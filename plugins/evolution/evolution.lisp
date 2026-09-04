;;;; evolution.lisp — SPEC-014 optional harness-evolution control plane

(in-package #:cl-user)

(defpackage #:anuna-imago.evolution
  (:use #:cl)
  (:export
   #:evolution-store
   #:open-evolution-store
   #:close-evolution-store
   #:freeze-candidate!
   #:read-candidate-manifest
   #:verify-candidate
   #:record-evaluation!
   #:make-decision!
   #:promote-candidate!
   #:rollback-pointer!
   #:read-pointer
   #:read-ledger
   #:read-ledger-head
   #:verify-ledger
   #:canonical-bytes
   #:candidate-directory
   #:candidate-image-path
   #:candidate-manifest-path
   #:ledger-path
   #:ledger-head-path
   #:pointer-path))

(in-package #:anuna-imago.evolution)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

;; ------------------------------------------------------------- constants ---

(defparameter +zero-sha256+ (make-string 64 :initial-element #\0))
(defparameter +manifest-file+ "manifest.sexp")
(defparameter +candidate-image-file+ "image.core")
(defparameter +ledger-file+ "ledger.sexp")
(defparameter +ledger-head-file+ "ledger.head")

(defparameter +manifest-keys+
  '(:version :candidate-id :parent-id :parent-image-sha256
    :image-file :image-sha256 :creator-did :creator-signature :created-at
    :theory-fingerprint :prompt-schema-sha256 :tool-schema-sha256
    :changed-components :budgets :activation-evidence))

(defparameter +budget-keys+
  '(:development-cost-microusd :wall-time-ms :input-tokens :output-tokens))

(defparameter +head-keys+
  '(:seq :event-hash :authority-did :authority-signature))

(defparameter +pointer-keys+
  '(:version :pointer :candidate-id :prior-candidate-id :event-hash))

(defparameter +freeze-event-keys+
  '(:event :timestamp :candidate-id :parent-id :image-sha256
    :manifest-sha256 :creator-did :creator-signature
    :seq :previous-hash :event-hash))

(defparameter +evaluation-event-keys+
  '(:event :timestamp :candidate-id :run-id :campaign-id :benchmark-id
    :split :task-id :replicate-index :evaluation-plan-sha256
    :executor-config-sha256 :scorer-config-sha256
    :executor-did :evaluator-did :run-complete-p :task-correct-p
    :capability-score-micros :activation-evidence :duration-ms
    :input-tokens :output-tokens :estimated-cost-microusd
    :executor-signature :evaluator-signature
    :seq :previous-hash :event-hash))

(defparameter +decision-event-keys+
  '(:event :timestamp :candidate-id :baseline-id :campaign-id :evidence-head
    :minimum-held-out-repetitions :minimum-distinct-executors
    :minimum-capability-delta-micros :maximum-execution-token-increase
    :maximum-runtime-cost-increase-microusd :gates :failed-gates
    :baseline-capability-mean-micros :candidate-capability-mean-micros
    :capability-delta-micros :replicate-capability-deltas
    :conservative-capability-delta-micros :executor-capability-deltas
    :baseline-execution-tokens-total :candidate-execution-tokens-total
    :baseline-execution-tokens-mean-per-event
    :candidate-execution-tokens-mean-per-event :execution-token-delta
    :baseline-runtime-cost-microusd-total
    :candidate-runtime-cost-microusd-total
    :baseline-runtime-cost-microusd-mean-per-event
    :candidate-runtime-cost-microusd-mean-per-event
    :runtime-cost-delta-microusd
    :development-cost-microusd :eligible-p :authorizer-did
    :authorization-signature :seq :previous-hash :event-hash))

(defparameter +activation-record-keys+
  '(:component :kind :artifact-sha256))

(defparameter +replicate-delta-keys+
  '(:replicate-index :baseline-capability-mean-micros
    :candidate-capability-mean-micros :capability-delta-micros))

(defparameter +executor-delta-keys+
  '(:executor-did :executor-config-sha256
    :baseline-capability-mean-micros :candidate-capability-mean-micros
    :capability-delta-micros))

(defparameter +pointer-event-keys+
  '(:event :timestamp :candidate-id :pointer :prior-candidate-id
    :evidence-head :authorizer-did :authorizer-signature
    :seq :previous-hash :event-hash))

(defparameter +gate-keys+
  '(:candidate-digest-valid
    :baseline-digest-valid
    :comparison-cells-match
    :candidate-cells-unique
    :single-evaluation-plan-context
    :replicate-templates-match
    :minimum-held-out-repetitions-met
    :minimum-distinct-executors-met
    :correctness-retained
    :changed-components-activated
    :runs-complete
    :creator-evaluator-separated
    :roles-pairwise-distinct
    :trusted-actor-signatures
    :replicate-capability-delta-met
    :per-executor-config-capability-delta-met
    :execution-token-increase-within-limit
    :runtime-cost-increase-within-limit
    :authorizer-rosters-disjoint
    :authorizer-creators-separated
    :trusted-authorizer-signature))

;; Persisted forms are deliberately small and closed.  These bounds are
;; security limits, not tuning hints: recognition rejects an input before it
;; can allocate an attacker-selected symbol, bignum, deep tree, or unbounded
;; file buffer.
(defparameter +maximum-form-octets+ (* 1024 1024))
(defparameter +maximum-ledger-octets+ (* 64 1024 1024))
(defparameter +maximum-canonical-depth+ 64)
(defparameter +maximum-canonical-nodes+ 16384)
(defparameter +maximum-list-elements+ 4096)
(defparameter +maximum-string-characters+ 65536)
(defparameter +maximum-source-integer+ (1- (expt 10 20)))
;; Derived decision totals add bounded source metrics.  Thirty-two decimal
;; digits cover every possible aggregate admitted by the campaign and ledger
;; ceilings while retaining a finite parser allocation bound.
(defparameter +maximum-integer-digits+ 32)
(defparameter +maximum-canonical-integer+
  (1- (expt 10 +maximum-integer-digits+)))
(defparameter +maximum-keyword-characters+ 64)
(defparameter +maximum-held-out-events-per-candidate-campaign+ 256)

(defparameter +persisted-keywords+
  (remove-duplicates
   (append +manifest-keys+ +budget-keys+ +head-keys+ +pointer-keys+
           +freeze-event-keys+ +evaluation-event-keys+
           +decision-event-keys+ +pointer-event-keys+ +gate-keys+
           +activation-record-keys+ +replicate-delta-keys+
           +executor-delta-keys+
           '(:freeze :evaluation :decision :promotion :rollback
             :feedback :development :selection :held-out
             :runtime-hit :reachable :canary :active))
   :test #'eq))

;; --------------------------------------------------------------- storage ---

(defclass evolution-store ()
  ((root :initarg :root :reader store-root)
   (authority :initarg :authority :reader store-authority)
   (authority-did :initarg :authority-did :reader store-authority-did)
   (trusted-executors :initarg :trusted-executors
                      :reader store-trusted-executors)
   (trusted-evaluators :initarg :trusted-evaluators
                       :reader store-trusted-evaluators)
   (trusted-authorizers :initarg :trusted-authorizers
                        :reader store-trusted-authorizers)
   (lock :initform (sb-thread:make-mutex :name "imago-evolution-store")
         :reader store-lock)))

(defun ledger-path (store)
  (merge-pathnames +ledger-file+ (store-root store)))

(defun ledger-head-path (store)
  (merge-pathnames +ledger-head-file+ (store-root store)))

(defun %ascii-digit-p (character)
  (and (char>= character #\0) (char<= character #\9)))

(defun %candidate-id-p (value)
  (and (stringp value)
       (<= 1 (length value) 63)
       (let ((first (char value 0)))
         (or (%ascii-digit-p first)
             (and (char>= first #\a) (char<= first #\z))))
       (every (lambda (character)
                (or (%ascii-digit-p character)
                    (and (char>= character #\a) (char<= character #\z))
                    (char= character #\-)))
              value)))

(defun %require-candidate-id (value)
  (unless (%candidate-id-p value)
    (error "Invalid candidate identifier ~S." value))
  value)

(defun candidate-directory (store candidate-id)
  (%require-candidate-id candidate-id)
  (%assert-store-root store)
  (%assert-managed-directory store "candidates/")
  (merge-pathnames (format nil "candidates/~A/" candidate-id)
                   (store-root store)))

(defun candidate-manifest-path (store candidate-id)
  (merge-pathnames +manifest-file+ (candidate-directory store candidate-id)))

(defun %pointer-name (pointer)
  (let ((name (etypecase pointer
                (keyword (string-downcase (symbol-name pointer)))
                (string (string-downcase pointer)))))
    (unless (member name '("canary" "active") :test #'string=)
      (error "Unsupported evolution pointer ~S." pointer))
    name))

(defun pointer-path (store pointer)
  (%assert-store-root store)
  (%assert-managed-directory store "pointers/")
  (merge-pathnames (format nil "pointers/~A.sexp" (%pointer-name pointer))
                   (store-root store)))

;; ---------------------------------------------------------- small helpers ---

(defun %control-character-p (character)
  (let ((code (char-code character)))
    (or (< code 32) (<= #x7f code #x9f))))

(defun %safe-string-p (value &key (nonempty nil) (ascii nil))
  (and (stringp value)
       (or (not nonempty) (plusp (length value)))
       (every (lambda (character)
                (and (not (%control-character-p character))
                     (or (not ascii) (< (char-code character) 128))))
              value)))

(defun %utc-string-p (value)
  (labels ((digits (start end)
             (loop for index from start below end
                   always (%ascii-digit-p (char value index))))
           (number (start end)
             (parse-integer value :start start :end end)))
    (and (%safe-string-p value :ascii t)
         (= (length value) 20)
         (digits 0 4)
         (char= (char value 4) #\-)
         (digits 5 7)
         (char= (char value 7) #\-)
         (digits 8 10)
         (char= (char value 10) #\T)
         (digits 11 13)
         (char= (char value 13) #\:)
         (digits 14 16)
         (char= (char value 16) #\:)
         (digits 17 19)
         (char= (char value 19) #\Z)
         (<= 1 (number 5 7) 12)
         (<= 1 (number 8 10) 31)
         (<= 0 (number 11 13) 23)
         (<= 0 (number 14 16) 59)
         (<= 0 (number 17 19) 60))))

(defun %proper-list-p (value)
  (loop with slow = value
        with fast = value
        do (cond
             ((null fast) (return t))
             ((atom fast) (return nil))
             (t (setf fast (cdr fast))))
           (cond
             ((null fast) (return t))
             ((atom fast) (return nil))
             (t (setf fast (cdr fast)
                      slow (cdr slow))))
           (when (eq slow fast) (return nil))))

(defun %validate-canonical-value (value &optional state (depth 0))
  "Validate the in-memory encoder domain with the same finite grammar bounds."
  (let ((state (or state (vector (make-hash-table :test #'eq) 0))))
    (when (> depth +maximum-canonical-depth+)
      (error "Canonical nesting exceeds its depth limit."))
    (when (> (incf (svref state 1)) +maximum-canonical-nodes+)
      (error "Canonical form contains too many values."))
    (cond
      ((or (null value) (eq value t)) t)
      ((keywordp value)
       (unless (and (<= (length (symbol-name value))
                         +maximum-keyword-characters+)
                    (member value +persisted-keywords+ :test #'eq))
         (error "Keyword ~S is outside the persisted schema." value))
       t)
      ((integerp value)
       (when (> (abs value) +maximum-canonical-integer+)
         (error "Canonical integer exceeds its digit limit."))
       t)
      ((stringp value)
       (unless (and (<= (length value) +maximum-string-characters+)
                    (%safe-string-p value))
         (error "Canonical string exceeds its bounds."))
       t)
      ((consp value)
       (let ((seen (svref state 0)) (marked nil) (tail value) (count 0))
         (unwind-protect
              (loop
                (cond
                  ((null tail) (return t))
                  ((atom tail)
                   (error "Canonical values require proper lists.")))
                (when (gethash tail seen)
                  (error "Canonical values cannot contain cycles."))
                (setf (gethash tail seen) t)
                (push tail marked)
                (when (> (incf count) +maximum-list-elements+)
                  (error "Canonical list contains too many elements."))
                (%validate-canonical-value (car tail) state (1+ depth))
                (setf tail (cdr tail)))
           (dolist (cell marked) (remhash cell seen)))))
      (t (error "Value ~S is outside the canonical grammar." value)))))

(defun %canonical-serialized-octets (value)
  "Return serialized UTF-8 size, aborting before a combined output allocation."
  (let ((total 0))
    (labels ((add (text)
               (incf total
                     (length (sb-ext:string-to-octets
                              text :external-format :utf-8)))
               (when (> total +maximum-form-octets+)
                 (error "Canonical form exceeds its UTF-8 octet limit.")))
             (walk (item)
               (cond
                 ((null item) (add "nil"))
                 ((eq item t) (add "t"))
                 ((consp item)
                  (add "(")
                  (loop for element in item
                        for first = t then nil
                        unless first do (add " ")
                        do (walk element))
                  (add ")"))
                 (t (add (with-output-to-string (stream)
                           (prin1 item stream)))))))
      (walk value)
      total)))

(defun %write-canonical-value (value stream)
  ;; T and NIL are emitted explicitly because SBCL qualifies inherited
  ;; COMMON-LISP symbols when *PACKAGE* is KEYWORD.  Every other atom uses the
  ;; contract printer bindings, and list spacing is fixed here.
  (cond
    ((null value) (write-string "nil" stream))
    ((eq value t) (write-string "t" stream))
    ((consp value)
     (write-char #\( stream)
     (loop for element in value
           for first = t then nil
           unless first do (write-char #\Space stream)
           do (%write-canonical-value element stream))
     (write-char #\) stream))
    (t (prin1 value stream))))

(defun canonical-bytes (value)
  "Return the exact UTF-8 bytes defined by SPEC-014 CON-006."
  (%validate-canonical-value value)
  (let ((*package* (find-package :keyword))
        (*print-base* 10)
        (*print-radix* nil)
        (*print-case* :downcase)
        (*print-pretty* nil)
        (*print-circle* nil)
        (*print-escape* t)
        (*print-readably* t))
    (%canonical-serialized-octets value)
    (let* ((text (with-output-to-string (stream)
                   (%write-canonical-value value stream)))
           (bytes (sb-ext:string-to-octets text :external-format :utf-8)))
      (unless (equal value (%read-one-form-string text "Canonical encoder"))
        (error "Canonical encoder and recognizer disagree."))
      bytes)))

(defun %canonical-string (value)
  (sb-ext:octets-to-string (canonical-bytes value) :external-format :utf-8))

(defun %sha256-bytes (bytes)
  (anuna-imago:bytes->hex (ironclad:digest-sequence :sha256 bytes)))

(defun %sha256-value (value)
  (%sha256-bytes (canonical-bytes value)))

(defun %sha256-file (path)
  (anuna-imago:bytes->hex (ironclad:digest-file :sha256 path)))

(defun %sha256-p (value)
  (and (stringp value)
       (= (length value) 64)
       (every (lambda (character)
                (or (%ascii-digit-p character)
                    (and (char>= character #\a) (char<= character #\f))))
              value)))

(defun %signature-p (value)
  (and (stringp value)
       (= (length value) 128)
       (every (lambda (character)
                (or (%ascii-digit-p character)
                    (and (char>= character #\a) (char<= character #\f))))
              value)))

(defun %did-key-p (did)
  (and (stringp did)
       (>= (length did) 13)
       (string= "did:key:z6Mk" did :end2 12)
       (handler-case
           (let ((bytes (anuna-imago:base58btc-decode (subseq did 9))))
             (and (= (length bytes) 34)
                  (= (aref bytes 0) #xed)
                  (= (aref bytes 1) #x01)))
         (error () nil))))

(defun %identity-did (identity)
  (let ((did (handler-case (anuna-imago:identity-did identity)
               (error () nil))))
    (unless (%did-key-p did)
      (error "A signing actor requires a valid Ed25519 did:key identity."))
    did))

(defun %sign-value (identity value)
  (%identity-did identity)
  (anuna-imago:bytes->hex
   (anuna-imago:sign-bytes identity (canonical-bytes value))))

(defun %verify-value (did value signature)
  (and (%did-key-p did)
       (%signature-p signature)
       (handler-case
           (anuna-imago:verify-bytes did (canonical-bytes value)
                                     (anuna-imago:hex->bytes signature))
         (error () nil))))

(defun %nonnegative-integer-p (value)
  (and (integerp value) (not (minusp value))))

(defun %bounded-source-integer-p (value)
  (and (%nonnegative-integer-p value)
       (<= value +maximum-source-integer+)))

(defun %sorted-unique-strings-p (value)
  (and (%proper-list-p value)
       (every (lambda (item) (%safe-string-p item :nonempty t)) value)
       (loop for (left right) on value
             while right
             always (string< left right))))

(defun %octets< (left right)
  (loop for index below (min (length left) (length right))
        for left-byte = (aref left index)
        for right-byte = (aref right index)
        when (< left-byte right-byte) do (return t)
        when (> left-byte right-byte) do (return nil)
        finally (return (< (length left) (length right)))))

(defun %canonical-value< (left right)
  (%octets< (canonical-bytes left) (canonical-bytes right)))

(defun %canonical-sort (values)
  (sort (copy-list values) #'%canonical-value<))

(defun %validate-activation-record (record)
  (%require-keys record +activation-record-keys+ "Activation record")
  (unless (%safe-string-p (getf record :component))
    (error "Activation component is invalid."))
  (unless (member (getf record :kind) '(:runtime-hit :reachable))
    (error "Activation kind is invalid."))
  (unless (%sha256-p (getf record :artifact-sha256))
    (error "Activation artifact digest is invalid."))
  record)

(defun %validate-activation-evidence (evidence)
  (unless (%proper-list-p evidence)
    (error "Activation evidence must be a proper list."))
  (dolist (record evidence)
    (%validate-activation-record record))
  (unless (loop for (left right) on evidence
                while right
                always (%canonical-value< left right))
    (error "Activation evidence must be unique and canonically sorted."))
  evidence)

(defun %plist-keys (plist)
  (unless (%proper-list-p plist)
    (error "Expected a proper property list."))
  (unless (evenp (length plist))
    (error "Expected an even property list."))
  (loop for key in plist by #'cddr
        unless (keywordp key)
          do (error "Property-list key ~S is not a keyword." key)
        collect key))

(defun %require-keys (plist expected context)
  (%validate-canonical-value plist)
  (let ((actual (%plist-keys plist)))
    (unless (equal actual expected)
      (error "~A has keys ~S; expected exactly ~S." context actual expected)))
  plist)

(defun %without-keys (plist keys)
  (loop for (key value) on plist by #'cddr
        unless (member key keys)
          append (list key value)))

(defun %read-file-string (path &key (maximum-octets +maximum-form-octets+))
  ;; FILE-LENGTH is an octet count for SBCL's UTF-8 file streams, and is an
  ;; upper bound on the number of decoded characters.  Check it before making
  ;; the input buffer; the final READ-CHAR also detects a file that grew after
  ;; the bound was checked.
  (unless (%regular-file-p path)
    (error "Persisted input ~A is absent or is not a regular file." path))
  (with-open-file (stream path :direction :input :external-format :utf-8)
    (let ((octets (file-length stream)))
      (unless (and (integerp octets) (<= 0 octets maximum-octets))
        (error "Persisted input ~A exceeds the ~D-octet limit."
               path maximum-octets))
      (let* ((buffer (make-string octets))
             (count (read-sequence buffer stream)))
        (when (read-char stream nil nil)
          (error "Persisted input ~A grew beyond its checked bound." path))
        (if (= count octets) buffer (subseq buffer 0 count))))))

(defun %write-file-string (path content &key (if-exists :supersede))
  (when (and (%path-entry-exists-p path) (not (%regular-file-p path)))
    (error "Refusing to open non-regular managed entry ~A." path))
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output
                               :if-exists if-exists
                               :if-does-not-exist :create
                               :external-format :utf-8)
    (write-string content stream)
    (finish-output stream))
  path)

(defun %temporary-peer (path)
  (parse-namestring
   (format nil "~A.tmp-~D-~D"
           (namestring path) (get-universal-time) (random 1000000000))))

(defun %atomic-write-string (path content)
  (when (and (%path-entry-exists-p path) (not (%regular-file-p path)))
    (error "Refusing to replace non-regular managed entry ~A." path))
  (let ((temporary (%temporary-peer path)))
    (unwind-protect
         (progn
           (%write-file-string temporary content :if-exists :error)
           (sb-posix:rename (namestring temporary) (namestring path))
           path)
      (when (%path-entry-exists-p temporary)
        (ignore-errors (delete-file temporary))))))

(defun %read-one-form-string (content context)
  "Recognize one bounded value from the closed canonical grammar.

Unlike the Common Lisp reader, this recognizer never resolves packages or
interns symbols.  Keyword slices are compared directly with an existing,
schema-derived vocabulary and only the corresponding pre-existing keyword is
returned."
  (unless (stringp content)
    (error "~A is not textual input." context))
  (when (> (length (sb-ext:string-to-octets
                    content :external-format :utf-8))
           +maximum-form-octets+)
    (error "~A exceeds the canonical form size limit." context))
  (let ((position 0)
        (length (length content))
        (nodes 0))
    (labels
        ((fail (control &rest arguments)
           (error "~A at offset ~D near ~S: ~?"
                  context position
                  (and (< position length) (char content position))
                  control arguments))
         (whitespace-p (character)
           (member character '(#\Space #\Tab #\Newline #\Return)))
         (delimiter-p (index)
           (or (= index length)
               (let ((character (char content index)))
                 (or (whitespace-p character)
                     (char= character #\()
                     (char= character #\))))))
         (skip-whitespace ()
           (loop while (and (< position length)
                            (whitespace-p (char content position)))
                 do (incf position)))
         (note-node ()
           (incf nodes)
           (when (> nodes +maximum-canonical-nodes+)
             (fail "canonical form contains too many values")))
         (slice-equal-p (start end expected)
           (and (= (- end start) (length expected))
                (loop for index from start below end
                      for expected-index from 0
                      always (char= (char content index)
                                    (char expected expected-index)))))
         (known-keyword (start end)
           (when (> (- end start) +maximum-keyword-characters+)
             (fail "keyword token exceeds its length limit"))
           (or (find-if
                (lambda (keyword)
                  (let ((name (symbol-name keyword)))
                    (and (= (- end start) (length name))
                         (loop for index from start below end
                               for name-index from 0
                               always (char-equal (char content index)
                                                  (char name name-index))))))
                +persisted-keywords+)
               (fail "keyword token is outside the persisted schema")))
         (parse-string-value ()
           ;; Scan and validate first, then allocate exactly once at the known
           ;; decoded length.  Canonical SBCL output escapes only quote and
           ;; backslash in strings admitted by %SAFE-STRING-P.
           (let ((scan (1+ position))
                 (decoded-length 0)
                 (closing nil))
             (loop while (< scan length)
                   for character = (char content scan)
                   do (cond
                        ((char= character #\")
                         (setf closing scan)
                         (return))
                        ((char= character #\\)
                         (incf scan)
                         (when (= scan length)
                           (fail "incomplete string escape"))
                         (unless (member (char content scan) '(#\" #\\))
                           (fail "non-canonical string escape"))
                         (incf decoded-length))
                        ((%control-character-p character)
                         (fail "string contains a control character"))
                        (t (incf decoded-length)))
                      (when (> decoded-length +maximum-string-characters+)
                        (fail "string exceeds its length limit"))
                      (incf scan))
             (unless closing (fail "unterminated string"))
             (let ((result (make-string decoded-length))
                   (source (1+ position))
                   (target 0))
               (loop while (< source closing)
                     for character = (char content source)
                     do (when (char= character #\\)
                          (incf source)
                          (setf character (char content source)))
                        (setf (char result target) character)
                        (incf source)
                        (incf target))
               (setf position (1+ closing))
               result)))
         (parse-integer-value ()
           (let ((start position))
             (when (char= (char content position) #\-)
               (incf position)
               (when (= position length)
                 (fail "incomplete integer")))
             (let ((digit-start position))
               (loop while (and (< position length)
                                (%ascii-digit-p (char content position)))
                     do (incf position)
                        (when (> (- position digit-start)
                                 +maximum-integer-digits+)
                          (fail "integer exceeds its digit limit")))
               (when (= position digit-start)
                 (fail "invalid integer token"))
               (unless (delimiter-p position)
                 (fail "invalid character after integer"))
               (when (and (> (- position digit-start) 1)
                          (char= (char content digit-start) #\0))
                 (fail "integer has a non-canonical leading zero"))
               (when (and (char= (char content start) #\-)
                          (= (- position digit-start) 1)
                          (char= (char content digit-start) #\0))
                 (fail "negative zero is not canonical"))
               (parse-integer content :start start :end position))))
         (parse-base-string-array ()
           ;; With *PRINT-READABLY* true SBCL prints a SIMPLE-BASE-STRING as
           ;; #A((N) COMMON-LISP:BASE-CHAR . "...").  It is still a string in
           ;; CON-006's value grammar, so recognize precisely this one printer
           ;; form without enabling dispatch macros or resolving CL symbols.
           (let ((prefix "#A((")
                 (type-marker ") common-lisp:base-char . "))
             (unless (and (<= (+ position (length prefix)) length)
                          (slice-equal-p position
                                         (+ position (length prefix)) prefix))
               (fail "unsupported dispatch syntax"))
             (incf position (length prefix))
             (let ((digit-start position))
               (loop while (and (< position length)
                                (%ascii-digit-p (char content position)))
                     do (incf position)
                        (when (> (- position digit-start)
                                 +maximum-integer-digits+)
                          (fail "array string length exceeds its digit limit")))
               (when (= position digit-start)
                 (fail "array string has no declared length"))
               (let ((declared-length
                       (parse-integer content :start digit-start :end position)))
                 (when (> declared-length +maximum-string-characters+)
                   (fail "array string exceeds its length limit"))
                 (unless (and (<= (+ position (length type-marker)) length)
                              (slice-equal-p
                               position (+ position (length type-marker))
                               type-marker))
                   (fail "array string has a non-canonical element type"))
                 (incf position (length type-marker))
                 (unless (and (< position length)
                              (char= (char content position) #\"))
                   (fail "array string has no string contents"))
                 (let ((value (parse-string-value)))
                   (unless (and (< position length)
                                (char= (char content position) #\)))
                     (fail "array string is incomplete"))
                   (incf position)
                   (unless (= declared-length (length value))
                     (fail "array string length does not match its contents"))
                   (let ((base-value
                           (make-array declared-length
                                       :element-type 'base-char)))
                     (replace base-value value)
                     base-value))))))
         (parse-keyword-value ()
           (let ((start (1+ position)))
             (setf position start)
             (loop while (and (< position length)
                              (let ((character (char content position)))
                                (or (and (char>= character #\a)
                                         (char<= character #\z))
                                    (and (char>= character #\A)
                                         (char<= character #\Z))
                                    (%ascii-digit-p character)
                                    (char= character #\-))))
                   do (incf position)
                      (when (> (- position start)
                               +maximum-keyword-characters+)
                        (fail "keyword token exceeds its length limit")))
             (when (= start position) (fail "empty keyword token"))
             (unless (delimiter-p position)
               (fail "invalid character after keyword"))
             (known-keyword start position)))
         (parse-list-value (depth)
           (incf position)
           (let ((elements nil)
                 (count 0))
             (loop
               (skip-whitespace)
               (when (= position length) (fail "unterminated list"))
               (when (char= (char content position) #\))
                 (incf position)
                 (return (nreverse elements)))
               (incf count)
               (when (> count +maximum-list-elements+)
                 (fail "list contains too many elements"))
               (push (parse-value (1+ depth)) elements)
               (when (and (< position length)
                          (not (or (whitespace-p (char content position))
                                   (char= (char content position) #\)))))
                 (fail "list elements require a delimiter")))))
         (parse-value (depth)
           (when (> depth +maximum-canonical-depth+)
             (fail "canonical nesting exceeds its depth limit"))
           (when (= position length) (fail "incomplete canonical value"))
           (note-node)
           (let ((character (char content position)))
             (cond
               ((char= character #\() (parse-list-value depth))
               ((char= character #\") (parse-string-value))
               ((char= character #\#) (parse-base-string-array))
               ((char= character #\:) (parse-keyword-value))
               ((or (%ascii-digit-p character) (char= character #\-))
                (parse-integer-value))
               ((and (<= (+ position 3) length)
                     (slice-equal-p position (+ position 3) "nil")
                     (delimiter-p (+ position 3)))
                (incf position 3)
                nil)
               ((and (< position length)
                     (char= character #\t)
                     (delimiter-p (1+ position)))
                (incf position)
                t)
               (t (fail "token is outside the canonical grammar"))))))
      (skip-whitespace)
      (when (= position length)
        (fail "input is empty"))
      (let ((form (parse-value 0)))
        (skip-whitespace)
        (unless (= position length)
          (fail "input contains trailing data"))
        form))))

(defun %read-one-form-file (path context &key
                                           (maximum-octets
                                             +maximum-form-octets+))
  (%read-one-form-string
   (%read-file-string path :maximum-octets maximum-octets)
   context))

(defun %persisted-form-string (value context)
  "Serialize VALUE only if the closed recognizer can recover the same value."
  (let ((content (%canonical-string value)))
    (unless (equal value (%read-one-form-string content context))
      (error "~A does not round-trip through the persisted grammar." context))
    content))

(defun %copy-binary-file (source target)
  (unless (%regular-file-p source)
    (error "Binary source ~A is not a regular file." source))
  (when (%path-entry-exists-p target)
    (error "Binary target ~A already exists." target))
  (ensure-directories-exist target)
  (with-open-file (input source :direction :input
                                :element-type '(unsigned-byte 8))
    (with-open-file (output target :direction :output
                                  :if-exists :error
                                  :if-does-not-exist :create
                                  :element-type '(unsigned-byte 8))
      (let ((buffer (make-array 65536 :element-type '(unsigned-byte 8))))
        (loop for count = (read-sequence buffer input)
              while (plusp count)
              do (write-sequence buffer output :end count))
        (finish-output output))))
  target)

(defun %path-entry-exists-p (path)
  (handler-case
      (progn (sb-posix:lstat (namestring path)) t)
    (sb-posix:syscall-error () nil)))

(defun %regular-file-p (path)
  (handler-case
      (sb-posix:s-isreg
       (sb-posix:stat-mode (sb-posix:lstat (namestring path))))
    (sb-posix:syscall-error () nil)))

(defun %directory-entry-p (path)
  (handler-case
      (sb-posix:s-isdir
       (sb-posix:stat-mode
        (sb-posix:lstat (string-right-trim "/" (namestring path)))))
    (sb-posix:syscall-error () nil)))

(defun %assert-store-root (store)
  (unless (%directory-entry-p (store-root store))
    (error "Evolution store root is absent, replaced, or symlinked."))
  t)

(defun %assert-managed-directory (store relative)
  (%assert-store-root store)
  (let ((path (merge-pathnames relative (store-root store))))
    (unless (%directory-entry-p path)
      (error "Managed evolution directory ~A is absent or symlinked." path))
    path))

;; ---------------------------------------------------------- strict forms ---

(defun %validate-budgets (budgets)
  (%require-keys budgets +budget-keys+ "Candidate budgets")
  (dolist (key +budget-keys+)
    (unless (%bounded-source-integer-p (getf budgets key))
      (error "Budget ~S must be a bounded nonnegative integer." key)))
  budgets)

(defun %basename-p (value)
  (and (%safe-string-p value :nonempty t :ascii t)
       (not (member value '("." "..") :test #'string=))
       (not (find #\/ value))
       (not (find #\\ value))))

(defun %validate-manifest (manifest)
  (%require-keys manifest +manifest-keys+ "Candidate manifest")
  (unless (= (getf manifest :version) 1)
    (error "Unsupported manifest version."))
  (%require-candidate-id (getf manifest :candidate-id))
  (let ((parent (getf manifest :parent-id))
        (parent-digest (getf manifest :parent-image-sha256)))
    (unless (or (and (null parent) (null parent-digest))
                (and (%candidate-id-p parent) (%sha256-p parent-digest)))
      (error "Parent identifier and digest must be present together.")))
  (unless (%basename-p (getf manifest :image-file))
    (error "Manifest image path must be a relative basename."))
  (dolist (key '(:image-sha256 :theory-fingerprint
                 :prompt-schema-sha256 :tool-schema-sha256))
    (unless (%sha256-p (getf manifest key))
      (error "Manifest field ~S is not a SHA-256 digest." key)))
  (unless (%did-key-p (getf manifest :creator-did))
    (error "Manifest creator DID is invalid."))
  (unless (%signature-p (getf manifest :creator-signature))
    (error "Manifest creator signature is invalid."))
  (unless (%utc-string-p (getf manifest :created-at))
    (error "Manifest creation time is invalid."))
  (unless (%sorted-unique-strings-p (getf manifest :changed-components))
    (error "Changed components must be sorted unique strings."))
  (%validate-budgets (getf manifest :budgets))
  (unless (%sorted-unique-strings-p (getf manifest :activation-evidence))
    (error "Activation evidence must be sorted unique strings."))
  manifest)

(defun %read-manifest-form (store candidate-id)
  (%require-candidate-id candidate-id)
  (let ((directory (candidate-directory store candidate-id))
        (path (candidate-manifest-path store candidate-id)))
    (unless (%directory-entry-p directory)
      (error "Candidate directory is absent or is not a real directory."))
    (unless (%regular-file-p path)
      (error "Candidate manifest is absent or is not a regular file."))
    (%validate-manifest
     (%read-one-form-file path "Candidate manifest"))))

(defun %manifest-signature-valid-p (manifest)
  (%verify-value (getf manifest :creator-did)
                 (%without-keys manifest '(:creator-signature))
                 (getf manifest :creator-signature)))

(defun %validate-head (head)
  (%require-keys head +head-keys+ "Ledger head")
  (unless (%nonnegative-integer-p (getf head :seq))
    (error "Ledger head sequence is invalid."))
  (unless (%sha256-p (getf head :event-hash))
    (error "Ledger head hash is invalid."))
  (unless (%did-key-p (getf head :authority-did))
    (error "Ledger head authority is invalid."))
  (unless (%signature-p (getf head :authority-signature))
    (error "Ledger head signature is invalid."))
  head)

(defun %validate-pointer-form (form expected-pointer)
  (%require-keys form +pointer-keys+ "Evolution pointer")
  (unless (= (getf form :version) 1)
    (error "Unsupported pointer version."))
  (unless (eq (getf form :pointer) expected-pointer)
    (error "Pointer name does not match its path."))
  (%require-candidate-id (getf form :candidate-id))
  (let ((prior (getf form :prior-candidate-id)))
    (unless (or (null prior) (%candidate-id-p prior))
      (error "Pointer prior candidate is invalid.")))
  (unless (%sha256-p (getf form :event-hash))
    (error "Pointer event hash is invalid."))
  form)

(defun %validate-event-common (event expected-keys)
  (%require-keys event expected-keys "Ledger event")
  (unless (%utc-string-p (getf event :timestamp))
    (error "Ledger timestamp is invalid."))
  (%require-candidate-id (getf event :candidate-id))
  (unless (and (integerp (getf event :seq)) (plusp (getf event :seq)))
    (error "Ledger sequence is invalid."))
  (unless (%sha256-p (getf event :previous-hash))
    (error "Previous event hash is invalid."))
  (unless (%sha256-p (getf event :event-hash))
    (error "Event hash is invalid."))
  event)

(defun %validate-freeze-event (event)
  (%validate-event-common event +freeze-event-keys+)
  (unless (eq (getf event :event) :freeze)
    (error "Expected a freeze event."))
  (let ((parent (getf event :parent-id)))
    (unless (or (null parent) (%candidate-id-p parent))
      (error "Freeze parent identifier is invalid.")))
  (unless (and (%sha256-p (getf event :image-sha256))
               (%sha256-p (getf event :manifest-sha256)))
    (error "Freeze digest is invalid."))
  (unless (and (%did-key-p (getf event :creator-did))
               (%signature-p (getf event :creator-signature)))
    (error "Freeze actor evidence is invalid."))
  event)

(defun %validate-evaluation-event (event)
  (%validate-event-common event +evaluation-event-keys+)
  (unless (eq (getf event :event) :evaluation)
    (error "Expected an evaluation event."))
  (dolist (key '(:run-id :campaign-id :benchmark-id :task-id))
    (unless (%safe-string-p (getf event key) :nonempty t :ascii t)
      (error "Evaluation identifier ~S is invalid." key)))
  (unless (member (getf event :split)
                  '(:feedback :development :selection :held-out))
    (error "Evaluation split is invalid."))
  (unless (and (integerp (getf event :replicate-index))
               (plusp (getf event :replicate-index)))
    (error "Evaluation replicate index is invalid."))
  (dolist (key '(:evaluation-plan-sha256 :executor-config-sha256
                 :scorer-config-sha256))
    (unless (%sha256-p (getf event key))
      (error "Evaluation configuration ~S is invalid." key)))
  (unless (and (%did-key-p (getf event :executor-did))
               (%did-key-p (getf event :evaluator-did)))
    (error "Evaluation actor DID is invalid."))
  (dolist (key '(:run-complete-p :task-correct-p))
    (unless (member (getf event key) '(nil t))
      (error "Evaluation Boolean ~S is invalid." key)))
  (dolist (key '(:capability-score-micros :duration-ms :input-tokens
                 :output-tokens :estimated-cost-microusd))
    (unless (%bounded-source-integer-p (getf event key))
      (error "Evaluation metric ~S is invalid." key)))
  (%validate-activation-evidence (getf event :activation-evidence))
  (unless (and (%signature-p (getf event :executor-signature))
               (%signature-p (getf event :evaluator-signature)))
    (error "Evaluation actor signature is invalid."))
  event)

(defun %validate-gates (gates)
  (%require-keys gates +gate-keys+ "Decision gates")
  (dolist (key +gate-keys+)
    (unless (member (getf gates key) '(nil t))
      (error "Decision gate ~S is not Boolean." key)))
  gates)

(defun %validate-replicate-delta (record)
  (%require-keys record +replicate-delta-keys+ "Replicate delta")
  (unless (and (integerp (getf record :replicate-index))
               (plusp (getf record :replicate-index)))
    (error "Replicate delta index is invalid."))
  (dolist (key '(:baseline-capability-mean-micros
                 :candidate-capability-mean-micros))
    (unless (%nonnegative-integer-p (getf record key))
      (error "Replicate delta metric ~S is invalid." key)))
  (unless (and (integerp (getf record :capability-delta-micros))
               (= (getf record :capability-delta-micros)
                  (- (getf record :candidate-capability-mean-micros)
                     (getf record :baseline-capability-mean-micros))))
    (error "Replicate capability delta is incoherent."))
  record)

(defun %validate-executor-delta (record)
  (%require-keys record +executor-delta-keys+ "Executor/config delta")
  (unless (%did-key-p (getf record :executor-did))
    (error "Executor/config delta DID is invalid."))
  (unless (%sha256-p (getf record :executor-config-sha256))
    (error "Executor/config delta digest is invalid."))
  (dolist (key '(:baseline-capability-mean-micros
                 :candidate-capability-mean-micros))
    (unless (%nonnegative-integer-p (getf record key))
      (error "Executor/config delta metric ~S is invalid." key)))
  (unless (and (integerp (getf record :capability-delta-micros))
               (= (getf record :capability-delta-micros)
                  (- (getf record :candidate-capability-mean-micros)
                     (getf record :baseline-capability-mean-micros))))
    (error "Executor/config capability delta is incoherent."))
  record)

(defun %executor-delta< (left right)
  (let ((left-did (getf left :executor-did))
        (right-did (getf right :executor-did)))
    (or (string< left-did right-did)
        (and (string= left-did right-did)
             (string< (getf left :executor-config-sha256)
                      (getf right :executor-config-sha256))))))

(defun %validate-decision-event (event)
  (%validate-event-common event +decision-event-keys+)
  (unless (eq (getf event :event) :decision)
    (error "Expected a decision event."))
  (%require-candidate-id (getf event :baseline-id))
  (when (string= (getf event :candidate-id) (getf event :baseline-id))
    (error "Decision candidates must differ."))
  (unless (%safe-string-p (getf event :campaign-id) :nonempty t :ascii t)
    (error "Decision campaign identifier is invalid."))
  (unless (%sha256-p (getf event :evidence-head))
    (error "Decision evidence head is invalid."))
  (dolist (key '(:minimum-held-out-repetitions :minimum-distinct-executors))
    (unless (and (integerp (getf event key)) (>= (getf event key) 2))
      (error "Decision threshold ~S is invalid." key)))
  (unless (and (integerp (getf event :minimum-capability-delta-micros))
               (plusp (getf event :minimum-capability-delta-micros)))
    (error "Decision capability threshold must be positive."))
  (dolist (key '(:maximum-execution-token-increase
                 :maximum-runtime-cost-increase-microusd
                 :baseline-capability-mean-micros
                 :candidate-capability-mean-micros
                 :baseline-execution-tokens-total
                 :candidate-execution-tokens-total
                 :baseline-execution-tokens-mean-per-event
                 :candidate-execution-tokens-mean-per-event
                 :baseline-runtime-cost-microusd-total
                 :candidate-runtime-cost-microusd-total
                 :baseline-runtime-cost-microusd-mean-per-event
                 :candidate-runtime-cost-microusd-mean-per-event
                 :development-cost-microusd))
    (unless (%nonnegative-integer-p (getf event key))
      (error "Decision metric ~S is invalid." key)))
  (dolist (key '(:capability-delta-micros
                 :conservative-capability-delta-micros
                 :execution-token-delta :runtime-cost-delta-microusd))
    (unless (integerp (getf event key))
      (error "Decision signed metric ~S is invalid." key)))
  (unless (= (getf event :capability-delta-micros)
             (- (getf event :candidate-capability-mean-micros)
                (getf event :baseline-capability-mean-micros)))
    (error "Decision aggregate capability delta is incoherent."))
  (unless (= (getf event :execution-token-delta)
             (- (getf event :candidate-execution-tokens-total)
                (getf event :baseline-execution-tokens-total)))
    (error "Decision execution-token delta is incoherent."))
  (unless (= (getf event :runtime-cost-delta-microusd)
             (- (getf event :candidate-runtime-cost-microusd-total)
                (getf event :baseline-runtime-cost-microusd-total)))
    (error "Decision runtime-cost delta is incoherent."))
  (dolist (pair
            '((:baseline-execution-tokens-mean-per-event
               :baseline-execution-tokens-total)
              (:candidate-execution-tokens-mean-per-event
               :candidate-execution-tokens-total)
              (:baseline-runtime-cost-microusd-mean-per-event
               :baseline-runtime-cost-microusd-total)
              (:candidate-runtime-cost-microusd-mean-per-event
               :candidate-runtime-cost-microusd-total)))
    (unless (<= (getf event (first pair)) (getf event (second pair)))
      (error "Decision per-event mean ~S exceeds its total." (first pair))))
  (let ((replicates (getf event :replicate-capability-deltas))
        (executors (getf event :executor-capability-deltas)))
    (unless (%proper-list-p replicates)
      (error "Decision replicate deltas must be a proper list."))
    (dolist (record replicates) (%validate-replicate-delta record))
    (unless (loop for (left right) on replicates
                  while right
                  always (< (getf left :replicate-index)
                            (getf right :replicate-index)))
      (error "Decision replicate deltas must be uniquely sorted."))
    (unless (= (getf event :conservative-capability-delta-micros)
               (if replicates
                   (reduce #'min replicates
                           :key (lambda (record)
                                  (getf record :capability-delta-micros)))
                   0))
      (error "Decision conservative capability delta is incoherent."))
    (unless (%proper-list-p executors)
      (error "Decision executor/config deltas must be a proper list."))
    (dolist (record executors) (%validate-executor-delta record))
    (unless (loop for (left right) on executors
                  while right
                  always (%executor-delta< left right))
      (error "Decision executor/config deltas must be uniquely sorted.")))
  (%validate-gates (getf event :gates))
  (let ((gates (getf event :gates)))
    (unless (eq (getf gates :replicate-capability-delta-met)
                (not (null
                      (and (getf event :replicate-capability-deltas)
                           (>= (getf event
                                    :conservative-capability-delta-micros)
                               (getf event
                                     :minimum-capability-delta-micros))))))
      (error "Replicate capability gate is incoherent."))
    (unless (eq (getf gates :per-executor-config-capability-delta-met)
                (not (null
                      (and (getf event :executor-capability-deltas)
                           (every
                            (lambda (record)
                              (>= (getf record :capability-delta-micros)
                                  (getf event
                                        :minimum-capability-delta-micros)))
                            (getf event :executor-capability-deltas))))))
      (error "Executor/config capability gate is incoherent."))
    (unless (eq (getf gates :execution-token-increase-within-limit)
                (<= (getf event :execution-token-delta)
                    (getf event :maximum-execution-token-increase)))
      (error "Execution-token gate is incoherent."))
    (unless (eq (getf gates :runtime-cost-increase-within-limit)
                (<= (getf event :runtime-cost-delta-microusd)
                    (getf event
                          :maximum-runtime-cost-increase-microusd)))
      (error "Runtime-cost gate is incoherent.")))
  (let ((expected-failures
          (loop for (key value) on (getf event :gates) by #'cddr
                unless value collect key)))
    (unless (and (%proper-list-p (getf event :failed-gates))
                 (equal (getf event :failed-gates) expected-failures))
      (error "Decision failed gates do not exactly match gate results."))
    (unless (eq (getf event :eligible-p) (null expected-failures))
      (error "Decision eligibility does not match failed gates.")))
  (unless (member (getf event :eligible-p) '(nil t))
    (error "Decision eligibility must be Boolean."))
  (unless (string= (getf event :evidence-head)
                   (getf event :previous-hash))
    (error "Decision evidence head must equal its previous event hash."))
  (unless (and (%did-key-p (getf event :authorizer-did))
               (%signature-p (getf event :authorization-signature)))
    (error "Decision authorization evidence is invalid."))
  event)

(defun %validate-pointer-event (event)
  (%validate-event-common event +pointer-event-keys+)
  (unless (member (getf event :event) '(:promotion :rollback))
    (error "Expected a promotion or rollback event."))
  (unless (member (getf event :pointer) '(:canary :active))
    (error "Pointer event name is invalid."))
  (let ((prior (getf event :prior-candidate-id)))
    (unless (or (null prior) (%candidate-id-p prior))
      (error "Pointer event prior candidate is invalid.")))
  (unless (and (%sha256-p (getf event :evidence-head))
               (string= (getf event :evidence-head)
                        (getf event :previous-hash)))
    (error "Pointer authorization must bind the immediately prior ledger head."))
  (unless (and (%did-key-p (getf event :authorizer-did))
               (%signature-p (getf event :authorizer-signature)))
    (error "Pointer authorizer evidence is invalid."))
  event)

(defun %validate-event (event)
  (case (getf event :event)
    (:freeze (%validate-freeze-event event))
    (:evaluation (%validate-evaluation-event event))
    (:decision (%validate-decision-event event))
    ((:promotion :rollback) (%validate-pointer-event event))
    (otherwise (error "Unknown ledger event kind ~S." (getf event :event)))))

(defun %exposed-split-p (split)
  (member split '(:feedback :development :selection)))

(defun %comparison-cell (event)
  (list :benchmark-id (getf event :benchmark-id)
        :task-id (getf event :task-id)
        :replicate-index (getf event :replicate-index)
        :executor-did (getf event :executor-did)
        :evaluator-did (getf event :evaluator-did)
        :evaluation-plan-sha256 (getf event :evaluation-plan-sha256)
        :executor-config-sha256 (getf event :executor-config-sha256)
        :scorer-config-sha256 (getf event :scorer-config-sha256)))

(defun %storage-cell (event)
  (list :campaign-id (getf event :campaign-id)
        :evaluation-plan-sha256 (getf event :evaluation-plan-sha256)
        :benchmark-id (getf event :benchmark-id)
        :task-id (getf event :task-id)
        :replicate-index (getf event :replicate-index)
        :executor-did (getf event :executor-did)
        :evaluator-did (getf event :evaluator-did)
        :executor-config-sha256 (getf event :executor-config-sha256)
        :scorer-config-sha256 (getf event :scorer-config-sha256)))

(defun %same-campaign-benchmark-task-p (left right)
  (and (string= (getf left :campaign-id) (getf right :campaign-id))
       (string= (getf left :benchmark-id) (getf right :benchmark-id))
       (string= (getf left :task-id) (getf right :task-id))))

(defun %split-contamination-p (left right)
  (and (%same-campaign-benchmark-task-p left right)
       (or (and (eq (getf left :split) :held-out)
                (%exposed-split-p (getf right :split)))
           (and (eq (getf right :split) :held-out)
                (%exposed-split-p (getf left :split))))))

(defun %validate-evaluation-ledger-constraints (event prior-events)
  (when (eq (getf event :event) :evaluation)
    (when (and (eq (getf event :split) :held-out)
               (>= (count-if
                    (lambda (prior)
                      (and (eq (getf prior :event) :evaluation)
                           (eq (getf prior :split) :held-out)
                           (string= (getf event :campaign-id)
                                    (getf prior :campaign-id))
                           (string= (getf event :candidate-id)
                                    (getf prior :candidate-id))))
                    prior-events)
                   +maximum-held-out-events-per-candidate-campaign+))
      (error "Held-out campaign exceeds the per-candidate evidence bound."))
    (dolist (prior prior-events)
      (when (eq (getf prior :event) :evaluation)
        (when (string= (getf event :run-id) (getf prior :run-id))
          (error "Ledger contains duplicate run identifier ~S."
                 (getf event :run-id)))
        (when (and (string= (getf event :candidate-id)
                            (getf prior :candidate-id))
                   (equal (%storage-cell event) (%storage-cell prior)))
          (error "Candidate ~A contains a duplicate evaluation cell."
                 (getf event :candidate-id)))
        (when (%split-contamination-p event prior)
          (error "Campaign task crosses the exposed and held-out split classes.")))))
  event)

;; --------------------------------------------------------------- ledger ---

(defun %head-payload (sequence hash authority-did)
  (list :seq sequence :event-hash hash :authority-did authority-did))

(defun %make-head (store sequence hash)
  (let* ((payload (%head-payload sequence hash (store-authority-did store)))
         (signature (%sign-value (store-authority store) payload))
         (head (append payload (list :authority-signature signature))))
    ;; Signing is a synchronous precondition, not part of the filesystem
    ;; commit.  Catch cleared or mismatched private keys before any ledger byte
    ;; can be appended.
    (unless (%verify-value (store-authority-did store) payload signature)
      (error "Store authority cannot produce a self-verifying ledger head."))
    head))

(defun %write-head (store sequence hash &optional prepared-head)
  (%assert-store-root store)
  (let ((head (or prepared-head (%make-head store sequence hash))))
    (unless (and (= sequence (getf head :seq))
                 (string= hash (getf head :event-hash))
                 (string= (store-authority-did store)
                          (getf head :authority-did))
                 (%verify-value
                  (getf head :authority-did)
                  (%without-keys head '(:authority-signature))
                  (getf head :authority-signature)))
      (error "Prepared ledger head does not match the requested commit."))
    (%atomic-write-string
     (ledger-head-path store)
     (concatenate 'string
                  (%persisted-form-string head "Generated ledger head")
                  (string #\Newline)))))

(defun %read-head-unlocked (store)
  (%assert-store-root store)
  (let ((head (%validate-head
               (%read-one-form-file (ledger-head-path store) "Ledger head"))))
    (unless (string= (getf head :authority-did) (store-authority-did store))
      (error "Ledger head belongs to a different store authority."))
    (unless (%verify-value
             (getf head :authority-did)
             (%without-keys head '(:authority-signature))
             (getf head :authority-signature))
      (error "Ledger head signature verification failed."))
    head))

(defun read-ledger-head (store)
  (sb-thread:with-mutex ((store-lock store))
    ;; The exported observer returns a terminal head only after establishing
    ;; that the complete ledger prefix actually commits to it.
    (%read-ledger-unlocked store)
    (%read-head-unlocked store)))

(defun %complete-ledger-lines (content)
  (loop with start = 0
        for newline = (position #\Newline content :start start)
        while newline
        when (> (length (sb-ext:string-to-octets
                         content :start start :end newline
                         :external-format :utf-8))
                +maximum-form-octets+)
          do (error "Ledger event exceeds the canonical form size limit.")
        collect (subseq content start newline)
        do (setf start (1+ newline))))

(defun %event-actor-payload (event)
  (%without-keys event
                 '(:creator-signature :executor-signature
                   :evaluator-signature :authorization-signature
                   :authorizer-signature :seq :previous-hash :event-hash)))

(defun %verify-event-actors (store event)
  (let ((payload (%event-actor-payload event)))
    (case (getf event :event)
      (:freeze
       (%verify-value (getf event :creator-did) payload
                      (getf event :creator-signature)))
      (:evaluation
       (and (member (getf event :executor-did)
                    (store-trusted-executors store) :test #'string=)
            (member (getf event :evaluator-did)
                    (store-trusted-evaluators store) :test #'string=)
            (%verify-value (getf event :executor-did) payload
                           (getf event :executor-signature))
            (%verify-value (getf event :evaluator-did) payload
                           (getf event :evaluator-signature))))
      (:decision
       (and (member (getf event :authorizer-did)
                    (store-trusted-authorizers store) :test #'string=)
            (%verify-value (getf event :authorizer-did) payload
                           (getf event :authorization-signature))))
      ((:promotion :rollback)
       (and (member (getf event :authorizer-did)
                    (store-trusted-authorizers store) :test #'string=)
            (%verify-value (getf event :authorizer-did) payload
                           (getf event :authorizer-signature))))
      (otherwise nil))))

(defun %read-ledger-unlocked (store)
  (%assert-store-root store)
  (let ((events nil)
        (expected-sequence 1)
        (previous-hash +zero-sha256+))
    (dolist (line (%complete-ledger-lines
                   (%read-file-string
                    (ledger-path store)
                    :maximum-octets +maximum-ledger-octets+)))
      (when (zerop (length line))
        (error "Ledger contains an empty complete line."))
      (let ((event (%validate-event (%read-one-form-string line "Ledger event"))))
        (unless (= expected-sequence (getf event :seq))
          (error "Ledger sequence discontinuity."))
        (unless (string= previous-hash (getf event :previous-hash))
          (error "Ledger previous-hash discontinuity."))
        (unless (string=
                 (%sha256-value (%without-keys event '(:event-hash)))
                 (getf event :event-hash))
          (error "Ledger event hash verification failed."))
        (when (and (eq (getf event :event) :decision)
                   (not (string= (getf event :evidence-head) previous-hash)))
          (error "Decision does not bind the immediately preceding evidence head."))
        (when (eq (getf event :event) :evaluation)
          (let* ((manifest (%read-manifest-form
                            store (getf event :candidate-id)))
                 (creator (getf manifest :creator-did)))
            (unless (and (string= (getf event :candidate-id)
                                  (getf manifest :candidate-id))
                         (%candidate-freeze-evidence-valid-p
                          store manifest (reverse events)))
              (error "Evaluation manifest is not anchored to a prior freeze event."))
            (unless (%manifest-signature-valid-p manifest)
              (error "Evaluation refers to an unsigned manifest."))
            (when (eq (getf event :split) :held-out)
              (unless (= 3 (length
                            (remove-duplicates
                             (list creator
                                   (getf event :executor-did)
                                   (getf event :evaluator-did))
                             :test #'string=)))
                (error "Held-out ledger roles are not pairwise distinct.")))))
        (%validate-evaluation-ledger-constraints event events)
        (unless (%verify-event-actors store event)
          (error "Ledger actor signature verification failed."))
        (when (eq (getf event :event) :freeze)
          ;; Every freeze is a durable reference to its immutable manifest,
          ;; even when no held-out evaluation or decision exists yet.
          (%require-anchored-candidate-context
           store (getf event :candidate-id) (cons event events)))
        ;; Decisions are caches of facts derived from their signed prefix, not
        ;; new sources of truth.  Recompute every derived field while replaying
        ;; the ledger.  The two digest gates are point-in-time attestations: a
        ;; later image mutation must not make history unreadable (and is still
        ;; checked afresh by promotion).
        (when (eq (getf event :event) :decision)
          (%validate-decision-against-events
           store event (reverse events) :historical-p t))
        (push event events)
        (setf previous-hash (getf event :event-hash))
        (incf expected-sequence)))
    (setf events (nreverse events))
    (let ((head (%read-head-unlocked store)))
      (unless (and (= (getf head :seq) (length events))
                   (string= (getf head :event-hash) previous-hash))
        (error "Ledger does not match its signed terminal head.")))
    events))

(defun read-ledger (store)
  (sb-thread:with-mutex ((store-lock store))
    (%read-ledger-unlocked store)))

(defun verify-ledger (store)
  (handler-case (progn (read-ledger store) t)
    (error () nil)))

(defun %append-event-unlocked (store actor-event &optional events)
  (%assert-store-root store)
  (let* ((events (or events (%read-ledger-unlocked store)))
         (sequence (1+ (length events)))
         (previous-hash (if events
                            (getf (car (last events)) :event-hash)
                            +zero-sha256+))
         (with-chain (append actor-event
                             (list :seq sequence :previous-hash previous-hash)))
         (event (append with-chain
                        (list :event-hash (%sha256-value with-chain)))))
    (%validate-event event)
    (when (eq (getf event :event) :decision)
      (%validate-decision-against-events store event events))
    (%validate-evaluation-ledger-constraints event events)
    (unless (%verify-event-actors store event)
      (error "Refusing to append an event with invalid actor evidence."))
    ;; Establish both signatures and parser round-trips before pruning or
    ;; writing anything.  A caller-supplied exotic form or an unavailable
    ;; authority key cannot leave the ledger ahead of its signed head.
    (let* ((prospective-head
             (%make-head store sequence (getf event :event-hash)))
           (event-text (%persisted-form-string event "Generated ledger event"))
           (ledger (ledger-path store))
           (content (%read-file-string
                     ledger :maximum-octets +maximum-ledger-octets+))
           (last-newline (position #\Newline content :from-end t))
           (complete-end (if last-newline (1+ last-newline) 0))
           (complete-prefix (subseq content 0 complete-end))
           (projected-octets
             (+ (length (sb-ext:string-to-octets
                         complete-prefix :external-format :utf-8))
                (length (sb-ext:string-to-octets
                         event-text :external-format :utf-8))
                1)))
      (when (> projected-octets +maximum-ledger-octets+)
        (error "Ledger append would exceed the ~D-octet recognition ceiling."
               +maximum-ledger-octets+))
      ;; A crash may leave an incomplete, unsigned final fragment.  Readers
      ;; ignore it by contract; remove only that fragment before the next append.
      (unless (= complete-end (length content))
        (%atomic-write-string ledger complete-prefix))
      (%write-file-string
       ledger
       (concatenate 'string event-text (string #\Newline))
       :if-exists :append)
      (%write-head store sequence (getf event :event-hash) prospective-head))
    event))

;; ------------------------------------------------------------ lifecycle ---

(defun %validate-roster (roster name)
  (unless (%proper-list-p roster)
    (error "~A roster must be a proper list." name))
  (dolist (did roster)
    (unless (%did-key-p did)
      (error "~A roster contains invalid DID ~S." name did)))
  (unless (= (length roster) (length (remove-duplicates roster :test #'string=)))
    (error "~A roster contains duplicates." name))
  (mapcar #'copy-seq roster))

(defun open-evolution-store (path &key authority trusted-executors
                                       trusted-evaluators trusted-authorizers)
  (let* ((authority-did (copy-seq (%identity-did authority)))
         (executors (%validate-roster trusted-executors "Executor"))
         (evaluators (%validate-roster trusted-evaluators "Evaluator"))
         (authorizers (%validate-roster trusted-authorizers "Authorizer")))
    (when (intersection executors evaluators :test #'string=)
      (error "Executor and evaluator trust rosters must be disjoint."))
    (unless authorizers
      (error "At least one trusted authorizer is required."))
    (when (or (intersection authorizers executors :test #'string=)
              (intersection authorizers evaluators :test #'string=))
      (error "Authorizer trust roster must be disjoint from actor rosters."))
    (let* ((root (uiop:ensure-directory-pathname (merge-pathnames path)))
           (store (make-instance 'evolution-store
                                 :root root
                                 :authority authority
                                 :authority-did authority-did
                                 :trusted-executors executors
                                 :trusted-evaluators evaluators
                                 :trusted-authorizers authorizers))
           (root-entry (string-right-trim "/" (namestring root)))
           (root-exists (%path-entry-exists-p root-entry)))
      ;; Reject a pre-existing symlink before any managed path can be opened.
      (when (and root-exists (not (%directory-entry-p root-entry)))
        (error "Evolution store root must be a real directory."))
      (let ((ledger-exists (%path-entry-exists-p (ledger-path store)))
            (head-exists (%path-entry-exists-p (ledger-head-path store))))
        (when (not (eq (not (null ledger-exists)) (not (null head-exists))))
          (error "Evolution store has only one ledger component."))
        ;; For a fresh store, signature construction and self-verification
        ;; precede even directory creation.
        (let ((initial-head
                (unless ledger-exists (%make-head store 0 +zero-sha256+))))
          (unless root-exists
            (ensure-directories-exist (merge-pathnames "anchor" root)))
          (%assert-store-root store)
          (dolist (relative '("candidates/" "pointers/"))
            (let* ((managed (merge-pathnames relative root))
                   (entry (string-right-trim "/" (namestring managed))))
              (cond
                ((%path-entry-exists-p entry)
                 (unless (%directory-entry-p entry)
                   (error "Managed evolution directory ~A is invalid." managed)))
                (t (sb-posix:mkdir entry #o700)))))
          (%assert-managed-directory store "candidates/")
          (%assert-managed-directory store "pointers/")
          (when initial-head
            (%write-file-string (ledger-path store) "")
            (%write-head store 0 +zero-sha256+ initial-head))))
      (unless (and (%regular-file-p (ledger-path store))
                   (%regular-file-p (ledger-head-path store)))
        (error "Evolution ledger components must be regular files."))
      (unless (verify-ledger store)
        (error "Evolution store ledger verification failed."))
      store)))

(defun close-evolution-store (store)
  (check-type store evolution-store)
  t)

;; ------------------------------------------------------------- candidate ---

(defun %candidate-identity-payload (manifest)
  (list :version (getf manifest :version)
        :parent-id (getf manifest :parent-id)
        :parent-image-sha256 (getf manifest :parent-image-sha256)
        :image-file (getf manifest :image-file)
        :image-sha256 (getf manifest :image-sha256)
        :creator-did (getf manifest :creator-did)
        :created-at (getf manifest :created-at)
        :theory-fingerprint (getf manifest :theory-fingerprint)
        :prompt-schema-sha256 (getf manifest :prompt-schema-sha256)
        :tool-schema-sha256 (getf manifest :tool-schema-sha256)
        :changed-components (getf manifest :changed-components)
        :budgets (getf manifest :budgets)
        :activation-evidence (getf manifest :activation-evidence)))

(defun %candidate-id-for-manifest (manifest)
  (concatenate 'string "c-"
               (subseq (%sha256-value (%candidate-identity-payload manifest))
                       0 61)))

(defun read-candidate-manifest (store candidate-id)
  (%read-manifest-form store candidate-id))

(defun candidate-image-path (store candidate-id)
  (let ((manifest (read-candidate-manifest store candidate-id)))
    (merge-pathnames (getf manifest :image-file)
                     (candidate-directory store candidate-id))))

(defun %freeze-event-matches-manifest-p (store event manifest)
  (and
   (handler-case
       (progn
         (%validate-freeze-event event)
         (%verify-event-actors store event))
     (error () nil))
   (string= (getf event :candidate-id) (getf manifest :candidate-id))
   (equal (getf event :parent-id) (getf manifest :parent-id))
   (string= (getf event :image-sha256) (getf manifest :image-sha256))
   (string= (getf event :manifest-sha256) (%sha256-value manifest))
   (string= (getf event :creator-did) (getf manifest :creator-did))
   (string= (getf event :timestamp) (getf manifest :created-at))))

(defun %candidate-freeze-evidence-valid-p (store manifest events)
  (let ((candidate-events
          (remove-if-not
           (lambda (event)
             (and (eq (getf event :event) :freeze)
                  (stringp (getf event :candidate-id))
                  (string= (getf event :candidate-id)
                           (getf manifest :candidate-id))))
           events)))
    (and (= (length candidate-events) 1)
         (%freeze-event-matches-manifest-p
          store (first candidate-events) manifest))))

(defun %verify-candidate-internal (store candidate-id seen events
                                   require-freeze-evidence-p
                                   &optional image-digest-exemption-id)
  (when (member candidate-id seen :test #'string=)
    (error "Candidate lineage contains a cycle."))
  (let* ((manifest (read-candidate-manifest store candidate-id))
         (unsigned (%without-keys manifest '(:creator-signature)))
         (image-path (candidate-image-path store candidate-id)))
    (and
     (string= candidate-id (getf manifest :candidate-id))
     (string= candidate-id (%candidate-id-for-manifest manifest))
     (%verify-value (getf manifest :creator-did) unsigned
                    (getf manifest :creator-signature))
     (or (not require-freeze-evidence-p)
         (%candidate-freeze-evidence-valid-p store manifest events))
     (%regular-file-p image-path)
     (or (and image-digest-exemption-id
              (string= candidate-id image-digest-exemption-id))
         (string= (%sha256-file image-path) (getf manifest :image-sha256)))
     (let ((parent (getf manifest :parent-id)))
       (if (null parent)
           (null (getf manifest :parent-image-sha256))
           (let ((parent-manifest (read-candidate-manifest store parent)))
             (and (string= (getf parent-manifest :image-sha256)
                           (getf manifest :parent-image-sha256))
                  (%verify-candidate-internal store parent
                                              (cons candidate-id seen)
                                              events
                                              require-freeze-evidence-p
                                              image-digest-exemption-id))))))))

(defun %verify-candidate-with-events (store candidate-id events)
  (%verify-candidate-internal store candidate-id nil events t))

(defun %verify-rollback-candidate (store prior-id current-id events)
  ;; CURRENT may occur in PRIOR's ancestor chain.  Keep all manifest, freeze,
  ;; lineage, and file-type checks, but exempt exactly CURRENT's image digest.
  (%verify-candidate-internal store prior-id nil events t current-id))

(defun %verify-candidate-files (store candidate-id)
  ;; Used only after a new immutable directory is fully materialized but
  ;; before its freeze event can exist.  Persisted callers must use the
  ;; evidence-requiring verifier above.
  (%verify-candidate-internal store candidate-id nil nil nil))

(defun verify-candidate (store candidate-id)
  (handler-case
      (sb-thread:with-mutex ((store-lock store))
        (%verify-candidate-with-events
         store candidate-id (%read-ledger-unlocked store)))
    (error () nil)))

(defun %require-freeze-field (present key)
  (unless present (error "Freeze requires ~S." key)))

(defun freeze-candidate! (store source-image
                          &key
                            (parent-id nil parent-id-p)
                            (parent-image-sha256 nil parent-image-sha256-p)
                            (creator nil creator-p)
                            (created-at nil created-at-p)
                            (theory-fingerprint nil theory-fingerprint-p)
                            (prompt-schema-sha256 nil prompt-schema-p)
                            (tool-schema-sha256 nil tool-schema-p)
                            (changed-components nil changed-components-p)
                            (budgets nil budgets-p)
                            (activation-evidence nil activation-evidence-p))
  (declare (ignore parent-id-p parent-image-sha256-p))
  (dolist (required (list (cons creator-p :creator)
                          (cons created-at-p :created-at)
                          (cons theory-fingerprint-p :theory-fingerprint)
                          (cons prompt-schema-p :prompt-schema-sha256)
                          (cons tool-schema-p :tool-schema-sha256)
                          (cons changed-components-p :changed-components)
                          (cons budgets-p :budgets)
                          (cons activation-evidence-p :activation-evidence)))
    (%require-freeze-field (car required) (cdr required)))
  (unless (%regular-file-p source-image)
    (error "Candidate source image must be a regular file."))
  (unless (or (and (null parent-id) (null parent-image-sha256))
              (and (%candidate-id-p parent-id)
                   (%sha256-p parent-image-sha256)))
    (error "Parent identifier and digest must be present together."))
  (unless (%utc-string-p created-at)
    (error "Freeze creation time is invalid."))
  (dolist (pair (list (cons :theory-fingerprint theory-fingerprint)
                      (cons :prompt-schema-sha256 prompt-schema-sha256)
                      (cons :tool-schema-sha256 tool-schema-sha256)))
    (unless (%sha256-p (cdr pair))
      (error "Freeze field ~S must be SHA-256." (car pair))))
  (unless (%sorted-unique-strings-p changed-components)
    (error "Changed components must be sorted and unique."))
  (%validate-budgets budgets)
  (unless (%sorted-unique-strings-p activation-evidence)
    (error "Activation evidence must be sorted and unique."))
  (let ((creator-did (%identity-did creator)))
    (sb-thread:with-mutex ((store-lock store))
      (let ((events (%read-ledger-unlocked store)))
        ;; Candidate materialization precedes its freeze event, so establish
        ;; that the authority can sign a self-verifying head before copying any
        ;; image or manifest bytes.
        (%make-head store 0 +zero-sha256+)
        (when parent-id
          (unless (and (%verify-candidate-with-events store parent-id events)
                       (string= parent-image-sha256
                                (getf (read-candidate-manifest store parent-id)
                                      :image-sha256)))
            (error "Parent candidate is missing or its digest differs.")))
        (let* ((image-sha256 (%sha256-file source-image))
               (identity-fields
                 (list :version 1
                       :parent-id parent-id
                       :parent-image-sha256 parent-image-sha256
                       :image-file +candidate-image-file+
                       :image-sha256 image-sha256
                       :creator-did creator-did
                       :created-at created-at
                       :theory-fingerprint theory-fingerprint
                       :prompt-schema-sha256 prompt-schema-sha256
                       :tool-schema-sha256 tool-schema-sha256
                       :changed-components changed-components
                       :budgets budgets
                       :activation-evidence activation-evidence))
               (candidate-id (%candidate-id-for-manifest identity-fields))
               (unsigned-manifest
                 (list :version 1
                       :candidate-id candidate-id
                       :parent-id parent-id
                       :parent-image-sha256 parent-image-sha256
                       :image-file +candidate-image-file+
                       :image-sha256 image-sha256
                       :creator-did creator-did
                       :created-at created-at
                       :theory-fingerprint theory-fingerprint
                       :prompt-schema-sha256 prompt-schema-sha256
                       :tool-schema-sha256 tool-schema-sha256
                       :changed-components changed-components
                       :budgets budgets
                       :activation-evidence activation-evidence))
               (signature (%sign-value creator unsigned-manifest))
               (manifest
                 (append (subseq unsigned-manifest 0 14)
                         (list :creator-signature signature)
                         (nthcdr 14 unsigned-manifest)))
               (manifest-text
                 (%persisted-form-string manifest "Generated candidate manifest"))
               (directory (candidate-directory store candidate-id))
               (directory-name (string-right-trim "/" (namestring directory)))
               (created-directory nil))
          (%validate-manifest manifest)
          (when (find-if
                 (lambda (event)
                   (and (eq (getf event :event) :freeze)
                        (string= candidate-id (getf event :candidate-id))))
                 events)
            (error "Candidate ~A already has persisted freeze evidence."
                   candidate-id))
          (when (%path-entry-exists-p directory-name)
            (error "Candidate ~A already exists." candidate-id))
          (unwind-protect
               (progn
                 (sb-posix:mkdir directory-name #o700)
                 (setf created-directory t)
                 (let ((frozen-image
                         (%copy-binary-file
                          source-image
                          (merge-pathnames +candidate-image-file+ directory))))
                   (unless (string= image-sha256 (%sha256-file frozen-image))
                     (error "Source image changed while the candidate was copied.")))
                 (%atomic-write-string
                  (merge-pathnames +manifest-file+ directory)
                  (concatenate 'string manifest-text (string #\Newline)))
                 (unless (%verify-candidate-files store candidate-id)
                   (error "Materialized candidate failed pre-freeze verification."))
                 (let* ((event-payload
                          (list :event :freeze
                                :timestamp created-at
                                :candidate-id candidate-id
                                :parent-id parent-id
                                :image-sha256 image-sha256
                                :manifest-sha256 (%sha256-value manifest)
                                :creator-did creator-did))
                        (event-signature (%sign-value creator event-payload))
                        (actor-event
                          (append event-payload
                                  (list :creator-signature event-signature))))
                   (%append-event-unlocked store actor-event events))
                 (setf created-directory nil)
                 manifest)
            (when created-directory
              (ignore-errors
                (uiop:delete-directory-tree directory
                                            :validate t
                                            :if-does-not-exist :ignore)))))))))

;; ------------------------------------------------------------ evaluation ---

(defun %trusted-identity-did (identity roster role)
  (let ((did (%identity-did identity)))
    (unless (member did roster :test #'string=)
      (error "~A DID is not enrolled in its trusted roster." role))
    did))

(defun record-evaluation! (store &key run-id campaign-id benchmark-id split
                                      task-id replicate-index
                                      evaluation-plan-sha256
                                      executor-config-sha256
                                      scorer-config-sha256 candidate-id
                                      executor evaluator
                                      (run-complete-p nil run-complete-p-supplied-p)
                                      task-correct-p
                                      capability-score-micros activation-evidence
                                      duration-ms input-tokens output-tokens
                                      estimated-cost-microusd)
  (%require-candidate-id candidate-id)
  (dolist (pair (list (cons :run-id run-id)
                      (cons :campaign-id campaign-id)
                      (cons :benchmark-id benchmark-id)
                      (cons :task-id task-id)))
    (unless (%safe-string-p (cdr pair) :nonempty t :ascii t)
      (error "Evaluation identifier ~S is invalid." (car pair))))
  (unless (member split '(:feedback :development :selection :held-out))
    (error "Evaluation split is invalid."))
  (unless run-complete-p-supplied-p
    (error "Evaluation requires :RUN-COMPLETE-P."))
  (unless (and (integerp replicate-index) (plusp replicate-index))
    (error "Replicate index must be positive."))
  (dolist (pair (list (cons :evaluation-plan-sha256 evaluation-plan-sha256)
                      (cons :executor-config-sha256 executor-config-sha256)
                      (cons :scorer-config-sha256 scorer-config-sha256)))
    (unless (%sha256-p (cdr pair))
      (error "Evaluation configuration ~S must be SHA-256." (car pair))))
  (dolist (pair (list (cons :run-complete-p run-complete-p)
                      (cons :task-correct-p task-correct-p)))
    (unless (member (cdr pair) '(nil t))
      (error "Evaluation field ~S must be Boolean." (car pair))))
  (dolist (pair (list (cons :capability-score-micros capability-score-micros)
                      (cons :duration-ms duration-ms)
                      (cons :input-tokens input-tokens)
                      (cons :output-tokens output-tokens)
                      (cons :estimated-cost-microusd estimated-cost-microusd)))
    (unless (%bounded-source-integer-p (cdr pair))
      (error "Evaluation field ~S must be nonnegative." (car pair))))
  (%validate-activation-evidence activation-evidence)
  (let ((executor-did (%trusted-identity-did
                       executor (store-trusted-executors store) "Executor"))
        (evaluator-did (%trusted-identity-did
                        evaluator (store-trusted-evaluators store) "Evaluator")))
    (sb-thread:with-mutex ((store-lock store))
      (let* ((events (%read-ledger-unlocked store))
             (manifest (read-candidate-manifest store candidate-id))
             (creator-did (getf manifest :creator-did)))
        (unless (%verify-candidate-with-events store candidate-id events)
          (error "Candidate verification failed before evaluation."))
        (when (find-if
               (lambda (event)
                 (and (eq (getf event :event) :evaluation)
                      (string= run-id (getf event :run-id))))
               events)
          (error "Run identifier ~S already exists." run-id))
        (when (eq split :held-out)
          (unless (= 3 (length (remove-duplicates
                                (list creator-did executor-did evaluator-did)
                                :test #'string=)))
            (error "Held-out creator, executor, and evaluator must differ.")))
        (let* ((payload
                 (list :event :evaluation
                       :timestamp (anuna-imago:iso-8601-now)
                       :candidate-id candidate-id
                       :run-id run-id
                       :campaign-id campaign-id
                       :benchmark-id benchmark-id
                       :split split
                       :task-id task-id
                       :replicate-index replicate-index
                       :evaluation-plan-sha256 evaluation-plan-sha256
                       :executor-config-sha256 executor-config-sha256
                       :scorer-config-sha256 scorer-config-sha256
                       :executor-did executor-did
                       :evaluator-did evaluator-did
                       :run-complete-p run-complete-p
                       :task-correct-p task-correct-p
                       :capability-score-micros capability-score-micros
                       :activation-evidence activation-evidence
                       :duration-ms duration-ms
                       :input-tokens input-tokens
                       :output-tokens output-tokens
                       :estimated-cost-microusd estimated-cost-microusd))
               (executor-signature (%sign-value executor payload))
               (evaluator-signature (%sign-value evaluator payload))
               (actor-event
                 (append payload
                         (list :executor-signature executor-signature
                               :evaluator-signature evaluator-signature))))
          (%append-event-unlocked store actor-event events))))))

;; -------------------------------------------------------------- decision ---

(defun %sum-field (events key)
  (reduce #'+ events :key (lambda (event) (getf event key))
          :initial-value 0))

(defun %integer-mean (total count)
  (if (plusp count) (truncate total count) 0))

(defun %mean-micros (events)
  (%integer-mean (%sum-field events :capability-score-micros)
                 (length events)))

(defun %execution-token-total (events)
  (reduce #'+ events
          :key (lambda (event)
                 (+ (getf event :input-tokens)
                    (getf event :output-tokens)))
          :initial-value 0))

(defun %canonical-multiset (values)
  (%canonical-sort values))

(defun %comparison-cell-multiset (events)
  (%canonical-multiset (mapcar #'%comparison-cell events)))

(defun %comparison-cells-match-p (baseline-events candidate-events)
  (and baseline-events candidate-events
       (equal (%comparison-cell-multiset baseline-events)
              (%comparison-cell-multiset candidate-events))))

(defun %candidate-cells-unique-p (events)
  (= (length events)
     (length (remove-duplicates events :key #'%comparison-cell
                                       :test #'equal))))

(defun %replicate-indices (events)
  (sort (remove-duplicates
         (mapcar (lambda (event) (getf event :replicate-index)) events))
        #'<))

(defun %events-for-replicate (events replicate-index)
  (remove replicate-index events
          :key (lambda (event) (getf event :replicate-index))
          :test-not #'=))

(defun %protocol-template-cell (event)
  ;; Actor identities deliberately remain comparison-cell fields but are not
  ;; protocol-template fields: actors may rotate between true replicates.
  (list :campaign-id (getf event :campaign-id)
        :evaluation-plan-sha256 (getf event :evaluation-plan-sha256)
        :benchmark-id (getf event :benchmark-id)
        :task-id (getf event :task-id)
        :executor-config-sha256 (getf event :executor-config-sha256)
        :scorer-config-sha256 (getf event :scorer-config-sha256)))

(defun %replicate-template (events replicate-index)
  (%canonical-multiset
   (mapcar #'%protocol-template-cell
           (%events-for-replicate events replicate-index))))

(defun %replicate-templates-match-p (baseline-events candidate-events)
  (let ((baseline-indices (%replicate-indices baseline-events))
        (candidate-indices (%replicate-indices candidate-events)))
    (and baseline-indices
         (equal baseline-indices candidate-indices)
         (let* ((indices baseline-indices)
                (reference (%replicate-template baseline-events
                                                (first indices))))
           (and reference
                (every (lambda (index)
                         (and (equal reference
                                     (%replicate-template baseline-events index))
                              (equal reference
                                     (%replicate-template candidate-events index))))
                       indices))))))

(defun %complete-replicate-indices (baseline-events candidate-events)
  (when (and (%comparison-cells-match-p baseline-events candidate-events)
             (%replicate-templates-match-p baseline-events candidate-events))
    (let ((candidate-indices (%replicate-indices candidate-events)))
      (loop for index in (%replicate-indices baseline-events)
            for baseline = (%events-for-replicate baseline-events index)
            for candidate = (%events-for-replicate candidate-events index)
            when (and (member index candidate-indices)
                      baseline candidate
                      (every (lambda (event) (getf event :run-complete-p))
                             baseline)
                      (every (lambda (event) (getf event :run-complete-p))
                             candidate))
              collect index))))

(defun %replicate-capability-deltas (baseline-events candidate-events)
  (when (%comparison-cells-match-p baseline-events candidate-events)
    (loop for index in (%replicate-indices baseline-events)
          for baseline-mean = (%mean-micros
                               (%events-for-replicate baseline-events index))
          for candidate-mean = (%mean-micros
                                (%events-for-replicate candidate-events index))
          collect (list :replicate-index index
                        :baseline-capability-mean-micros baseline-mean
                        :candidate-capability-mean-micros candidate-mean
                        :capability-delta-micros
                        (- candidate-mean baseline-mean)))))

(defun %executor-config-key (event)
  (list (getf event :executor-did)
        (getf event :executor-config-sha256)))

(defun %events-for-executor-config (events key)
  (remove key events :key #'%executor-config-key :test-not #'equal))

(defun %executor-config-capability-deltas (baseline-events candidate-events)
  (when (%comparison-cells-match-p baseline-events candidate-events)
    (let ((keys (remove-duplicates
                 (mapcar #'%executor-config-key baseline-events)
                 :test #'equal)))
      (sort
       (loop for key in keys
             for baseline-mean =
               (%mean-micros (%events-for-executor-config baseline-events key))
             for candidate-mean =
               (%mean-micros (%events-for-executor-config candidate-events key))
             collect (list :executor-did (first key)
                           :executor-config-sha256 (second key)
                           :baseline-capability-mean-micros baseline-mean
                           :candidate-capability-mean-micros candidate-mean
                           :capability-delta-micros
                           (- candidate-mean baseline-mean)))
       #'%executor-delta<))))

(defun %distinct-executor-count (events)
  (length (remove-duplicates
           (mapcar (lambda (event) (getf event :executor-did)) events)
           :test #'string=)))

(defun %correctness-retained-p (baseline-events candidate-events)
  (and baseline-events candidate-events
       (every
        (lambda (baseline)
          (or (not (getf baseline :task-correct-p))
              (let ((candidate
                      (find (%comparison-cell baseline) candidate-events
                            :key #'%comparison-cell :test #'equal)))
                (and candidate (getf candidate :task-correct-p)))))
        baseline-events)))

(defun %event-role-separation-p (store event)
  (let* ((manifest (read-candidate-manifest store (getf event :candidate-id)))
         (creator (getf manifest :creator-did))
         (executor (getf event :executor-did))
         (evaluator (getf event :evaluator-did)))
    (= 3 (length (remove-duplicates (list creator executor evaluator)
                                     :test #'string=)))))

(defun %candidate-valid-p (store candidate-id ledger-events)
  (handler-case
      (not (null (%verify-candidate-with-events
                  store candidate-id ledger-events)))
    (error () nil)))

(defun %require-anchored-candidate-context (store candidate-id events
                                            &optional seen)
  (when (member candidate-id seen :test #'string=)
    (error "Candidate history contains a lineage cycle."))
  (let* ((manifest (read-candidate-manifest store candidate-id))
         (unsigned (%without-keys manifest '(:creator-signature))))
    (unless (and (string= candidate-id (getf manifest :candidate-id))
                 (string= candidate-id (%candidate-id-for-manifest manifest))
                 (%verify-value (getf manifest :creator-did) unsigned
                                (getf manifest :creator-signature))
                 (%candidate-freeze-evidence-valid-p store manifest events))
      (error "Candidate ~A lacks its anchored signed freeze context."
             candidate-id))
    (let ((parent (getf manifest :parent-id)))
      (when parent
        (let ((parent-manifest
                (%require-anchored-candidate-context
                 store parent events (cons candidate-id seen))))
          (unless (string= (getf manifest :parent-image-sha256)
                           (getf parent-manifest :image-sha256))
            (error "Candidate ~A has inconsistent historical lineage."
                   candidate-id)))))
    manifest))

(defun %single-evaluation-plan-context-p (events)
  (and events
       (= 1 (length
             (remove-duplicates
              (mapcar (lambda (event)
                        (getf event :evaluation-plan-sha256))
                      events)
              :test #'string=)))))

(defun %changed-components-activated-p (store candidate-id selected-events)
  (handler-case
      (let* ((manifest (read-candidate-manifest store candidate-id))
             (image-digest (getf manifest :image-sha256))
             (candidate-events
               (remove candidate-id selected-events
                       :key (lambda (event) (getf event :candidate-id))
                       :test-not #'string=))
             (activated
               (remove-duplicates
                (loop for event in candidate-events
                      append
                      (loop for record in (getf event :activation-evidence)
                            when (and (eq (getf record :kind) :runtime-hit)
                                      (string=
                                       (getf record :artifact-sha256)
                                       image-digest))
                              collect (getf record :component)))
                :test #'string=)))
        (every (lambda (component)
                 (member component activated :test #'string=))
               (getf manifest :changed-components)))
    (error () nil)))

(defun %authorizer-rosters-disjoint-p (store)
  (and (null (intersection (store-trusted-authorizers store)
                           (store-trusted-executors store) :test #'string=))
       (null (intersection (store-trusted-authorizers store)
                           (store-trusted-evaluators store) :test #'string=))))

(defun %authorizer-creators-separated-p (store baseline-id candidate-id
                                         authorizer-did)
  (handler-case
      (and (not (string= authorizer-did
                         (getf (read-candidate-manifest store baseline-id)
                               :creator-did)))
           (not (string= authorizer-did
                         (getf (read-candidate-manifest store candidate-id)
                               :creator-did))))
    (error () nil)))

(defun %decision-gates (store baseline-id candidate-id ledger-events
                        baseline-events candidate-events minimum-repetitions
                        minimum-executors minimum-delta maximum-token-increase
                        maximum-cost-increase authorizer-did replicate-deltas
                        conservative-delta executor-deltas token-delta cost-delta
                        trusted-authorizer-signature-p
                        &optional historical-digest-gates)
  (let* ((candidate-valid
           (if historical-digest-gates
               (getf historical-digest-gates :candidate-digest-valid)
               (%candidate-valid-p store candidate-id ledger-events)))
         (baseline-valid
           (if historical-digest-gates
               (getf historical-digest-gates :baseline-digest-valid)
               (%candidate-valid-p store baseline-id ledger-events)))
         (selected (append baseline-events candidate-events)))
    (list
      :candidate-digest-valid candidate-valid
      :baseline-digest-valid baseline-valid
      :comparison-cells-match
      (%comparison-cells-match-p baseline-events candidate-events)
      :candidate-cells-unique
      (and candidate-events (%candidate-cells-unique-p candidate-events))
      :single-evaluation-plan-context
      (%single-evaluation-plan-context-p selected)
      :replicate-templates-match
      (%replicate-templates-match-p baseline-events candidate-events)
      :minimum-held-out-repetitions-met
      (and (%replicate-templates-match-p baseline-events candidate-events)
           (>= (length (%complete-replicate-indices
                        baseline-events candidate-events))
               minimum-repetitions))
      :minimum-distinct-executors-met
      (and (%comparison-cells-match-p baseline-events candidate-events)
           (>= (%distinct-executor-count baseline-events) minimum-executors))
      :correctness-retained
      (%correctness-retained-p baseline-events candidate-events)
      :changed-components-activated
      (%changed-components-activated-p store candidate-id selected)
      :runs-complete
      (and selected
           (every (lambda (event) (getf event :run-complete-p)) selected))
      :creator-evaluator-separated
      (and selected
           (every (lambda (event)
                    (let ((creator
                            (getf (read-candidate-manifest
                                   store (getf event :candidate-id))
                                  :creator-did)))
                      (not (string= creator (getf event :evaluator-did)))))
                  selected))
      :roles-pairwise-distinct
      (and selected
           (every (lambda (event) (%event-role-separation-p store event))
                  selected))
      :trusted-actor-signatures
      (and selected
           (every (lambda (event)
                    (%verify-event-actors store event))
                  selected))
      :replicate-capability-delta-met
      (and replicate-deltas (>= conservative-delta minimum-delta))
      :per-executor-config-capability-delta-met
      (and executor-deltas
           (every (lambda (record)
                    (>= (getf record :capability-delta-micros) minimum-delta))
                  executor-deltas))
      :execution-token-increase-within-limit
      (<= token-delta maximum-token-increase)
      :runtime-cost-increase-within-limit
      (<= cost-delta maximum-cost-increase)
      :authorizer-rosters-disjoint
      (%authorizer-rosters-disjoint-p store)
      :authorizer-creators-separated
      (%authorizer-creators-separated-p store baseline-id candidate-id
                                        authorizer-did)
      :trusted-authorizer-signature
      (not (null trusted-authorizer-signature-p)))))

(defparameter +decision-derived-keys+
  '(:gates :failed-gates
    :baseline-capability-mean-micros :candidate-capability-mean-micros
    :capability-delta-micros :replicate-capability-deltas
    :conservative-capability-delta-micros :executor-capability-deltas
    :baseline-execution-tokens-total :candidate-execution-tokens-total
    :baseline-execution-tokens-mean-per-event
    :candidate-execution-tokens-mean-per-event :execution-token-delta
    :baseline-runtime-cost-microusd-total
    :candidate-runtime-cost-microusd-total
    :baseline-runtime-cost-microusd-mean-per-event
    :candidate-runtime-cost-microusd-mean-per-event
    :runtime-cost-delta-microusd :development-cost-microusd :eligible-p))

(defun %held-out-comparison-events (events campaign-id baseline-id candidate-id)
  (remove-if-not
   (lambda (event)
     (and (eq (getf event :event) :evaluation)
          (eq (getf event :split) :held-out)
          (string= (getf event :campaign-id) campaign-id)
          (member (getf event :candidate-id)
                  (list baseline-id candidate-id) :test #'string=)))
   events))

(defun %candidate-events (events candidate-id)
  (remove candidate-id events
          :key (lambda (event) (getf event :candidate-id))
          :test-not #'string=))

(defun %decision-analysis (store baseline-id candidate-id campaign-id events
                           minimum-repetitions minimum-executors minimum-delta
                           maximum-token-increase maximum-cost-increase
                           authorizer-did trusted-authorizer-signature-p
                           &optional historical-digest-gates)
  (let* ((held-out (%held-out-comparison-events
                    events campaign-id baseline-id candidate-id))
         (baseline-events (%candidate-events held-out baseline-id))
         (candidate-events (%candidate-events held-out candidate-id))
         (baseline-mean (%mean-micros baseline-events))
         (candidate-mean (%mean-micros candidate-events))
         (delta (- candidate-mean baseline-mean))
         (replicate-deltas
           (%replicate-capability-deltas baseline-events candidate-events))
         (conservative-delta
           (if replicate-deltas
               (reduce #'min replicate-deltas
                       :key (lambda (record)
                              (getf record :capability-delta-micros)))
               0))
         (executor-deltas
           (%executor-config-capability-deltas baseline-events candidate-events))
         (baseline-tokens (%execution-token-total baseline-events))
         (candidate-tokens (%execution-token-total candidate-events))
         (baseline-token-mean
           (%integer-mean baseline-tokens (length baseline-events)))
         (candidate-token-mean
           (%integer-mean candidate-tokens (length candidate-events)))
         (token-delta (- candidate-tokens baseline-tokens))
         (baseline-cost (%sum-field baseline-events :estimated-cost-microusd))
         (candidate-cost (%sum-field candidate-events :estimated-cost-microusd))
         (baseline-cost-mean
           (%integer-mean baseline-cost (length baseline-events)))
         (candidate-cost-mean
           (%integer-mean candidate-cost (length candidate-events)))
         (cost-delta (- candidate-cost baseline-cost))
         (gates
           (%decision-gates
            store baseline-id candidate-id events baseline-events candidate-events
            minimum-repetitions minimum-executors minimum-delta
            maximum-token-increase maximum-cost-increase authorizer-did
            replicate-deltas conservative-delta executor-deltas token-delta
            cost-delta trusted-authorizer-signature-p historical-digest-gates))
         (failed-gates
           (loop for (key value) on gates by #'cddr
                 unless value collect key))
         (development-cost
           (getf (getf (read-candidate-manifest store candidate-id) :budgets)
                 :development-cost-microusd)))
    (list :gates gates
          :failed-gates failed-gates
          :baseline-capability-mean-micros baseline-mean
          :candidate-capability-mean-micros candidate-mean
          :capability-delta-micros delta
          :replicate-capability-deltas replicate-deltas
          :conservative-capability-delta-micros conservative-delta
          :executor-capability-deltas executor-deltas
          :baseline-execution-tokens-total baseline-tokens
          :candidate-execution-tokens-total candidate-tokens
          :baseline-execution-tokens-mean-per-event baseline-token-mean
          :candidate-execution-tokens-mean-per-event candidate-token-mean
          :execution-token-delta token-delta
          :baseline-runtime-cost-microusd-total baseline-cost
          :candidate-runtime-cost-microusd-total candidate-cost
          :baseline-runtime-cost-microusd-mean-per-event baseline-cost-mean
          :candidate-runtime-cost-microusd-mean-per-event candidate-cost-mean
          :runtime-cost-delta-microusd cost-delta
          :development-cost-microusd development-cost
          :eligible-p (null failed-gates))))

(defun %validate-decision-against-events (store decision prior-events
                                          &key historical-p)
  (%validate-decision-event decision)
  (%require-anchored-candidate-context
   store (getf decision :baseline-id) prior-events)
  (%require-anchored-candidate-context
   store (getf decision :candidate-id) prior-events)
  (let ((expected
          (%decision-analysis
           store (getf decision :baseline-id) (getf decision :candidate-id)
           (getf decision :campaign-id) prior-events
           (getf decision :minimum-held-out-repetitions)
           (getf decision :minimum-distinct-executors)
           (getf decision :minimum-capability-delta-micros)
           (getf decision :maximum-execution-token-increase)
           (getf decision :maximum-runtime-cost-increase-microusd)
           (getf decision :authorizer-did)
           (%verify-event-actors store decision)
           (and historical-p (getf decision :gates)))))
    (dolist (key +decision-derived-keys+)
      (unless (equal (getf decision key) (getf expected key))
        (error "Decision field ~S does not match its signed evidence prefix."
               key))))
  decision)

(defun make-decision! (store baseline-id candidate-id
                       &key campaign-id
                            (minimum-held-out-repetitions 3)
                            (minimum-distinct-executors 2)
                            (minimum-capability-delta-micros 1)
                            (maximum-execution-token-increase 0)
                            (maximum-runtime-cost-increase-microusd 0)
                            authorizer)
  (%require-candidate-id baseline-id)
  (%require-candidate-id candidate-id)
  (when (string= baseline-id candidate-id)
    (error "Baseline and candidate identifiers must differ."))
  (unless (%safe-string-p campaign-id :nonempty t :ascii t)
    (error "Decision campaign identifier is invalid."))
  (unless (and (integerp minimum-held-out-repetitions)
               (>= minimum-held-out-repetitions 2))
    (error "Held-out repetition minimum must be at least two."))
  (unless (and (integerp minimum-distinct-executors)
               (>= minimum-distinct-executors 2))
    (error "Distinct executor minimum must be at least two."))
  (unless (and (integerp minimum-capability-delta-micros)
               (plusp minimum-capability-delta-micros))
    (error "Minimum capability delta must be positive."))
  (unless (%nonnegative-integer-p maximum-execution-token-increase)
    (error "Maximum execution-token increase must be nonnegative."))
  (unless (%nonnegative-integer-p maximum-runtime-cost-increase-microusd)
    (error "Maximum runtime-cost increase must be nonnegative."))
  (let ((authorizer-did
          (%trusted-identity-did authorizer
                                 (store-trusted-authorizers store)
                                 "Authorizer")))
    (sb-thread:with-mutex ((store-lock store))
      (let* ((events (%read-ledger-unlocked store))
             (baseline-manifest
               (%require-anchored-candidate-context
                store baseline-id events))
             (candidate-manifest
               (%require-anchored-candidate-context
                store candidate-id events))
             (head (if events
                       (getf (car (last events)) :event-hash)
                       +zero-sha256+))
             (analysis
               (%decision-analysis
                store baseline-id candidate-id campaign-id events
                minimum-held-out-repetitions minimum-distinct-executors
                minimum-capability-delta-micros
                maximum-execution-token-increase
                maximum-runtime-cost-increase-microusd authorizer-did t))
             (payload
               (append
                (list :event :decision
                      :timestamp (anuna-imago:iso-8601-now)
                      :candidate-id candidate-id
                      :baseline-id baseline-id
                      :campaign-id campaign-id
                      :evidence-head head
                      :minimum-held-out-repetitions
                      minimum-held-out-repetitions
                      :minimum-distinct-executors minimum-distinct-executors
                      :minimum-capability-delta-micros
                      minimum-capability-delta-micros
                      :maximum-execution-token-increase
                      maximum-execution-token-increase
                      :maximum-runtime-cost-increase-microusd
                      maximum-runtime-cost-increase-microusd)
                analysis
                (list :authorizer-did authorizer-did)))
             (signature (%sign-value authorizer payload))
             (actor-event
               (append payload (list :authorization-signature signature))))
        (declare (ignore baseline-manifest candidate-manifest))
        (%append-event-unlocked store actor-event events)))))

;; -------------------------------------------------------------- pointers ---

(defun %pointer-keyword (pointer)
  (let ((name (%pointer-name pointer)))
    (cond ((string= name "canary") :canary)
          ((string= name "active") :active)
          (t (error "Unsupported evolution pointer ~S." pointer)))))

(defun %read-pointer-form (store pointer)
  (let* ((keyword (%pointer-keyword pointer))
         (path (pointer-path store keyword)))
    (when (%path-entry-exists-p path)
      (unless (%regular-file-p path)
        (error "Evolution pointer is not a regular file."))
      (%validate-pointer-form
       (%read-one-form-file path "Evolution pointer") keyword))))

(defun %latest-pointer-event (pointer events)
  (loop with latest = nil
        for event in events
        when (and (member (getf event :event) '(:promotion :rollback))
                  (eq (getf event :pointer) pointer))
          do (setf latest event)
        finally (return latest)))

(defun %pointer-corresponds-to-events-p (form events)
  (let ((latest (%latest-pointer-event (getf form :pointer) events)))
    (and latest
         (string= (getf latest :event-hash) (getf form :event-hash))
         (eq (getf latest :pointer) (getf form :pointer))
         (string= (getf latest :candidate-id) (getf form :candidate-id))
         (equal (getf latest :prior-candidate-id)
                (getf form :prior-candidate-id)))))

(defun read-pointer (store pointer)
  (sb-thread:with-mutex ((store-lock store))
    ;; Validate the signed evidence root even when the pointer is absent.  A
    ;; corrupt ledger or head can never be downgraded into a diagnostic pointer
    ;; success; this observer has no repair or write path.
    (let ((events (%read-ledger-unlocked store))
          (form (%read-pointer-form store pointer)))
      (cond
        (form
         (unless (%pointer-corresponds-to-events-p form events)
           (error "Pointer does not correspond to latest signed ledger evidence."))
         (getf form :candidate-id))
        ((%latest-pointer-event (%pointer-keyword pointer) events)
         (error "Signed pointer evidence exists but its pointer file is absent."))
        (t nil)))))

(defun %write-pointer (store pointer candidate-id prior-id event-hash)
  (%atomic-write-string
   (pointer-path store pointer)
   (concatenate
    'string
    (%persisted-form-string
     (list :version 1
           :pointer (%pointer-keyword pointer)
           :candidate-id candidate-id
           :prior-candidate-id prior-id
           :event-hash event-hash)
     "Generated evolution pointer")
    (string #\Newline))))

(defun %require-external-authorizer (store identity)
  (when anuna-imago:*current-agent*
    (error "Candidate agent context cannot operate promotion pointers."))
  (%trusted-identity-did identity
                         (store-trusted-authorizers store)
                         "Authorizer"))

(defun promote-candidate! (store decision &key pointer authorizer)
  (let* ((pointer (%pointer-keyword pointer))
         (authorizer-did (%require-external-authorizer store authorizer)))
    (sb-thread:with-mutex ((store-lock store))
      (let* ((events (%read-ledger-unlocked store))
             (last-event (car (last events))))
        (%validate-decision-event decision)
        (unless (and last-event
                     (eq (getf last-event :event) :decision)
                     (equal decision last-event)
                     (string= (getf decision :event-hash)
                              (getf last-event :event-hash)))
          (error "Promotion decision is stale or absent from the ledger head."))
        (unless (getf decision :eligible-p)
          (error "An ineligible decision cannot be promoted."))
        (unless (string= authorizer-did (getf decision :authorizer-did))
          (error "Promotion authorizer differs from the decision signer."))
        (unless (and (%verify-candidate-with-events
                      store (getf decision :candidate-id) events)
                     (%verify-candidate-with-events
                      store (getf decision :baseline-id) events))
          (error "Promotion candidate or baseline no longer verifies."))
        (let* ((prior-form (%read-pointer-form store pointer))
               (prior
                 (cond
                   (prior-form
                    (unless (%pointer-corresponds-to-events-p prior-form events)
                      (error "Pointer does not correspond to latest signed ledger evidence."))
                   (getf prior-form :candidate-id))
                   ((%latest-pointer-event pointer events)
                    (error "Signed pointer evidence exists but its pointer file is absent."))
                   (t nil))))
          (when (and prior
                     (string= prior (getf decision :candidate-id)))
            (error "A promotion must change the selected candidate."))
          (let* ((payload
                 (list :event :promotion
                       :timestamp (anuna-imago:iso-8601-now)
                       :candidate-id (getf decision :candidate-id)
                       :pointer pointer
                       :prior-candidate-id prior
                       :evidence-head (getf last-event :event-hash)
                       :authorizer-did authorizer-did))
               (signature (%sign-value authorizer payload))
               (event (%append-event-unlocked
                       store
                       (append payload (list :authorizer-signature signature))
                       events)))
          (%write-pointer store pointer (getf decision :candidate-id) prior
                          (getf event :event-hash))
          event))))))

(defun rollback-pointer! (store pointer &key authorizer)
  (let* ((pointer (%pointer-keyword pointer))
         (authorizer-did (%require-external-authorizer store authorizer)))
    (sb-thread:with-mutex ((store-lock store))
      (let* ((events (%read-ledger-unlocked store))
             (form (%read-pointer-form store pointer)))
        (unless form (error "Pointer ~S has no promotion to roll back." pointer))
        (unless (%pointer-corresponds-to-events-p form events)
          (error "Rollback pointer lacks signed ledger provenance."))
        (let ((current (getf form :candidate-id))
              (prior (getf form :prior-candidate-id)))
          (unless prior
            (error "Pointer ~S has no recorded prior candidate." pointer))
          ;; Rollback is the recovery path for a corrupt current image.  The
          ;; signed pointer and ledger establish CURRENT; only the recovery
          ;; target must still pass present-time candidate verification.
          (unless (%verify-rollback-candidate store prior current events)
            (error "Rollback candidate verification failed."))
          (let* ((payload
                   (list :event :rollback
                         :timestamp (anuna-imago:iso-8601-now)
                         :candidate-id prior
                         :pointer pointer
                         :prior-candidate-id current
                         :evidence-head
                         (if events
                             (getf (car (last events)) :event-hash)
                             +zero-sha256+)
                         :authorizer-did authorizer-did))
                 (signature (%sign-value authorizer payload))
                 (event (%append-event-unlocked
                         store
                         (append payload (list :authorizer-signature signature))
                         events)))
            (%write-pointer store pointer prior current (getf event :event-hash))
            event))))))

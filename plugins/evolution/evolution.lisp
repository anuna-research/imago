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
  '(:event :timestamp :candidate-id :run-id :split :task-id
    :executor-did :evaluator-did :task-correct-p
    :capability-score-micros :activation-evidence :duration-ms
    :input-tokens :output-tokens :estimated-cost-microusd
    :executor-signature :evaluator-signature
    :seq :previous-hash :event-hash))

(defparameter +decision-event-keys+
  '(:event :timestamp :candidate-id :baseline-id :evidence-head
    :minimum-held-out-repetitions :minimum-distinct-executors
    :minimum-capability-delta-micros :gates :failed-gates
    :baseline-capability-mean-micros :candidate-capability-mean-micros
    :capability-delta-micros :runtime-cost-microusd
    :development-cost-microusd :eligible-p :authorizer-did
    :authorization-signature :seq :previous-hash :event-hash))

(defparameter +pointer-event-keys+
  '(:event :timestamp :candidate-id :pointer :prior-candidate-id
    :authorizer-did :authorizer-signature :seq :previous-hash :event-hash))

(defparameter +gate-keys+
  '(:candidate-digest-valid
    :baseline-digest-valid
    :minimum-held-out-repetitions-met
    :minimum-distinct-executors-met
    :correctness-retained
    :activation-evidence-present
    :creator-evaluator-separated
    :roles-pairwise-distinct
    :trusted-evaluator-signatures
    :capability-delta-met
    :trusted-authorizer-signature))

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

(defun %candidate-id-p (value)
  (and (stringp value)
       (<= 1 (length value) 63)
       (let ((first (char value 0)))
         (or (digit-char-p first)
             (and (char>= first #\a) (char<= first #\z))))
       (every (lambda (character)
                (or (digit-char-p character)
                    (and (char>= character #\a) (char<= character #\z))
                    (char= character #\-)))
              value)))

(defun %require-candidate-id (value)
  (unless (%candidate-id-p value)
    (error "Invalid candidate identifier ~S." value))
  value)

(defun candidate-directory (store candidate-id)
  (%require-candidate-id candidate-id)
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
  (merge-pathnames (format nil "pointers/~A.sexp" (%pointer-name pointer))
                   (store-root store)))

;; ---------------------------------------------------------- small helpers ---

(defun %control-character-p (character)
  (let ((code (char-code character)))
    (or (< code 32) (= code 127))))

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
                   always (digit-char-p (char value index))))
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

(defun %validate-canonical-value (value &optional seen)
  (cond
    ((or (null value) (eq value t)) t)
    ((keywordp value) t)
    ((integerp value) t)
    ((stringp value)
     (unless (%safe-string-p value)
       (error "Canonical strings cannot contain control characters."))
     t)
    ((consp value)
     (unless (%proper-list-p value)
       (error "Canonical values require proper, acyclic lists."))
     (let ((seen (or seen (make-hash-table :test #'eq))))
       (when (gethash value seen)
         (error "Canonical values cannot contain cycles."))
       (setf (gethash value seen) t)
       (dolist (element value)
         (%validate-canonical-value element seen))
       (remhash value seen)
       t))
    (t (error "Value ~S is outside the canonical grammar." value))))

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
  (sb-ext:string-to-octets
   (with-output-to-string (stream)
     (let ((*package* (find-package :keyword))
           (*print-base* 10)
           (*print-radix* nil)
           (*print-case* :downcase)
           (*print-pretty* nil)
           (*print-circle* nil)
           (*print-escape* t)
           (*print-readably* t))
       (%write-canonical-value value stream)))
   :external-format :utf-8))

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
                (or (digit-char-p character)
                    (and (char>= character #\a) (char<= character #\f))))
              value)))

(defun %signature-p (value)
  (and (stringp value)
       (= (length value) 128)
       (every (lambda (character)
                (or (digit-char-p character)
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

(defun %sorted-unique-strings-p (value)
  (and (%proper-list-p value)
       (every (lambda (item) (%safe-string-p item :nonempty t)) value)
       (loop for (left right) on value
             while right
             always (string< left right))))

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

(defun %read-file-string (path)
  (with-open-file (stream path :direction :input :external-format :utf-8)
    (with-output-to-string (output)
      (loop for character = (read-char stream nil nil)
            while character
            do (write-char character output)))))

(defun %write-file-string (path content &key (if-exists :supersede))
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
  (let ((temporary (%temporary-peer path)))
    (unwind-protect
         (progn
           (%write-file-string temporary content)
           (sb-posix:rename (namestring temporary) (namestring path))
           path)
      (when (probe-file temporary)
        (ignore-errors (delete-file temporary))))))

(defun %read-one-form-string (content context)
  (let ((*read-eval* nil)
        (*readtable* (copy-readtable nil))
        (*read-base* 10)
        (*package* (find-package :cl-user)))
    (multiple-value-bind (form position)
        (read-from-string content nil :eof)
      (when (eq form :eof)
        (error "~A is empty or incomplete." context))
      (loop for index from position below (length content)
            unless (member (char content index)
                           '(#\Space #\Tab #\Newline #\Return))
              do (error "~A contains trailing data." context))
      form)))

(defun %read-one-form-file (path context)
  (%read-one-form-string (%read-file-string path) context))

(defun %copy-binary-file (source target)
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

;; ---------------------------------------------------------- strict forms ---

(defun %validate-budgets (budgets)
  (%require-keys budgets +budget-keys+ "Candidate budgets")
  (dolist (key +budget-keys+)
    (unless (%nonnegative-integer-p (getf budgets key))
      (error "Budget ~S must be a nonnegative integer." key)))
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
  (unless (%safe-string-p (getf event :run-id) :nonempty t :ascii t)
    (error "Evaluation run identifier is invalid."))
  (unless (member (getf event :split) '(:development :selection :held-out))
    (error "Evaluation split is invalid."))
  (unless (%safe-string-p (getf event :task-id) :nonempty t :ascii t)
    (error "Evaluation task identifier is invalid."))
  (unless (and (%did-key-p (getf event :executor-did))
               (%did-key-p (getf event :evaluator-did)))
    (error "Evaluation actor DID is invalid."))
  (unless (member (getf event :task-correct-p) '(nil t))
    (error "Task correctness must be Boolean."))
  (dolist (key '(:capability-score-micros :duration-ms :input-tokens
                 :output-tokens :estimated-cost-microusd))
    (unless (%nonnegative-integer-p (getf event key))
      (error "Evaluation metric ~S is invalid." key)))
  (unless (%sorted-unique-strings-p (getf event :activation-evidence))
    (error "Evaluation activation evidence is invalid."))
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

(defun %validate-decision-event (event)
  (%validate-event-common event +decision-event-keys+)
  (unless (eq (getf event :event) :decision)
    (error "Expected a decision event."))
  (%require-candidate-id (getf event :baseline-id))
  (unless (%sha256-p (getf event :evidence-head))
    (error "Decision evidence head is invalid."))
  (dolist (key '(:minimum-held-out-repetitions :minimum-distinct-executors))
    (unless (and (integerp (getf event key)) (>= (getf event key) 2))
      (error "Decision threshold ~S is invalid." key)))
  (dolist (key '(:minimum-capability-delta-micros
                 :baseline-capability-mean-micros
                 :candidate-capability-mean-micros
                 :runtime-cost-microusd :development-cost-microusd))
    (unless (%nonnegative-integer-p (getf event key))
      (error "Decision metric ~S is invalid." key)))
  (unless (integerp (getf event :capability-delta-micros))
    (error "Decision capability delta is invalid."))
  (%validate-gates (getf event :gates))
  (unless (and (%proper-list-p (getf event :failed-gates))
               (every (lambda (gate) (member gate +gate-keys+))
                      (getf event :failed-gates)))
    (error "Decision failed-gate list is invalid."))
  (unless (member (getf event :eligible-p) '(nil t))
    (error "Decision eligibility must be Boolean."))
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

;; --------------------------------------------------------------- ledger ---

(defun %head-payload (sequence hash authority-did)
  (list :seq sequence :event-hash hash :authority-did authority-did))

(defun %make-head (store sequence hash)
  (let* ((payload (%head-payload sequence hash (store-authority-did store)))
         (signature (%sign-value (store-authority store) payload)))
    (append payload (list :authority-signature signature))))

(defun %write-head (store sequence hash)
  (%atomic-write-string
   (ledger-head-path store)
   (concatenate 'string (%canonical-string (%make-head store sequence hash))
                (string #\Newline))))

(defun %read-head-unlocked (store)
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
    (%read-head-unlocked store)))

(defun %complete-ledger-lines (content)
  (loop with start = 0
        for newline = (position #\Newline content :start start)
        while newline
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
  (let ((events nil)
        (expected-sequence 1)
        (previous-hash +zero-sha256+))
    (dolist (line (%complete-ledger-lines
                   (%read-file-string (ledger-path store))))
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
        (when (and (eq (getf event :event) :evaluation)
                   (eq (getf event :split) :held-out))
          (let* ((manifest (%read-manifest-form
                            store (getf event :candidate-id)))
                 (creator (getf manifest :creator-did)))
            (unless (%manifest-signature-valid-p manifest)
              (error "Held-out evaluation refers to an unsigned manifest."))
            (unless (= 3 (length
                          (remove-duplicates
                           (list creator
                                 (getf event :executor-did)
                                 (getf event :evaluator-did))
                           :test #'string=)))
              (error "Held-out ledger roles are not pairwise distinct."))))
        (unless (%verify-event-actors store event)
          (error "Ledger actor signature verification failed."))
        (when (eq (getf event :event) :evaluation)
          (when (find (getf event :run-id) events
                      :key (lambda (prior) (getf prior :run-id))
                      :test #'string=)
            (error "Ledger contains duplicate run identifier ~S."
                   (getf event :run-id))))
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
    (unless (%verify-event-actors store event)
      (error "Refusing to append an event with invalid actor evidence."))
    ;; A crash may leave an incomplete, unsigned final fragment.  Readers
    ;; ignore it by contract; remove only that fragment before the next append.
    (let* ((ledger (ledger-path store))
           (content (%read-file-string ledger))
           (last-newline (position #\Newline content :from-end t))
           (complete-end (if last-newline (1+ last-newline) 0)))
      (unless (= complete-end (length content))
        (%atomic-write-string ledger (subseq content 0 complete-end))))
    (%write-file-string
     (ledger-path store)
     (concatenate 'string (%canonical-string event) (string #\Newline))
     :if-exists :append)
    (%write-head store sequence (getf event :event-hash))
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
  (copy-list roster))

(defun open-evolution-store (path &key authority trusted-executors
                                       trusted-evaluators trusted-authorizers)
  (let* ((authority-did (%identity-did authority))
         (executors (%validate-roster trusted-executors "Executor"))
         (evaluators (%validate-roster trusted-evaluators "Evaluator"))
         (authorizers (%validate-roster trusted-authorizers "Authorizer")))
    (when (intersection executors evaluators :test #'string=)
      (error "Executor and evaluator trust rosters must be disjoint."))
    (unless authorizers
      (error "At least one trusted authorizer is required."))
    (let* ((root (uiop:ensure-directory-pathname (merge-pathnames path)))
           (store (make-instance 'evolution-store
                                 :root root
                                 :authority authority
                                 :authority-did authority-did
                                 :trusted-executors executors
                                 :trusted-evaluators evaluators
                                 :trusted-authorizers authorizers)))
      (ensure-directories-exist (merge-pathnames "candidates/anchor" root))
      (ensure-directories-exist (merge-pathnames "pointers/anchor" root))
      (let ((ledger-exists (probe-file (ledger-path store)))
            (head-exists (probe-file (ledger-head-path store))))
        (cond
          ((and (null ledger-exists) (null head-exists))
           (%write-file-string (ledger-path store) "")
           (%write-head store 0 +zero-sha256+))
          ((not (and ledger-exists head-exists))
           (error "Evolution store has only one ledger component."))))
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

(defun %verify-candidate-internal (store candidate-id seen)
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
     (%regular-file-p image-path)
     (string= (%sha256-file image-path) (getf manifest :image-sha256))
     (let ((parent (getf manifest :parent-id)))
       (if (null parent)
           (null (getf manifest :parent-image-sha256))
           (let ((parent-manifest (read-candidate-manifest store parent)))
             (and (string= (getf parent-manifest :image-sha256)
                           (getf manifest :parent-image-sha256))
                  (%verify-candidate-internal store parent
                                              (cons candidate-id seen)))))))))

(defun verify-candidate (store candidate-id)
  (handler-case (%verify-candidate-internal store candidate-id nil)
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
        (when parent-id
          (unless (and (verify-candidate store parent-id)
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
               (directory (candidate-directory store candidate-id))
               (directory-name (string-right-trim "/" (namestring directory)))
               (created-directory nil))
          (%validate-manifest manifest)
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
                  (concatenate 'string (%canonical-string manifest)
                               (string #\Newline)))
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

(defun record-evaluation! (store &key run-id split task-id candidate-id
                                      executor evaluator task-correct-p
                                      capability-score-micros activation-evidence
                                      duration-ms input-tokens output-tokens
                                      estimated-cost-microusd)
  (%require-candidate-id candidate-id)
  (unless (%safe-string-p run-id :nonempty t :ascii t)
    (error "Run identifier is invalid."))
  (unless (member split '(:development :selection :held-out))
    (error "Evaluation split is invalid."))
  (unless (%safe-string-p task-id :nonempty t :ascii t)
    (error "Task identifier is invalid."))
  (unless (member task-correct-p '(nil t))
    (error "Task correctness must be Boolean."))
  (dolist (pair (list (cons :capability-score-micros capability-score-micros)
                      (cons :duration-ms duration-ms)
                      (cons :input-tokens input-tokens)
                      (cons :output-tokens output-tokens)
                      (cons :estimated-cost-microusd estimated-cost-microusd)))
    (unless (%nonnegative-integer-p (cdr pair))
      (error "Evaluation field ~S must be nonnegative." (car pair))))
  (unless (%sorted-unique-strings-p activation-evidence)
    (error "Evaluation activation evidence must be sorted and unique."))
  (let ((executor-did (%trusted-identity-did
                       executor (store-trusted-executors store) "Executor"))
        (evaluator-did (%trusted-identity-did
                        evaluator (store-trusted-evaluators store) "Evaluator")))
    (sb-thread:with-mutex ((store-lock store))
      (let* ((events (%read-ledger-unlocked store))
             (manifest (read-candidate-manifest store candidate-id))
             (creator-did (getf manifest :creator-did)))
        (unless (verify-candidate store candidate-id)
          (error "Candidate verification failed before evaluation."))
        (when (find run-id events :key (lambda (event) (getf event :run-id))
                                  :test #'string=)
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
                       :split split
                       :task-id task-id
                       :executor-did executor-did
                       :evaluator-did evaluator-did
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

(defun %mean-micros (events)
  (if events
      (truncate (reduce #'+ events
                        :key (lambda (event)
                               (getf event :capability-score-micros)))
                (length events))
      0))

(defun %distinct-executor-count (events)
  (length (remove-duplicates
           (mapcar (lambda (event) (getf event :executor-did)) events)
           :test #'string=)))

(defun %correctness-retained-p (baseline-events candidate-events)
  (let ((baseline-correct-tasks
          (remove-duplicates
           (loop for event in baseline-events
                 when (getf event :task-correct-p)
                   collect (getf event :task-id))
           :test #'string=)))
    (and baseline-events candidate-events baseline-correct-tasks
         (every
          (lambda (task-id)
            (let ((matches
                    (remove-if-not
                     (lambda (event)
                       (string= task-id (getf event :task-id)))
                     candidate-events)))
              (and matches
                   (every (lambda (event) (getf event :task-correct-p))
                          matches))))
          baseline-correct-tasks))))

(defun %event-role-separation-p (store event)
  (let* ((manifest (read-candidate-manifest store (getf event :candidate-id)))
         (creator (getf manifest :creator-did))
         (executor (getf event :executor-did))
         (evaluator (getf event :evaluator-did)))
    (= 3 (length (remove-duplicates (list creator executor evaluator)
                                     :test #'string=)))))

(defun %decision-gates (store baseline-id candidate-id
                        baseline-events candidate-events minimum-repetitions
                        minimum-executors minimum-delta authorizer-did)
  (let* ((candidate-valid (verify-candidate store candidate-id))
         (baseline-valid (verify-candidate store baseline-id))
         (baseline-mean (%mean-micros baseline-events))
         (candidate-mean (%mean-micros candidate-events))
         (delta (- candidate-mean baseline-mean))
         (selected (append baseline-events candidate-events)))
    (values
     (list
      :candidate-digest-valid (not (null candidate-valid))
      :baseline-digest-valid (not (null baseline-valid))
      :minimum-held-out-repetitions-met
      (and (>= (length baseline-events) minimum-repetitions)
           (>= (length candidate-events) minimum-repetitions))
      :minimum-distinct-executors-met
      (and (>= (%distinct-executor-count baseline-events) minimum-executors)
           (>= (%distinct-executor-count candidate-events) minimum-executors))
      :correctness-retained
      (%correctness-retained-p baseline-events candidate-events)
      :activation-evidence-present
      (and selected
           (every (lambda (event) (not (null (getf event :activation-evidence))))
                  selected))
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
      :trusted-evaluator-signatures
      (and selected
           (every (lambda (event)
                    (member (getf event :evaluator-did)
                            (store-trusted-evaluators store) :test #'string=))
                  selected))
      :capability-delta-met (>= delta minimum-delta)
      :trusted-authorizer-signature
      (not (null (member authorizer-did (store-trusted-authorizers store)
                         :test #'string=))))
     baseline-mean candidate-mean delta)))

(defun make-decision! (store baseline-id candidate-id
                       &key (minimum-held-out-repetitions 3)
                            (minimum-distinct-executors 2)
                            (minimum-capability-delta-micros 0)
                            authorizer)
  (%require-candidate-id baseline-id)
  (%require-candidate-id candidate-id)
  (when (string= baseline-id candidate-id)
    (error "Baseline and candidate identifiers must differ."))
  (unless (and (integerp minimum-held-out-repetitions)
               (>= minimum-held-out-repetitions 2))
    (error "Held-out repetition minimum must be at least two."))
  (unless (and (integerp minimum-distinct-executors)
               (>= minimum-distinct-executors 2))
    (error "Distinct executor minimum must be at least two."))
  (unless (%nonnegative-integer-p minimum-capability-delta-micros)
    (error "Minimum capability delta must be nonnegative."))
  (let ((authorizer-did
          (%trusted-identity-did authorizer
                                 (store-trusted-authorizers store)
                                 "Authorizer")))
    (sb-thread:with-mutex ((store-lock store))
      (let* ((events (%read-ledger-unlocked store))
             (held-out (remove-if-not
                        (lambda (event)
                          (and (eq (getf event :event) :evaluation)
                               (eq (getf event :split) :held-out)))
                        events))
             (baseline-events
               (remove baseline-id held-out
                       :key (lambda (event) (getf event :candidate-id))
                       :test-not #'string=))
             (candidate-events
               (remove candidate-id held-out
                       :key (lambda (event) (getf event :candidate-id))
                       :test-not #'string=))
             (head (if events
                       (getf (car (last events)) :event-hash)
                       +zero-sha256+)))
        (multiple-value-bind (gates baseline-mean candidate-mean delta)
            (%decision-gates store baseline-id candidate-id
                             baseline-events candidate-events
                             minimum-held-out-repetitions
                             minimum-distinct-executors
                             minimum-capability-delta-micros
                             authorizer-did)
          (let* ((failed-gates
                   (loop for (key value) on gates by #'cddr
                         unless value collect key))
                 (eligible-p (null failed-gates))
                 (runtime-cost
                   (reduce #'+ (append baseline-events candidate-events)
                           :key (lambda (event)
                                  (getf event :estimated-cost-microusd))
                           :initial-value 0))
                 (development-cost
                   (if (verify-candidate store candidate-id)
                       (getf (getf (read-candidate-manifest store candidate-id)
                                   :budgets)
                             :development-cost-microusd)
                       0))
                 (payload
                   (list :event :decision
                         :timestamp (anuna-imago:iso-8601-now)
                         :candidate-id candidate-id
                         :baseline-id baseline-id
                         :evidence-head head
                         :minimum-held-out-repetitions
                         minimum-held-out-repetitions
                         :minimum-distinct-executors minimum-distinct-executors
                         :minimum-capability-delta-micros
                         minimum-capability-delta-micros
                         :gates gates
                         :failed-gates failed-gates
                         :baseline-capability-mean-micros baseline-mean
                         :candidate-capability-mean-micros candidate-mean
                         :capability-delta-micros delta
                         :runtime-cost-microusd runtime-cost
                         :development-cost-microusd development-cost
                         :eligible-p eligible-p
                         :authorizer-did authorizer-did))
                 (signature (%sign-value authorizer payload))
                 (actor-event
                   (append payload (list :authorization-signature signature))))
            (%append-event-unlocked store actor-event events)))))))

;; -------------------------------------------------------------- pointers ---

(defun %pointer-keyword (pointer)
  (intern (string-upcase (%pointer-name pointer)) :keyword))

(defun %read-pointer-form (store pointer)
  (let* ((keyword (%pointer-keyword pointer))
         (path (pointer-path store keyword)))
    (when (%path-entry-exists-p path)
      (unless (%regular-file-p path)
        (error "Evolution pointer is not a regular file."))
      (%validate-pointer-form
       (%read-one-form-file path "Evolution pointer") keyword))))

(defun %pointer-corresponds-to-events-p (form events)
  (let ((latest
          (loop with latest = nil
                for event in events
                when (and (member (getf event :event) '(:promotion :rollback))
                          (eq (getf event :pointer) (getf form :pointer)))
                  do (setf latest event)
                finally (return latest))))
    (and latest
         (string= (getf latest :event-hash) (getf form :event-hash))
         (eq (getf latest :pointer) (getf form :pointer))
         (string= (getf latest :candidate-id) (getf form :candidate-id))
         (equal (getf latest :prior-candidate-id)
                (getf form :prior-candidate-id)))))

(defun read-pointer (store pointer)
  (sb-thread:with-mutex ((store-lock store))
    (let ((form (%read-pointer-form store pointer)))
      (when form
        ;; A valid ledger gives the pointer cryptographic provenance.  If the
        ;; ledger is corrupt, this read-only API still exposes the complete
        ;; observed pointer for diagnosis; every effectful caller verifies the
        ;; ledger first and therefore fails closed in that state.
        (let ((correspondence
                (handler-case
                    (let ((events (%read-ledger-unlocked store)))
                      (%pointer-corresponds-to-events-p form events))
                  (error () :ledger-unavailable))))
          (when (null correspondence)
            (error "Pointer does not correspond to latest signed ledger evidence.")))
        (getf form :candidate-id)))))

(defun %write-pointer (store pointer candidate-id prior-id event-hash)
  (%atomic-write-string
   (pointer-path store pointer)
   (concatenate
    'string
    (%canonical-string
     (list :version 1
           :pointer (%pointer-keyword pointer)
           :candidate-id candidate-id
           :prior-candidate-id prior-id
           :event-hash event-hash))
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
        (unless (and (verify-candidate store (getf decision :candidate-id))
                     (verify-candidate store (getf decision :baseline-id)))
          (error "Promotion candidate or baseline no longer verifies."))
        (let* ((prior-form (%read-pointer-form store pointer))
               (prior
                 (when prior-form
                   (unless (%pointer-corresponds-to-events-p prior-form events)
                     (error "Pointer does not correspond to latest signed ledger evidence."))
                   (getf prior-form :candidate-id)))
               (payload
                 (list :event :promotion
                       :timestamp (anuna-imago:iso-8601-now)
                       :candidate-id (getf decision :candidate-id)
                       :pointer pointer
                       :prior-candidate-id prior
                       :authorizer-did authorizer-did))
               (signature (%sign-value authorizer payload))
               (event (%append-event-unlocked
                       store
                       (append payload (list :authorizer-signature signature))
                       events)))
          (%write-pointer store pointer (getf decision :candidate-id) prior
                          (getf event :event-hash))
          event)))))

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
          (unless (and (verify-candidate store current)
                       (verify-candidate store prior))
            (error "Rollback candidate verification failed."))
          (let* ((payload
                   (list :event :rollback
                         :timestamp (anuna-imago:iso-8601-now)
                         :candidate-id prior
                         :pointer pointer
                         :prior-candidate-id current
                         :authorizer-did authorizer-did))
                 (signature (%sign-value authorizer payload))
                 (event (%append-event-unlocked
                         store
                         (append payload (list :authorizer-signature signature))
                         events)))
            (%write-pointer store pointer prior current (getf event :event-hash))
            event))))))

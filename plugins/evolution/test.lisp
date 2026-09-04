;;;; test.lisp — SPEC-014 Red Gate for the optional evolution control plane
;;;;
;;;; This file deliberately contains no reader references to the production
;;;; package.  IMAGO/EVOLUTION/TEST therefore loads with IMAGO/TEST while the
;;;; optional subsystem is absent.  RUN-EVOLUTION-TESTS loads the subsystem,
;;;; resolves its public API dynamically, and then executes the contract.

(in-package #:anuna-imago.test)

(export 'run-evolution-tests)

(defparameter *evolution-package-present-at-test-load*
  (not (null (find-package "ANUNA-IMAGO.EVOLUTION"))))

(defvar *evolution-reader-attack-fired* nil)

(defparameter +evolution-fixed-time+ "2026-09-04T00:00:00Z")
(defparameter +evolution-zero-sha256+ (make-string 64 :initial-element #\0))
(defparameter +evolution-sha-a+ (make-string 64 :initial-element #\a))
(defparameter +evolution-sha-b+ (make-string 64 :initial-element #\b))
(defparameter +evolution-sha-c+ (make-string 64 :initial-element #\c))
(defparameter +evolution-decision-gate-keys+
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

;; ------------------------------------------------------------- harness ---

(defun %evo-symbol (name &optional (errorp t))
  (let ((package (find-package "ANUNA-IMAGO.EVOLUTION")))
    (cond
      ((null package)
       (when errorp
         (error "The ANUNA-IMAGO.EVOLUTION package is absent.")))
      (t
       (multiple-value-bind (symbol status) (find-symbol name package)
         (declare (ignore status))
         (cond ((and symbol (fboundp symbol)) symbol)
               (errorp (error "Evolution API ~A is absent." name))
               (t nil)))))))

(defun %evo-function (name &optional (errorp t))
  (let ((symbol (%evo-symbol name errorp)))
    (and symbol (symbol-function symbol))))

(defun %evo-call (name &rest arguments)
  (apply (%evo-function name) arguments))

(defun %evo-apply (name arguments)
  (apply (%evo-function name) arguments))

(defun %signals-error-p (thunk)
  (handler-case (progn (funcall thunk) nil)
    (error () t)))

(defun %rejected-p (thunk)
  "True when THUNK signals or returns NIL."
  (handler-case (not (funcall thunk))
    (error () t)))

(defun %run-evolution-case (name thunk)
  (format t "~%-- ~A --~%" name)
  (handler-case (funcall thunk)
    (error (condition)
      (incf *failures*)
      (format t "  ERROR test setup — ~A~%" condition))))

(defun %temporary-evolution-directory ()
  (loop
    for nonce = (format nil "imago-evolution-test-~D-~D/"
                        (get-universal-time) (random 1000000000))
    for directory = (merge-pathnames nonce (uiop:temporary-directory))
    unless (probe-file directory)
      do (ensure-directories-exist (merge-pathnames "anchor" directory))
         (return directory)))

(defun %call-with-evolution-directory (thunk)
  (let ((directory (%temporary-evolution-directory)))
    (unwind-protect (funcall thunk directory)
      (uiop:delete-directory-tree directory
                                  :validate t
                                  :if-does-not-exist :ignore))))

(defun %write-octets (path octets)
  (ensure-directories-exist path)
  (with-open-file (stream path
                          :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create
                          :element-type '(unsigned-byte 8))
    (write-sequence octets stream))
  path)

(defun %read-octets (path)
  (with-open-file (stream path :direction :input
                               :element-type '(unsigned-byte 8))
    (let ((result (make-array (file-length stream)
                              :element-type '(unsigned-byte 8))))
      (read-sequence result stream)
      result)))

(defun %write-string (path string)
  (ensure-directories-exist path)
  (with-open-file (stream path
                          :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create
                          :external-format :utf-8)
    (write-string string stream))
  path)

(defun %read-string (path)
  (with-open-file (stream path :direction :input :external-format :utf-8)
    (let ((result (make-string (file-length stream))))
      (let ((count (read-sequence result stream)))
        (if (= count (length result)) result (subseq result 0 count))))))

(defun %call-with-entry-replaced-by-self-symlink (entry thunk)
  "Temporarily move ENTRY aside and put a symlink to those same valid bytes at
its managed name.  THUNK must reject the entry based on lstat, not content."
  (let* ((entry-name (string-right-trim "/" (namestring entry)))
         (backup-name
           (format nil "~A.imago-backup-~D" entry-name (random 1000000000))))
    (sb-posix:rename entry-name backup-name)
    (unwind-protect
         (progn
           (sb-posix:symlink backup-name entry-name)
           (funcall thunk))
      (ignore-errors (sb-posix:unlink entry-name))
      (sb-posix:rename backup-name entry-name))))

(defun %write-form (path form &key (trailing-newline t))
  (%write-string
   path
   (concatenate
    'string
    (funcall (%evo-function "%CANONICAL-STRING") form)
    (if trailing-newline (string #\Newline) ""))))

(defun %plist-without (plist key)
  (loop for (candidate-key value) on plist by #'cddr
        unless (eq candidate-key key)
          append (list candidate-key value)))

(defun %plist-put (plist key value)
  (let ((copy (copy-list plist)))
    (setf (getf copy key) value)
    copy))

(defun %plist-without-keys (plist keys)
  (reduce #'%plist-without keys :initial-value plist))

(defun %package-registry-snapshot ()
  (list
   (sort (mapcar #'package-name (list-all-packages)) #'string<)
   (sort (loop for symbol being the external-symbols of (find-package :keyword)
               collect (symbol-name symbol))
         #'string<)))

(defun %ascii-digit-p (character)
  (and (char>= character #\0) (char<= character #\9)))

(defun %valid-sha256-p (value)
  (and (stringp value)
       (= 64 (length value))
       (every (lambda (character)
                (or (%ascii-digit-p character)
                    (find character "abcdef" :test #'char=)))
              value)))

(defun %valid-signature-hex-p (value)
  (and (stringp value)
       (= 128 (length value))
       (every (lambda (character)
                (or (%ascii-digit-p character)
                    (find character "abcdef" :test #'char=)))
              value)))

(defun %valid-candidate-id-p (value)
  (and (stringp value)
       (<= 1 (length value) 63)
       (or (%ascii-digit-p (char value 0))
           (find (char value 0) "abcdefghijklmnopqrstuvwxyz" :test #'char=))
       (every (lambda (character)
                (or (%ascii-digit-p character)
                    (find character "abcdefghijklmnopqrstuvwxyz-" :test #'char=)))
              value)))

(defun %event-of-kind (events kind)
  (find kind events :key (lambda (event) (getf event :event))))

(defun %events-of-kind (events kind)
  (remove-if-not (lambda (event) (eq kind (getf event :event))) events))

(defun %make-actors ()
  (list :authority (generate-identity)
        :creator (generate-identity)
        :creator-2 (generate-identity)
        :executor-1 (generate-identity)
        :executor-2 (generate-identity)
        :evaluator-1 (generate-identity)
        :evaluator-2 (generate-identity)
        :authorizer (generate-identity)
        :outsider (generate-identity)))

(defun %actor (actors key)
  (getf actors key))

(defun %did (actors key)
  (identity-did (%actor actors key)))

(defun %open-test-store (path actors &key executor-dids evaluator-dids
                                             authorizer-dids)
  (%evo-call "OPEN-EVOLUTION-STORE"
             path
             :authority (%actor actors :authority)
             :trusted-executors (or executor-dids
                                    (list (%did actors :executor-1)
                                          (%did actors :executor-2)))
             :trusted-evaluators (or evaluator-dids
                                     (list (%did actors :evaluator-1)
                                           (%did actors :evaluator-2)))
             :trusted-authorizers (or authorizer-dids
                                      (list (%did actors :authorizer)))))

(defun %close-test-store (store)
  (let ((close (%evo-function "CLOSE-EVOLUTION-STORE" nil)))
    (when close (funcall close store))))

(defun %base-freeze-arguments (creator &key parent-id parent-image-sha256)
  (list :parent-id parent-id
        :parent-image-sha256 parent-image-sha256
        :creator creator
        :created-at +evolution-fixed-time+
        :theory-fingerprint +evolution-sha-a+
        :prompt-schema-sha256 +evolution-sha-b+
        :tool-schema-sha256 +evolution-sha-c+
        :changed-components '("prompt/system" "tools/weather")
        :budgets '(:development-cost-microusd 1200
                   :wall-time-ms 2500
                   :input-tokens 300
                   :output-tokens 100)
        :activation-evidence '("prompt/system:sha256:aa"
                               "tools/weather:dispatch:1")))

(defun %freeze (store image creator &key parent-id parent-image-sha256 arguments)
  (%evo-apply "FREEZE-CANDIDATE!"
              (append (list store image)
                      (or arguments
                          (%base-freeze-arguments
                           creator
                           :parent-id parent-id
                           :parent-image-sha256 parent-image-sha256)))))

(defun %candidate-id (manifest)
  (getf manifest :candidate-id))

(defun %make-image (directory name &optional (octets #(73 77 65 71 79)))
  (%write-octets (merge-pathnames name directory) octets))

(defun %runtime-activation-evidence (store candidate-id)
  (let ((digest (getf (%evo-call "READ-CANDIDATE-MANIFEST"
                                 store candidate-id)
                      :image-sha256)))
    (list (list :component "prompt/system"
                :kind :runtime-hit
                :artifact-sha256 digest)
          (list :component "tools/weather"
                :kind :runtime-hit
                :artifact-sha256 digest))))

(defun %record-evaluation (store actors candidate-id run-id task-id score
                           &key (campaign-id "matrix")
                                (benchmark-id "benchmark-1")
                                (replicate-index 1)
                                (evaluation-plan-sha256 +evolution-sha-a+)
                                (executor-config-sha256 +evolution-sha-b+)
                                (scorer-config-sha256 +evolution-sha-c+)
                                (executor :executor-1)
                                (evaluator :evaluator-1)
                                (run-complete-p t)
                                (correct-p t)
                                (activation-evidence nil activation-evidence-p)
                                (duration-ms 100)
                                (input-tokens 20)
                                (output-tokens 10)
                                (cost 30)
                                (split :held-out))
  (%evo-call "RECORD-EVALUATION!"
             store
             :run-id run-id
             :campaign-id campaign-id
             :benchmark-id benchmark-id
             :split split
             :task-id task-id
             :replicate-index replicate-index
             :evaluation-plan-sha256 evaluation-plan-sha256
             :executor-config-sha256 executor-config-sha256
             :scorer-config-sha256 scorer-config-sha256
             :candidate-id candidate-id
             :executor (%actor actors executor)
             :evaluator (%actor actors evaluator)
             :run-complete-p run-complete-p
             :task-correct-p correct-p
             :capability-score-micros score
             :activation-evidence
             (if activation-evidence-p
                 activation-evidence
                 (%runtime-activation-evidence store candidate-id))
             :duration-ms duration-ms
             :input-tokens input-tokens
             :output-tokens output-tokens
             :estimated-cost-microusd cost))

(defun %record-comparison-matrix (store actors baseline-id candidate-id
                                  &key (candidate-correct '(t t t))
                                       (baseline-scores '(500000 600000 700000))
                                       (candidate-scores '(700000 800000 900000))
                                       (order :forward)
                                       (prefix "matrix")
                                       campaign-id)
  (let* ((campaign-id (or campaign-id prefix))
         (baseline
           (loop for index from 1
                 for score in baseline-scores
                 collect
                 (list baseline-id (format nil "~A-b~D" prefix index)
                       "task-1" score
                       :campaign-id campaign-id
                       :replicate-index index
                       :executor (if (oddp index) :executor-1 :executor-2)
                       :evaluator (if (oddp index)
                                      :evaluator-1 :evaluator-2))))
         (candidate
           (loop for index from 1
                 for score in candidate-scores
                 for correct in candidate-correct
                 collect
                 (list candidate-id (format nil "~A-c~D" prefix index)
                       "task-1" score
                       :campaign-id campaign-id
                       :replicate-index index
                       :correct-p correct
                       :executor (if (oddp index) :executor-1 :executor-2)
                       :evaluator (if (oddp index)
                                      :evaluator-1 :evaluator-2))))
         (rows (append baseline candidate)))
    (cond
      ((eq order :reverse)
       (setf rows (reverse rows)))
      ((integerp order)
       (let ((offset (mod order (length rows))))
         (setf rows (append (nthcdr offset rows)
                            (subseq rows 0 offset))))))
    (dolist (row rows)
      (apply #'%record-evaluation store actors row))))

(defun %make-decision (store baseline-id candidate-id authorizer
                       &key (campaign-id "matrix")
                            (minimum-repetitions 3)
                            (minimum-executors 2)
                            (minimum-capability-delta-micros 100000)
                            (maximum-execution-token-increase 0)
                            (maximum-runtime-cost-increase-microusd 0))
  (%evo-call "MAKE-DECISION!"
             store baseline-id candidate-id
             :campaign-id campaign-id
             :minimum-held-out-repetitions minimum-repetitions
             :minimum-distinct-executors minimum-executors
             :minimum-capability-delta-micros minimum-capability-delta-micros
             :maximum-execution-token-increase
             maximum-execution-token-increase
             :maximum-runtime-cost-increase-microusd
             maximum-runtime-cost-increase-microusd
             :authorizer authorizer))

(defun %resign-decision-for-validation (decision authorizer)
  (let* ((payload
           (funcall (%evo-function "%EVENT-ACTOR-PAYLOAD") decision))
         (signature
           (funcall (%evo-function "%SIGN-VALUE") authorizer payload)))
    (%plist-put decision :authorization-signature signature)))

(defun %make-candidate-pair (directory actors &key (candidate-bytes #(67 65 78 68)))
  (let* ((store-path (merge-pathnames "store/" directory))
         (store (%open-test-store store-path actors))
         (baseline-image (%make-image directory "baseline.core" #(66 65 83 69)))
         (candidate-image (%make-image directory "candidate.core" candidate-bytes))
         (baseline-manifest (%freeze store baseline-image (%actor actors :creator)))
         (baseline-id (%candidate-id baseline-manifest))
         (candidate-manifest (%freeze store candidate-image (%actor actors :creator-2)))
         (candidate-id (%candidate-id candidate-manifest)))
    (values store store-path baseline-manifest baseline-id
            candidate-manifest candidate-id)))

(defun %plist-overlay (base overrides)
  (let ((result (copy-list base)))
    (loop for (key value) on overrides by #'cddr
          do (setf (getf result key) value))
    result))

(defun %record-paired-cell (store actors baseline-id candidate-id prefix
                            replicate-index baseline-score candidate-score
                            &key (campaign-id "matrix")
                                 (benchmark-id "benchmark-1")
                                 (task-id "task-1")
                                 (executor :executor-1)
                                 (evaluator :evaluator-1)
                                 (evaluation-plan-sha256 +evolution-sha-a+)
                                 (executor-config-sha256 +evolution-sha-b+)
                                 (scorer-config-sha256 +evolution-sha-c+)
                                 baseline-options candidate-options)
  (let ((common
          (list :campaign-id campaign-id
                :benchmark-id benchmark-id
                :replicate-index replicate-index
                :executor executor
                :evaluator evaluator
                :evaluation-plan-sha256 evaluation-plan-sha256
                :executor-config-sha256 executor-config-sha256
                :scorer-config-sha256 scorer-config-sha256)))
    (apply #'%record-evaluation store actors baseline-id
           (format nil "~A-b" prefix) task-id baseline-score
           (%plist-overlay common baseline-options))
    (apply #'%record-evaluation store actors candidate-id
           (format nil "~A-c" prefix) task-id candidate-score
           (%plist-overlay common candidate-options))))

(defun %ledger-rejected-p (store)
  (%rejected-p (lambda () (%evo-call "VERIFY-LEDGER" store))))

;; ---------------------------------------------------- TEST-005 / boundary ---

(defun test-evolution-optional-load-boundary ()
  (let* ((imago-system (asdf:find-system :imago))
         (dependencies (mapcar (lambda (dependency)
                                 (string-downcase (string dependency)))
                               (asdf:system-depends-on imago-system)))
         (test-dependencies
           (mapcar (lambda (dependency)
                     (string-downcase (string dependency)))
                   (asdf:system-depends-on
                    (asdf:find-system :imago/evolution/test))))
         (tools-before (sort (mapcar #'symbol-name (list-tools)) #'string<)))
    (if *evolution-package-present-at-test-load*
        (format t "  note  evolution was explicitly preloaded; dependency checks remain valid~%")
        (check t "a clean imago/evolution/test load has no production package"))
    (check (not (member "imago/evolution" dependencies :test #'string=))
           "the default imago system has no evolution dependency")
    (check (and (member "imago/test" test-dependencies :test #'string=)
                (not (member "imago/evolution" test-dependencies :test #'string=)))
           "the Red Gate itself does not force the optional production system")
    (asdf:load-system :imago/evolution)
    (check (find-package "ANUNA-IMAGO.EVOLUTION")
           "the optional system creates its package only on request")
    (dolist (name '("OPEN-EVOLUTION-STORE" "FREEZE-CANDIDATE!"
                    "RECORD-EVALUATION!" "MAKE-DECISION!"
                    "PROMOTE-CANDIDATE!" "ROLLBACK-POINTER!"))
      (check (%evo-symbol name nil) (format nil "~A is present" name)))
    (check (equal tools-before
                  (sort (mapcar #'symbol-name (list-tools)) #'string<))
           "loading the control plane registers no agent tools")))

;; -------------------------------- TEST-007, TEST-019, TEST-026 / freeze ---

(defun test-evolution-freeze-copy-hash-immutability-and-identity ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let* ((actors (%make-actors))
            (store-a (%open-test-store (merge-pathnames "a/" directory) actors))
            (store-b (%open-test-store (merge-pathnames "b/" directory) actors))
            (source (%make-image directory "source.core" #(0 1 2 3 4 255)))
            (arguments (%base-freeze-arguments (%actor actors :creator)))
            (manifest-a (%freeze store-a source (%actor actors :creator)
                                 :arguments arguments))
            (manifest-b (%freeze store-b source (%actor actors :creator)
                                 :arguments arguments))
            (candidate-id (%candidate-id manifest-a))
            (copy-path (%evo-call "CANDIDATE-IMAGE-PATH" store-a candidate-id))
            (copy-before (%read-octets copy-path))
            (manifest-path (%evo-call "CANDIDATE-MANIFEST-PATH"
                                      store-a candidate-id))
            (manifest-before (%read-octets manifest-path))
            (ledger-before (%read-octets (%evo-call "LEDGER-PATH" store-a))))
       (check (%valid-candidate-id-p candidate-id))
       (check (string= candidate-id (%candidate-id manifest-b))
              "identical bytes and identity inputs yield one identifier")
       (check (not (equal (truename source) (truename copy-path)))
              "freeze copies instead of retaining the source path")
       (check (equalp #(0 1 2 3 4 255) copy-before))
       (check (string= (bytes->hex (ironclad:digest-file :sha256 copy-path))
                       (getf manifest-a :image-sha256)))
       (check (%valid-sha256-p (getf manifest-a :image-sha256)))
       (check (%signals-error-p
               (lambda () (%freeze store-a source (%actor actors :creator)
                                    :arguments arguments)))
              "an existing identifier cannot be overwritten")
       (check (equalp copy-before (%read-octets copy-path)))
       (check (equalp manifest-before (%read-octets manifest-path)))
       (check (equalp ledger-before (%read-octets (%evo-call "LEDGER-PATH" store-a)))
              "a collision leaves the ledger prefix unchanged")
       (let* ((oversized-arguments (copy-tree arguments))
              (wide-components
                (loop for index below 4096
                      collect (format nil "component-~4,'0D-~A" index
                                      (make-string 256
                                                   :initial-element #\x))))
              (candidate-root (merge-pathnames "candidates/"
                                               (%evo-call "STORE-ROOT" store-a)))
              (entries-before
                (append (uiop:directory-files candidate-root)
                        (uiop:subdirectories candidate-root)))
              (head-before (%read-octets (%evo-call "LEDGER-HEAD-PATH"
                                                    store-a))))
         (setf (getf oversized-arguments :changed-components) wide-components)
         (check (%signals-error-p
                 (lambda ()
                   (%freeze store-a source (%actor actors :creator)
                            :arguments oversized-arguments)))
                "an oversized semantic manifest fails bounded recognition")
         (check (equal entries-before
                       (append (uiop:directory-files candidate-root)
                               (uiop:subdirectories candidate-root)))
                "manifest recognition precedes candidate directory creation")
         (check (equalp ledger-before
                        (%read-octets (%evo-call "LEDGER-PATH" store-a))))
         (check (equalp head-before
                        (%read-octets (%evo-call "LEDGER-HEAD-PATH" store-a)))
                "oversized manifest rejection preserves ledger and head"))
       (%write-octets source #(9 9 9))
       (check (equalp copy-before (%read-octets copy-path))
              "later source mutation cannot alter frozen bytes")
       (%close-test-store store-a)
       (%close-test-store store-b)))))

(defun test-evolution-ledger-size-preflight ()
  "TEST-056: an append cannot cross the store's own recognition ceiling."
  (%call-with-evolution-directory
   (lambda (directory)
     (let* ((actors (%make-actors))
            (store (%open-test-store (merge-pathnames "store/" directory)
                                     actors))
            (image (%make-image directory "bounded.core" #(1 2 3)))
            (ledger-path (%evo-call "LEDGER-PATH" store))
            (head-path (%evo-call "LEDGER-HEAD-PATH" store))
            (ledger-before (%read-string ledger-path))
            (head-before (%read-string head-path))
            (limit-symbol
              (find-symbol "+MAXIMUM-LEDGER-OCTETS+"
                           "ANUNA-IMAGO.EVOLUTION")))
       (check (%signals-error-p
               (lambda ()
                 (progv (list limit-symbol) (list 1)
                   (%freeze store image (%actor actors :creator)))))
              "projected oversized append is rejected before persistence")
       (check (string= ledger-before (%read-string ledger-path))
              "oversized append leaves ledger bytes unchanged")
       (check (string= head-before (%read-string head-path))
              "oversized append leaves signed head unchanged")
       (%close-test-store store)))))

(defun test-evolution-rejects-unicode-control-strings ()
  "TEST-057: canonical strings reject Unicode C1 control characters."
  (%call-with-evolution-directory
   (lambda (directory)
     (let* ((actors (%make-actors))
            (store (%open-test-store (merge-pathnames "store/" directory)
                                     actors))
            (image (%make-image directory "c1.core" #(4 5 6)))
            (arguments (%base-freeze-arguments (%actor actors :creator)))
            (c1-string (format nil "component~Cname" (code-char #x85))))
       (setf (getf arguments :changed-components) (list c1-string))
       (check (%signals-error-p
               (lambda ()
                 (%freeze store image (%actor actors :creator)
                          :arguments arguments)))
              "U+0085 is rejected from canonical signed strings")
       (%close-test-store store)))))

(defun test-evolution-authority-signing-preflight ()
  "TEST-060: authority signing failures precede every persistent mutation."
  (%call-with-evolution-directory
   (lambda (directory)
     (let* ((bad-actors (%make-actors))
            (fresh-root (merge-pathnames "fresh-signing-failure/" directory))
            (fresh-ledger (merge-pathnames "ledger.sexp" fresh-root))
            (fresh-head (merge-pathnames "ledger.head" fresh-root)))
       (clear-identity-private-key! (%actor bad-actors :authority))
       (check (%signals-error-p
               (lambda () (%open-test-store fresh-root bad-actors)))
              "fresh-store signing failure is reported synchronously")
       (check (null (probe-file fresh-root))
              "fresh-store signing failure creates no store directory")
       (check (null (probe-file fresh-ledger))
              "fresh-store failure creates no ledger component")
       (check (null (probe-file fresh-head))
              "fresh-store failure creates no head component"))
     (let* ((actors (%make-actors))
            (existing-root (merge-pathnames "existing/" directory))
            (store (%open-test-store existing-root actors))
            (image (%make-image directory "wrong-authority.core" #(7 8 9)))
            (candidate-root (merge-pathnames "candidates/" existing-root))
            (candidate-entries-before
              (append (uiop:directory-files candidate-root)
                      (uiop:subdirectories candidate-root)))
            (ledger-path (%evo-call "LEDGER-PATH" store))
            (head-path (%evo-call "LEDGER-HEAD-PATH" store))
            (ledger-before (%read-string ledger-path))
            (head-before (%read-string head-path))
            (authority (%actor actors :authority))
            (wrong (generate-identity)))
       (setf (identity-private-key authority) (identity-private-key wrong))
       (check (%signals-error-p
               (lambda () (%freeze store image (%actor actors :creator))))
              "a private key that does not match the authority DID is rejected")
       (check (string= ledger-before (%read-string ledger-path))
              "failed append leaves ledger bytes unchanged")
       (check (string= head-before (%read-string head-path))
              "failed append leaves head bytes unchanged")
       (check (equal candidate-entries-before
                     (append (uiop:directory-files candidate-root)
                             (uiop:subdirectories candidate-root)))
              "authority preflight precedes candidate materialization")
       (%close-test-store store)))))

(defun test-evolution-aggregate-serialization-bounds ()
  "TEST-062: admitted evidence remains serializable as a derived decision."
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors))
           (maximum (1- (expt 10 20))))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         (loop for index from 1 to 3
               for executor = (if (oddp index) :executor-1 :executor-2)
               for evaluator = (if (oddp index) :evaluator-1 :evaluator-2)
               do (%record-evaluation
                   store actors baseline-id (format nil "aggregate-b~D" index)
                   "aggregate-task" (- maximum 2)
                   :campaign-id "aggregate" :replicate-index index
                   :executor executor :evaluator evaluator
                   :duration-ms maximum :input-tokens maximum
                   :output-tokens maximum :cost maximum)
                  (%record-evaluation
                   store actors candidate-id (format nil "aggregate-c~D" index)
                   "aggregate-task" (- maximum 1)
                   :campaign-id "aggregate" :replicate-index index
                   :executor executor :evaluator evaluator
                   :duration-ms maximum :input-tokens maximum
                   :output-tokens maximum :cost maximum))
         (let ((decision
                 (%make-decision store baseline-id candidate-id
                                 (%actor actors :authorizer)
                                 :campaign-id "aggregate"
                                 :minimum-capability-delta-micros 1)))
           (check (> (getf decision :candidate-execution-tokens-total)
                     maximum)
                  "derived totals may exceed the source-field digit width")
           (check (equal decision (car (last (%evo-call "READ-LEDGER" store))))
                  "large derived totals round-trip through the ledger grammar"))
         (let ((count-before (length (%evo-call "READ-LEDGER" store))))
           (check (%signals-error-p
                   (lambda ()
                     (%record-evaluation
                      store actors candidate-id "aggregate-too-large"
                      "aggregate-other" (expt 10 20)
                      :campaign-id "aggregate-other" :split :development)))
                  "a 21-digit source metric is rejected")
           (check (= count-before (length (%evo-call "READ-LEDGER" store)))))
         (%close-test-store store)))
     ;; Exercise the exact campaign cardinality boundary without manufacturing
     ;; hundreds of signatures and files: this private recognizer is also run
     ;; for every append and every ledger replay.
     (let* ((validate
              (%evo-function "%VALIDATE-EVALUATION-LEDGER-CONSTRAINTS"))
            (prior
              (loop for index below 256
                    collect (list :event :evaluation :split :held-out
                                  :candidate-id "c-bounded"
                                  :campaign-id "bounded-campaign"
                                  :run-id (format nil "bounded-~D" index)
                                  :benchmark-id "bounded-benchmark"
                                  :task-id (format nil "task-~D" index))))
            (event (list :event :evaluation :split :held-out
                         :candidate-id "c-bounded"
                         :campaign-id "bounded-campaign"
                         :run-id "bounded-next"
                         :benchmark-id "bounded-benchmark"
                         :task-id "task-next")))
       (check (funcall validate event (subseq prior 0 255))
              "the 256th held-out row is admitted")
       (check (%signals-error-p (lambda () (funcall validate event prior)))
              "the 257th held-out row is rejected")))))

(defun test-evolution-freeze-surface-and-symlink-scope ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let* ((actors (%make-actors))
            (source (%make-image directory "surface.core" #(10 20 30 40)))
            (required '(:creator :created-at :theory-fingerprint
                        :prompt-schema-sha256 :tool-schema-sha256
                        :changed-components :budgets :activation-evidence)))
       (dolist (missing required)
         (let* ((store-path (merge-pathnames
                             (format nil "missing-~(~A~)/" missing) directory))
                (store (%open-test-store store-path actors))
                (arguments (%plist-without
                            (%base-freeze-arguments (%actor actors :creator))
                            missing)))
           (check (%signals-error-p
                   (lambda () (%freeze store source (%actor actors :creator)
                                        :arguments arguments)))
                  (format nil "missing ~S is rejected" missing))
           (check (null (%evo-call "READ-LEDGER" store))
                  "invalid input causes no freeze event")
           (%close-test-store store)))
       (dolist (budget-key '(:development-cost-microusd :wall-time-ms
                             :input-tokens :output-tokens))
         (let* ((store (%open-test-store
                        (merge-pathnames (format nil "budget-~(~A~)/" budget-key)
                                         directory)
                        actors))
                (arguments (%base-freeze-arguments (%actor actors :creator))))
           (setf (getf arguments :budgets)
                 (%plist-without (getf arguments :budgets) budget-key))
           (check (%signals-error-p
                   (lambda () (%freeze store source (%actor actors :creator)
                                        :arguments arguments)))
                  (format nil "missing budget ~S is rejected" budget-key))
           (check (null (%evo-call "READ-LEDGER" store)))
           (%close-test-store store)))
       ;; Discover the deterministic target in one store, then put a symlink at
       ;; that exact target in another store.  The freeze must not follow it.
       (let* ((probe-store (%open-test-store (merge-pathnames "probe/" directory)
                                             actors))
              (arguments (%base-freeze-arguments (%actor actors :creator)))
              (probe-manifest (%freeze probe-store source (%actor actors :creator)
                                       :arguments arguments))
              (candidate-id (%candidate-id probe-manifest))
              (attack-store (%open-test-store (merge-pathnames "attack/" directory)
                                              actors))
              (candidate-directory
                (%evo-call "CANDIDATE-DIRECTORY" attack-store candidate-id))
              (link-name (string-right-trim "/" (namestring candidate-directory)))
              (outside (merge-pathnames "outside/" directory))
              (marker (merge-pathnames "marker" outside)))
         (ensure-directories-exist marker)
         (%write-string marker "unchanged")
         (ensure-directories-exist
          (make-pathname :directory
                         (butlast (pathname-directory candidate-directory))
                         :name "anchor"))
         (sb-posix:symlink (namestring outside) link-name)
         (check (%signals-error-p
                 (lambda () (%freeze attack-store source (%actor actors :creator)
                                      :arguments arguments)))
                "a pre-existing symlink target is rejected")
         (check (string= "unchanged" (%read-string marker))
                "freeze never writes through the symlink")
         (check (null (%evo-call "READ-LEDGER" attack-store)))
         (%close-test-store probe-store)
         (%close-test-store attack-store))))))

(defun test-evolution-managed-entry-symlink-confinement ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore baseline candidate))
         (%record-comparison-matrix store actors baseline-id candidate-id)
         (let ((decision (%make-decision store baseline-id candidate-id
                                         (%actor actors :authorizer))))
           (%evo-call "PROMOTE-CANDIDATE!" store decision
                      :pointer :canary
                      :authorizer (%actor actors :authorizer)))
         (let* ((ledger (%evo-call "LEDGER-PATH" store))
                (head (%evo-call "LEDGER-HEAD-PATH" store))
                (manifest (%evo-call "CANDIDATE-MANIFEST-PATH"
                                     store candidate-id))
                (image (%evo-call "CANDIDATE-IMAGE-PATH" store candidate-id))
                (pointer (%evo-call "POINTER-PATH" store :canary))
                (candidates (merge-pathnames "candidates/" store-path))
                (pointers (merge-pathnames "pointers/" store-path))
                (ledger-before (%read-octets ledger))
                (head-before (%read-octets head))
                (manifest-before (%read-octets manifest))
                (image-before (%read-octets image))
                (pointer-before (%read-octets pointer)))
           ;; Each symlink points to the exact valid bytes that were moved out
           ;; of the managed name.  A content-following implementation would
           ;; therefore succeed; rejection proves the lstat boundary.
           (%call-with-entry-replaced-by-self-symlink
            store-path
            (lambda ()
              (check (%signals-error-p
                      (lambda () (%evo-call "READ-LEDGER" store)))
                     "a symlinked store root is rejected before traversal")
              (check (%signals-error-p
                      (lambda () (%open-test-store store-path actors)))
                     "opening a symlinked store root is rejected")))
           (check (equalp ledger-before (%read-octets ledger))
                  "root rejection leaves the moved outside ledger unchanged")
           (%call-with-entry-replaced-by-self-symlink
            candidates
            (lambda ()
              (check (%rejected-p
                      (lambda ()
                        (%evo-call "VERIFY-CANDIDATE" store candidate-id)))
                     "a symlinked candidates ancestor is rejected")))
           (check (equalp image-before (%read-octets image))
                  "candidate ancestor rejection leaves outside bytes unchanged")
           (%call-with-entry-replaced-by-self-symlink
            pointers
            (lambda ()
              (check (%signals-error-p
                      (lambda () (%evo-call "READ-POINTER" store :canary)))
                     "a symlinked pointers ancestor is rejected")))
           (check (equalp pointer-before (%read-octets pointer))
                  "pointer ancestor rejection leaves outside bytes unchanged")
           (%call-with-entry-replaced-by-self-symlink
            ledger
            (lambda ()
              (check (%signals-error-p
                      (lambda () (%evo-call "READ-LEDGER" store)))
                     "a symlinked ledger leaf is rejected")))
           (%call-with-entry-replaced-by-self-symlink
            head
            (lambda ()
              (check (%signals-error-p
                      (lambda () (%evo-call "READ-LEDGER-HEAD" store)))
                     "a symlinked signed-head leaf is rejected")))
           (%call-with-entry-replaced-by-self-symlink
            manifest
            (lambda ()
              (check (%signals-error-p
                      (lambda ()
                        (%evo-call "READ-CANDIDATE-MANIFEST"
                                   store candidate-id)))
                     "a symlinked manifest leaf is rejected")))
           (%call-with-entry-replaced-by-self-symlink
            image
            (lambda ()
              (check (%rejected-p
                      (lambda ()
                        (%evo-call "VERIFY-CANDIDATE" store candidate-id)))
                     "a symlinked candidate image leaf is rejected")))
           (%call-with-entry-replaced-by-self-symlink
            pointer
            (lambda ()
              (check (%signals-error-p
                      (lambda () (%evo-call "READ-POINTER" store :canary)))
                     "a symlinked pointer leaf is rejected")))
           ;; A predictable temporary-name collision must use exclusive
           ;; creation.  Otherwise a regular hard link could redirect the
           ;; pre-rename write into an operator file outside the store.
           (let* ((outside (merge-pathnames "outside-hardlink" directory))
                  (outside-before "outside-bytes-must-survive")
                  (seed (sb-ext:seed-random-state 26014))
                  (prediction (make-random-state seed))
                  (suffix (random 1000000000 prediction))
                  (now (get-universal-time))
                  (peers
                    (loop for delta from -1 to 3
                          collect
                          (parse-namestring
                           (format nil "~A.tmp-~D-~D"
                                   (namestring pointer) (+ now delta) suffix)))))
             (%write-string outside outside-before)
             (unwind-protect
                  (progn
                    (dolist (peer peers)
                      (sb-posix:link (namestring outside) (namestring peer)))
                    (let ((*random-state* (make-random-state seed)))
                      (check (%signals-error-p
                              (lambda ()
                                (%evo-call "%ATOMIC-WRITE-STRING"
                                           pointer "replacement")))
                             "a pre-existing atomic temp peer is rejected"))
                    (check (string= outside-before (%read-string outside))
                           "temp-peer collision cannot overwrite hardlinked outside bytes"))
               (dolist (peer peers)
                 (when (probe-file peer) (ignore-errors (delete-file peer))))))
           (check (equalp ledger-before (%read-octets ledger)))
           (check (equalp head-before (%read-octets head)))
           (check (equalp manifest-before (%read-octets manifest)))
           (check (equalp image-before (%read-octets image)))
           (check (equalp pointer-before (%read-octets pointer))
                  "all symlink probes preserve the moved outside files"))
         (%close-test-store store))))))

;; ----------------------------------------- TEST-008, TEST-009, TEST-032 ---

(defun test-evolution-lineage-and-surface-round-trip ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let* ((actors (%make-actors))
            (store (%open-test-store (merge-pathnames "store/" directory) actors))
            (root-image (%make-image directory "root.core" #(1 3 3 7)))
            (child-image (%make-image directory "child.core" #(2 4 6 8)))
            (root (%freeze store root-image (%actor actors :creator)))
            (root-id (%candidate-id root))
            (root-digest (getf root :image-sha256))
            (child (%freeze store child-image (%actor actors :creator-2)
                            :parent-id root-id
                            :parent-image-sha256 root-digest))
            (child-id (%candidate-id child))
            (round-trip (%evo-call "READ-CANDIDATE-MANIFEST" store child-id)))
       (check (equal child round-trip) "the full manifest survives persistence")
       (check (string= root-id (getf child :parent-id)))
       (check (string= root-digest (getf child :parent-image-sha256)))
       (check (string= +evolution-sha-a+ (getf child :theory-fingerprint)))
       (check (string= +evolution-sha-b+ (getf child :prompt-schema-sha256)))
       (check (string= +evolution-sha-c+ (getf child :tool-schema-sha256)))
       (check (equal '("prompt/system" "tools/weather")
                     (getf child :changed-components)))
       (check (equal '("prompt/system:sha256:aa" "tools/weather:dispatch:1")
                     (getf child :activation-evidence)))
       (check (equal '(:development-cost-microusd 1200
                       :wall-time-ms 2500
                       :input-tokens 300
                       :output-tokens 100)
                     (getf child :budgets)))
       (check (%evo-call "VERIFY-CANDIDATE" store root-id))
       (check (%evo-call "VERIFY-CANDIDATE" store child-id))
       ;; A fully parseable but false parent digest must invalidate the child.
       (let* ((path (%evo-call "CANDIDATE-MANIFEST-PATH" store child-id))
              (original (%read-string path)))
         (unwind-protect
              (progn
                (%write-form path (%plist-put child :parent-image-sha256
                                              +evolution-sha-a+))
                (check (%rejected-p
                        (lambda () (%evo-call "VERIFY-CANDIDATE" store child-id)))
                       "parent digest mismatch invalidates lineage"))
           (%write-string path original)))
       ;; A syntactically valid but nonexistent parent is also invalid.
       (let* ((path (%evo-call "CANDIDATE-MANIFEST-PATH" store child-id))
              (original (%read-string path)))
         (unwind-protect
              (progn
                (%write-form path (%plist-put child :parent-id "missing-parent"))
                (check (%rejected-p
                        (lambda () (%evo-call "VERIFY-CANDIDATE" store child-id)))))
           (%write-string path original)))
       (check (equalp (%read-octets root-image) #(1 3 3 7))
              "lineage validation does not mutate a source")
       (%close-test-store store)))))

(defun test-evolution-persisted-freeze-evidence-required ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let* ((actors (%make-actors))
            (source-store (%open-test-store (merge-pathnames "source/" directory)
                                            actors))
            (target-store (%open-test-store (merge-pathnames "target/" directory)
                                            actors))
            (image (%make-image directory "injected.core" #(90 91 92 93)))
            (manifest (%freeze source-store image (%actor actors :creator)))
            (candidate-id (%candidate-id manifest))
            (source-image (%evo-call "CANDIDATE-IMAGE-PATH"
                                     source-store candidate-id))
            (source-manifest (%evo-call "CANDIDATE-MANIFEST-PATH"
                                        source-store candidate-id))
            (target-directory (%evo-call "CANDIDATE-DIRECTORY"
                                         target-store candidate-id))
            (target-name (string-right-trim "/" (namestring target-directory)))
            (freeze-event
              (find candidate-id (%evo-call "READ-LEDGER" source-store)
                    :key (lambda (event) (getf event :candidate-id))
                    :test #'string=))
            (actor-event
              (%plist-without-keys freeze-event
                                   '(:seq :previous-hash :event-hash))))
       (check (%evo-call "VERIFY-CANDIDATE" source-store candidate-id))
       ;; Copying a fully valid, creator-signed immutable directory into a
       ;; different store is not a freeze.  The target ledger is the root of
       ;; persistence provenance and initially contains no matching evidence.
       (sb-posix:mkdir target-name #o700)
       (%write-octets (merge-pathnames "image.core" target-directory)
                      (%read-octets source-image))
       (%write-string (merge-pathnames "manifest.sexp" target-directory)
                      (%read-string source-manifest))
       (check (equal manifest
                     (%evo-call "READ-CANDIDATE-MANIFEST"
                                target-store candidate-id))
              "the injected directory retains a correctly signed manifest")
       (check (%rejected-p
               (lambda ()
                 (%evo-call "VERIFY-CANDIDATE" target-store candidate-id)))
              "a signed candidate without a freeze event is not persisted")
       ;; One exact creator-signed freeze record establishes provenance.  A
       ;; second record for the same candidate makes provenance ambiguous and
       ;; must fail the exactly-one invariant.
       (%evo-call "%APPEND-EVENT-UNLOCKED" target-store actor-event)
       (check (%evo-call "VERIFY-CANDIDATE" target-store candidate-id)
              "one exact valid freeze event establishes provenance")
       (%evo-call "%APPEND-EVENT-UNLOCKED" target-store actor-event)
       (check (%rejected-p
               (lambda ()
                 (%evo-call "VERIFY-CANDIDATE" target-store candidate-id)))
              "duplicate freeze evidence is rejected")
       (%close-test-store source-store)
       (%close-test-store target-store)))))

;; ----------------------------------------- TEST-006, TEST-033 / signing ---

(defparameter +evolution-fixture-did+
  "did:key:z6MktwupdmLXVVqTzCw4i46r4uGyosGXRnR3XjN4Zq7oMMsw")

(defun %fixed-signing-identity ()
  "RFC 8032 test-vector key used only for signed-byte interoperability."
  (let* ((private-bytes
           (hex->bytes
            "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
         (public-bytes
           (hex->bytes
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"))
         (private-key (ironclad:make-private-key :ed25519
                                                 :x private-bytes
                                                 :y public-bytes))
         (public-key (ironclad:make-public-key :ed25519 :y public-bytes)))
    (make-instance 'agent-identity
                   :private-key private-key
                   :public-key public-key
                   :did +evolution-fixture-did+)))

(defun %signed-byte-fixtures ()
  (let ((manifest
          `(:version 1
            :candidate-id "c-fixed"
            :parent-id nil
            :parent-image-sha256 nil
            :image-file "agent.core"
            :image-sha256 ,+evolution-sha-a+
            :creator-did ,+evolution-fixture-did+
            :created-at ,+evolution-fixed-time+
            :theory-fingerprint ,+evolution-sha-a+
            :prompt-schema-sha256 ,+evolution-sha-b+
            :tool-schema-sha256 ,+evolution-sha-c+
            :changed-components ("prompt/system")
            :budgets (:development-cost-microusd 12
                      :wall-time-ms 34
                      :input-tokens 56
                      :output-tokens 78)
            :activation-evidence ("prompt/system:sha256:aa")))
        (event
          `(:event :evaluation
            :timestamp ,+evolution-fixed-time+
            :candidate-id "c-fixed"
            :run-id "run-1"
            :campaign-id "campaign-fixed"
            :benchmark-id "benchmark-fixed"
            :split :held-out
            :task-id "task-1"
            :replicate-index 1
            :evaluation-plan-sha256 ,+evolution-sha-a+
            :executor-config-sha256 ,+evolution-sha-b+
            :scorer-config-sha256 ,+evolution-sha-c+
            :executor-did ,+evolution-fixture-did+
            :evaluator-did ,+evolution-fixture-did+
            :run-complete-p t
            :task-correct-p t
            :capability-score-micros 750000
            :activation-evidence
            ((:component "prompt/system"
              :kind :runtime-hit
              :artifact-sha256 ,+evolution-sha-a+))
            :duration-ms 123
            :input-tokens 45
            :output-tokens 6
            :estimated-cost-microusd 78))
        (decision
          `(:event :decision
            :timestamp ,+evolution-fixed-time+
            :candidate-id "c-fixed"
            :baseline-id "b-fixed"
            :campaign-id "campaign-fixed"
            :evidence-head ,+evolution-sha-b+
            :minimum-held-out-repetitions 3
            :minimum-distinct-executors 2
            :minimum-capability-delta-micros 1
            :maximum-execution-token-increase 0
            :maximum-runtime-cost-increase-microusd 0
            :gates (:candidate-digest-valid t
                    :baseline-digest-valid t
                    :comparison-cells-match t
                    :candidate-cells-unique t
                    :single-evaluation-plan-context t
                    :replicate-templates-match t
                    :minimum-held-out-repetitions-met t
                    :minimum-distinct-executors-met t
                    :correctness-retained t
                    :changed-components-activated t
                    :runs-complete t
                    :creator-evaluator-separated t
                    :roles-pairwise-distinct t
                    :trusted-actor-signatures t
                    :replicate-capability-delta-met t
                    :per-executor-config-capability-delta-met t
                    :execution-token-increase-within-limit t
                    :runtime-cost-increase-within-limit t
                    :authorizer-rosters-disjoint t
                    :authorizer-creators-separated t
                    :trusted-authorizer-signature t)
            :failed-gates nil
            :baseline-capability-mean-micros 500000
            :candidate-capability-mean-micros 750000
            :capability-delta-micros 250000
            :replicate-capability-deltas
            ((:replicate-index 1
              :baseline-capability-mean-micros 500000
              :candidate-capability-mean-micros 750000
              :capability-delta-micros 250000))
            :conservative-capability-delta-micros 250000
            :executor-capability-deltas
            ((:executor-did ,+evolution-fixture-did+
              :executor-config-sha256 ,+evolution-sha-b+
              :baseline-capability-mean-micros 500000
              :candidate-capability-mean-micros 750000
              :capability-delta-micros 250000))
            :baseline-execution-tokens-total 40
            :candidate-execution-tokens-total 51
            :baseline-execution-tokens-mean-per-event 40
            :candidate-execution-tokens-mean-per-event 51
            :execution-token-delta 11
            :baseline-runtime-cost-microusd-total 70
            :candidate-runtime-cost-microusd-total 78
            :baseline-runtime-cost-microusd-mean-per-event 70
            :candidate-runtime-cost-microusd-mean-per-event 78
            :runtime-cost-delta-microusd 8
            :development-cost-microusd 12
            :eligible-p t
            :authorizer-did ,+evolution-fixture-did+))
        (head `(:seq 7
                :event-hash ,+evolution-sha-c+
                :authority-did ,+evolution-fixture-did+)))
    (list
     (list :manifest manifest
           "(:version 1 :candidate-id \"c-fixed\" :parent-id nil :parent-image-sha256 nil :image-file \"agent.core\" :image-sha256 \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\" :creator-did \"did:key:z6MktwupdmLXVVqTzCw4i46r4uGyosGXRnR3XjN4Zq7oMMsw\" :created-at \"2026-09-04T00:00:00Z\" :theory-fingerprint \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\" :prompt-schema-sha256 \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\" :tool-schema-sha256 \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\" :changed-components (\"prompt/system\") :budgets (:development-cost-microusd 12 :wall-time-ms 34 :input-tokens 56 :output-tokens 78) :activation-evidence (\"prompt/system:sha256:aa\"))"
           "0077eec6c4bebed589a902542ebf53f43ff1198f0b1705ee008fa351154242af0abe5f3b735251bd37a39d752f45ead393c6b0ac5b717616ce1a2a315c552d0f")
     (list :event event
           "(:event :evaluation :timestamp \"2026-09-04T00:00:00Z\" :candidate-id \"c-fixed\" :run-id \"run-1\" :campaign-id \"campaign-fixed\" :benchmark-id \"benchmark-fixed\" :split :held-out :task-id \"task-1\" :replicate-index 1 :evaluation-plan-sha256 \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\" :executor-config-sha256 \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\" :scorer-config-sha256 \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\" :executor-did \"did:key:z6MktwupdmLXVVqTzCw4i46r4uGyosGXRnR3XjN4Zq7oMMsw\" :evaluator-did \"did:key:z6MktwupdmLXVVqTzCw4i46r4uGyosGXRnR3XjN4Zq7oMMsw\" :run-complete-p t :task-correct-p t :capability-score-micros 750000 :activation-evidence ((:component \"prompt/system\" :kind :runtime-hit :artifact-sha256 \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\")) :duration-ms 123 :input-tokens 45 :output-tokens 6 :estimated-cost-microusd 78)"
           "b150c4c7c5bca293528c7e6f08da2c7ce97a5bfc5d3777728e743b46c38cfcc7dfe84c3a725b57403e6b341e405f3fff02aaa31c9b623b4e0988c9560bb5df02")
     (list :decision decision
           "(:event :decision :timestamp \"2026-09-04T00:00:00Z\" :candidate-id \"c-fixed\" :baseline-id \"b-fixed\" :campaign-id \"campaign-fixed\" :evidence-head \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\" :minimum-held-out-repetitions 3 :minimum-distinct-executors 2 :minimum-capability-delta-micros 1 :maximum-execution-token-increase 0 :maximum-runtime-cost-increase-microusd 0 :gates (:candidate-digest-valid t :baseline-digest-valid t :comparison-cells-match t :candidate-cells-unique t :single-evaluation-plan-context t :replicate-templates-match t :minimum-held-out-repetitions-met t :minimum-distinct-executors-met t :correctness-retained t :changed-components-activated t :runs-complete t :creator-evaluator-separated t :roles-pairwise-distinct t :trusted-actor-signatures t :replicate-capability-delta-met t :per-executor-config-capability-delta-met t :execution-token-increase-within-limit t :runtime-cost-increase-within-limit t :authorizer-rosters-disjoint t :authorizer-creators-separated t :trusted-authorizer-signature t) :failed-gates nil :baseline-capability-mean-micros 500000 :candidate-capability-mean-micros 750000 :capability-delta-micros 250000 :replicate-capability-deltas ((:replicate-index 1 :baseline-capability-mean-micros 500000 :candidate-capability-mean-micros 750000 :capability-delta-micros 250000)) :conservative-capability-delta-micros 250000 :executor-capability-deltas ((:executor-did \"did:key:z6MktwupdmLXVVqTzCw4i46r4uGyosGXRnR3XjN4Zq7oMMsw\" :executor-config-sha256 \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\" :baseline-capability-mean-micros 500000 :candidate-capability-mean-micros 750000 :capability-delta-micros 250000)) :baseline-execution-tokens-total 40 :candidate-execution-tokens-total 51 :baseline-execution-tokens-mean-per-event 40 :candidate-execution-tokens-mean-per-event 51 :execution-token-delta 11 :baseline-runtime-cost-microusd-total 70 :candidate-runtime-cost-microusd-total 78 :baseline-runtime-cost-microusd-mean-per-event 70 :candidate-runtime-cost-microusd-mean-per-event 78 :runtime-cost-delta-microusd 8 :development-cost-microusd 12 :eligible-p t :authorizer-did \"did:key:z6MktwupdmLXVVqTzCw4i46r4uGyosGXRnR3XjN4Zq7oMMsw\")"
           "53db45ce660a9f418b4a3fda0d350e0c2fd3741b4acfbfb9058749d0e6c7df0e8e7637e4e78b441c5f4bb18ca27f051ede936ab8479938e54a7731c7f9bac109")
     (list :head head
           "(:seq 7 :event-hash \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\" :authority-did \"did:key:z6MktwupdmLXVVqTzCw4i46r4uGyosGXRnR3XjN4Zq7oMMsw\")"
           "279af648be81df8436fe4028fbc4e2d61c8379c22a71a3614da84801e88b296514cc351195f75f20c863015d997ab4eadcc1cd8463dee81e7e14e7943b899103"))))

(defun test-evolution-canonical-bytes-and-actor-signatures ()
  (let ((identity (%fixed-signing-identity)))
    (check (equalp
            (hex->bytes
             "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
            (parse-did-key +evolution-fixture-did+))
           "the fixed DID decodes to exactly the RFC public key")
    (dolist (fixture (%signed-byte-fixtures))
      (destructuring-bind (name value expected-text expected-signature) fixture
        (let* ((bytes-1 (%evo-call "CANONICAL-BYTES" value))
               (bytes-2 (%evo-call "CANONICAL-BYTES" value))
               (signature (sign-bytes identity bytes-1)))
          (check (equalp bytes-1 bytes-2)
                 (format nil "~S bytes are deterministic" name))
          (check (string= expected-text
                          (sb-ext:octets-to-string
                           bytes-1 :external-format :utf-8))
                 (format nil "~S uses the contract printer" name))
          (check (string= expected-signature (bytes->hex signature))
                 (format nil "~S matches the fixed Ed25519 signature" name))
          (check (verify-bytes +evolution-fixture-did+
                               bytes-1 (hex->bytes expected-signature)))
          (when (eq name :head)
            (check (equal value
                          (%evo-call "%HEAD-PAYLOAD" 7 +evolution-sha-c+
                                     +evolution-fixture-did+))
                   "the fixed head vector signs the production head payload")))))
    (dolist (bad (list 1.5 'not-a-keyword '(1 . 2)
                       (format nil "control~Ccharacter" #\Newline)))
      (check (%signals-error-p
              (lambda () (%evo-call "CANONICAL-BYTES" (list :value bad))))
             (format nil "canonical grammar rejects ~S" bad)))
    (let* ((parse (%evo-function "%READ-ONE-FORM-STRING"))
           (arabic-one (code-char #x0661))
           (fullwidth-one (code-char #xff11))
           (arabic-digest (make-string 64 :initial-element arabic-one))
           (fullwidth-signature
             (make-string 128 :initial-element fullwidth-one)))
      (dolist (identifier
                (list (string arabic-one)
                      (format nil "c-~C" arabic-one)
                      (string fullwidth-one)))
        (check (not (%evo-call "%CANDIDATE-ID-P" identifier))
               "candidate identifiers admit ASCII digits only"))
      (check (not (%evo-call "%SHA256-P" arabic-digest))
             "SHA-256 text rejects Unicode decimal digits")
      (check (not (%evo-call "%SIGNATURE-P" fullwidth-signature))
             "signature text rejects Unicode decimal digits")
      (dolist (text
                (list (string arabic-one)
                      (string fullwidth-one)
                      (format nil
                              "#A((~C) common-lisp:base-char . \"x\")"
                              arabic-one)
                      (format nil
                              "#A((~C) common-lisp:base-char . \"x\")"
                              fullwidth-one)))
        (check (%signals-error-p
                (lambda () (funcall parse text "ASCII digit grammar")))
               "canonical numeric syntax admits ASCII digits only")))
    (labels ((nest (value count)
               (if (zerop count) value (nest (list value) (1- count)))))
      (let* ((max-int (1- (expt 10 32)))
             (max-string (make-string 65536 :initial-element #\x))
             (max-list (make-list 4096))
             (depth-64 (nest nil 64))
             (node-boundary
               (list (make-list 4095) (make-list 4095)
                     (make-list 4095) (make-list 4094))))
        (dolist (value (list max-int (- max-int) max-string max-list
                             depth-64 node-boundary))
          (check (typep (%evo-call "CANONICAL-BYTES" value)
                        '(vector (unsigned-byte 8)))
                 "an exact encoder grammar boundary is accepted"))
        (dolist (value (list (expt 10 32) (make-string 65537)
                             (make-list 4097) (list depth-64)
                             (list (make-list 4095) (make-list 4095)
                                   (make-list 4095) (make-list 4095))
                             :provider-invented-keyword))
          (check (%signals-error-p
                  (lambda () (%evo-call "CANONICAL-BYTES" value)))
                 "one step beyond an encoder grammar boundary is rejected")))))
  (%call-with-evolution-directory
   (lambda (directory)
     (multiple-value-bind (store store-path baseline baseline-id
                           candidate candidate-id)
         (%make-candidate-pair directory (%make-actors))
       (declare (ignore store-path baseline baseline-id))
       (let* ((actors-slot nil))
         ;; Recovering the creator from the manifest proves a signed actor DID
         ;; is persisted; VERIFY-CANDIDATE proves its signature validates.
         (declare (ignore actors-slot))
         (check (and (stringp (getf candidate :creator-did))
                     (string= "did:key:z6Mk" (getf candidate :creator-did)
                              :end2 12)))
       (check (%valid-signature-hex-p (getf candidate :creator-signature)))
       (check (%evo-call "VERIFY-CANDIDATE" store candidate-id))
       (let* ((head (%evo-call "READ-LEDGER-HEAD" store))
              (payload (%plist-without head :authority-signature))
              (head-path (%evo-call "LEDGER-HEAD-PATH" store)))
         (check (verify-bytes (getf head :authority-did)
                              (%evo-call "CANONICAL-BYTES" payload)
                              (hex->bytes (getf head :authority-signature)))
                "a live store head signs its complete production payload")
         (unwind-protect
              (progn
                (%write-form head-path
                             (%plist-put head :authority-did
                                         +evolution-fixture-did+))
                (check (%signals-error-p
                        (lambda () (%evo-call "READ-LEDGER-HEAD" store)))
                       "tampering the head authority invalidates the head"))
           (%write-form head-path head)))
       (%close-test-store store))))))

;; -------------------------------- TEST-010, TEST-027, TEST-034 / ledger ---

(defun %lines (string)
  (remove "" (uiop:split-string string :separator '(#\Newline))
          :test #'string=))

(defun %join-lines (lines)
  (with-output-to-string (stream)
    (dolist (line lines) (write-line line stream))))

(defun %tamper-event-hash (ledger-string)
  (let* ((copy (copy-seq ledger-string))
         (marker ":event-hash \"")
         (start (search marker copy)))
    (unless start (error "No event hash in ledger fixture."))
    (let* ((position (+ start (length marker)))
           (current (char copy position)))
      (setf (char copy position) (if (char= current #\0) #\1 #\0)))
    copy))

(defun %rechain-evolution-event (event sequence previous-hash)
  "Return EVENT with fresh chain fields; actor signatures remain unchanged."
  (let* ((actor-event
           (%plist-without-keys event '(:seq :previous-hash :event-hash)))
         (with-chain
           (append actor-event
                   (list :seq sequence :previous-hash previous-hash))))
    (append with-chain
            (list :event-hash (%evo-call "%SHA256-VALUE" with-chain)))))

(defun test-evolution-evaluation-requires-prior-freeze ()
  "TEST-066: every evaluation split is ordered after its signed freeze."
  (%call-with-evolution-directory
   (lambda (directory)
     (dolist (split '(:feedback :development :selection :held-out))
       (let* ((actors (%make-actors))
              (label (string-downcase (symbol-name split)))
              (store-path
                (merge-pathnames (format nil "before-freeze-~A/" label)
                                 directory))
              (image (%make-image directory
                                  (format nil "before-freeze-~A.core" label)))
              (store (%open-test-store store-path actors)))
         (unwind-protect
              (let* ((manifest
                       (%freeze store image (%actor actors :creator)))
                     (candidate-id (%candidate-id manifest)))
                (%record-evaluation
                 store actors candidate-id
                 (format nil "before-freeze-~A" label)
                 "task-before-freeze" 500000
                 :campaign-id (format nil "before-freeze-~A" label)
                 :split split)
                (let* ((events (%evo-call "READ-LEDGER" store))
                       (evaluation
                         (%rechain-evolution-event
                          (second events) 1 +evolution-zero-sha256+))
                       (freeze
                         (%rechain-evolution-event
                          (first events) 2 (getf evaluation :event-hash)))
                       (ledger-text
                         (with-output-to-string (stream)
                           (dolist (event (list evaluation freeze))
                             (write-line
                              (funcall (%evo-function "%CANONICAL-STRING")
                                       event)
                              stream)))))
                  (%write-string (%evo-call "LEDGER-PATH" store) ledger-text)
                  (%evo-call "%WRITE-HEAD" store 2 (getf freeze :event-hash))
                  (check (%signals-error-p
                          (lambda () (%evo-call "READ-LEDGER" store)))
                         (format nil
                                 "~S evaluation before freeze is rejected"
                                 split))
                  (check (not (%evo-call "VERIFY-LEDGER" store))
                         "verification fails closed on reordered evidence")))
           (%close-test-store store)))))))

(defun test-evolution-ledger-chain-head-and-replay ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         (%record-comparison-matrix store actors baseline-id candidate-id)
         (let* ((decision (%make-decision store baseline-id candidate-id
                                          (%actor actors :authorizer)))
                (ignored (%evo-call "PROMOTE-CANDIDATE!" store decision
                                    :pointer :canary
                                    :authorizer (%actor actors :authorizer)))
                (events (%evo-call "READ-LEDGER" store))
                (head (%evo-call "READ-LEDGER-HEAD" store)))
           (declare (ignore ignored))
           (check (%evo-call "VERIFY-LEDGER" store))
           (check (every (lambda (pair)
                           (= (car pair) (getf (cdr pair) :seq)))
                         (loop for event in events
                               for sequence from 1
                               collect (cons sequence event)))
                  "sequence numbers are contiguous")
           (dolist (kind '(:freeze :evaluation :decision :promotion))
             (check (%event-of-kind events kind)
                    (format nil "ledger contains ~S" kind)))
           (check (= (length events) (getf head :seq)))
           (check (string= (getf (car (last events)) :event-hash)
                           (getf head :event-hash)))
           (check (%valid-signature-hex-p (getf head :authority-signature))
                  "the terminal head carries an authority signature")
           (let* ((ledger-path (%evo-call "LEDGER-PATH" store))
                  (head-path (%evo-call "LEDGER-HEAD-PATH" store))
                  (ledger-before (%read-string ledger-path))
                  (head-before (%read-string head-path))
                  (pointer-path (%evo-call "POINTER-PATH" store :canary))
                  (pointer-before (%evo-call "READ-POINTER" store :canary))
                  (pointer-bytes-before (%read-octets pointer-path)))
             ;; Duplicate run IDs are rejected without changing either file.
             (check (%signals-error-p
                     (lambda ()
                       (%record-evaluation store actors candidate-id
                                           "matrix-c1" "task-replay" 999999)))
                    "a run identifier is globally unique")
             (check (string= ledger-before (%read-string ledger-path)))
             (check (string= head-before (%read-string head-path)))
             ;; Each complete corruption must be detected.  Readers may ignore
             ;; only an incomplete final line whose valid prefix matches HEAD.
             (dolist (corrupt
                       (list
                        (%tamper-event-hash ledger-before)
                        (%join-lines (reverse (%lines ledger-before)))
                        (%join-lines (butlast (%lines ledger-before)))
                        (concatenate 'string ledger-before
                                     (format nil "(:event :bogus)~%"))))
               (%write-string ledger-path corrupt)
               (check (%ledger-rejected-p store))
               (check (%signals-error-p
                       (lambda () (%evo-call "READ-LEDGER" store)))
                      "a complete chain corruption is rejected by the reader")
               (check (%signals-error-p
                       (lambda () (%evo-call "READ-LEDGER-HEAD" store)))
                      "the exported head observer validates ledger correspondence")
               (check (%signals-error-p
                       (lambda () (%evo-call "READ-POINTER" store :canary)))
                      "pointer reads fail closed on corrupt ledger evidence")
               (check (equalp pointer-bytes-before (%read-octets pointer-path))
                      "failed pointer verification never changes pointer bytes")
               (check (string= head-before (%read-string head-path)))
               (%write-string ledger-path ledger-before))
             ;; The detached signed head is part of every pointer read's trust
             ;; root, not a diagnostic optional check.
             (%write-string head-path (concatenate 'string head-before "junk"))
             (check (%signals-error-p
                     (lambda () (%evo-call "READ-POINTER" store :canary)))
                    "pointer reads fail closed on corrupt signed head evidence")
             (check (equalp pointer-bytes-before (%read-octets pointer-path)))
             (%write-string head-path head-before)
             (%write-string ledger-path
                            (concatenate 'string ledger-before "(:event"))
             (check (%evo-call "VERIFY-LEDGER" store)
                    "an incomplete final line is ignored")
             (check (= (length events)
                       (length (%evo-call "READ-LEDGER" store))))
             (check (string= pointer-before
                             (%evo-call "READ-POINTER" store :canary))
                    "an incomplete suffix preserves the signed pointer view")
             (check (equalp pointer-bytes-before (%read-octets pointer-path)))
             (%write-string ledger-path ledger-before)
             (check (%evo-call "VERIFY-LEDGER" store))))
         (%close-test-store store))))))

;; ---------------------------------------- TEST-011, TEST-035 / rosters ---

(defun test-evolution-disjoint-role-rosters ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let* ((actors (%make-actors))
            (overlap (list (%did actors :executor-1))))
       (check (%signals-error-p
               (lambda ()
                 (%open-test-store (merge-pathnames "overlap/" directory) actors
                                   :executor-dids overlap
                                   :evaluator-dids overlap)))
              "executor and evaluator trust rosters must be disjoint")
       (let* ((executor-string (copy-seq (%did actors :executor-1)))
              (evaluator-string (copy-seq (%did actors :evaluator-1)))
              (authorizer-string (copy-seq (%did actors :authorizer)))
              (executor-roster (list executor-string))
              (evaluator-roster (list evaluator-string))
              (authorizer-roster (list authorizer-string))
              (store
                (%open-test-store
                 (merge-pathnames "roster-copy/" directory) actors
                 :executor-dids executor-roster
                 :evaluator-dids evaluator-roster
                 :authorizer-dids authorizer-roster)))
         (replace executor-string (%did actors :outsider))
         (replace evaluator-string (%did actors :outsider))
         (replace authorizer-string (%did actors :outsider))
         (setf (car executor-roster) (%did actors :outsider)
               (car evaluator-roster) (%did actors :outsider)
               (car authorizer-roster) (%did actors :outsider))
         (check (equal (list (%did actors :executor-1))
                       (%evo-call "STORE-TRUSTED-EXECUTORS" store))
                "the executor roster owns its DID strings")
         (check (equal (list (%did actors :evaluator-1))
                       (%evo-call "STORE-TRUSTED-EVALUATORS" store))
                "the evaluator roster owns its DID strings")
         (check (equal (list (%did actors :authorizer))
                       (%evo-call "STORE-TRUSTED-AUTHORIZERS" store))
                "the authorizer roster owns its DID strings")
         (%close-test-store store))
       (let* ((authority-actors (%make-actors))
              (expected
                (copy-seq (%did authority-actors :authority)))
              (store
                (%open-test-store
                 (merge-pathnames "authority-did-copy/" directory)
                 authority-actors)))
         (replace (%did authority-actors :authority)
                  (%did authority-actors :outsider))
         (check (string= expected (%evo-call "STORE-AUTHORITY-DID" store))
                "the store owns its authority DID string")
         (%close-test-store store))
       ;; Enrol the creator in exactly the attempted actor roster so these
       ;; probes reach pairwise role separation rather than failing roster
       ;; membership first.
       (dolist (creator-role '(:executor :evaluator))
         (let* ((root (merge-pathnames
                       (format nil "creator-as-~(~A~)/" creator-role) directory))
                (store
                  (%open-test-store
                   root actors
                   :executor-dids
                   (if (eq creator-role :executor)
                       (list (%did actors :creator) (%did actors :executor-1))
                       (list (%did actors :executor-1) (%did actors :executor-2)))
                   :evaluator-dids
                   (if (eq creator-role :evaluator)
                       (list (%did actors :creator) (%did actors :evaluator-1))
                       (list (%did actors :evaluator-1)
                             (%did actors :evaluator-2)))))
                (image (%make-image
                        directory (format nil "creator-~(~A~).core" creator-role)
                        #(8 8 8)))
                (candidate-id
                  (%candidate-id (%freeze store image (%actor actors :creator)))))
           (check (%signals-error-p
                   (lambda ()
                     (%record-evaluation
                      store actors candidate-id
                      (format nil "creator-~(~A~)" creator-role) "role-task"
                      500000
                      :executor (if (eq creator-role :executor)
                                    :creator :executor-1)
                      :evaluator (if (eq creator-role :evaluator)
                                     :creator :evaluator-1))))
                  "an enrolled creator cannot be reused as held-out actor")
           (check (null (%events-of-kind (%evo-call "READ-LEDGER" store)
                                         :evaluation)))
           (%close-test-store store)))
       (let* ((store (%open-test-store (merge-pathnames "valid/" directory) actors))
              (image (%make-image directory "roles.core" #(4 5 6)))
              (manifest (%freeze store image (%actor actors :creator)))
              (candidate-id (%candidate-id manifest)))
         (flet ((attempt (run executor evaluator)
                  (%record-evaluation store actors candidate-id run "role-task" 500000
                                      :executor executor :evaluator evaluator)))
           (check (%signals-error-p
                   (lambda () (attempt "creator-executor"
                                       :creator :evaluator-1))))
           (check (%signals-error-p
                   (lambda () (attempt "creator-evaluator"
                                       :executor-1 :creator))))
           (check (%signals-error-p
                   (lambda () (attempt "same-role"
                                       :executor-1 :executor-1))))
           (check (%signals-error-p
                   (lambda () (attempt "unknown-evaluator"
                                       :executor-1 :outsider))))
           (check (attempt "valid-roles" :executor-1 :evaluator-1)
                  "distinct enrolled actors can attest a held-out run"))
         (let ((event (%event-of-kind (%evo-call "READ-LEDGER" store)
                                      :evaluation)))
           (check (string= (%did actors :executor-1) (getf event :executor-did)))
           (check (string= (%did actors :evaluator-1) (getf event :evaluator-did)))
           (check (%valid-signature-hex-p (getf event :executor-signature)))
           (check (%valid-signature-hex-p (getf event :evaluator-signature))))
         (%close-test-store store))))))

;; ------------------------------------------ TEST-036 / protocol envelope ---

(defun test-evolution-signed-protocol-envelope ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let* ((actors (%make-actors))
            (store (%open-test-store (merge-pathnames "store/" directory) actors))
            (image (%make-image directory "envelope.core" #(36 36 36)))
            (manifest (%freeze store image (%actor actors :creator)))
            (candidate-id (%candidate-id manifest))
            (arguments
              (list store
                    :run-id "envelope-1"
                    :campaign-id "campaign-envelope"
                    :benchmark-id "benchmark-envelope"
                    :split :held-out
                    :task-id "task-envelope"
                    :replicate-index 7
                    :evaluation-plan-sha256 +evolution-sha-a+
                    :executor-config-sha256 +evolution-sha-b+
                    :scorer-config-sha256 +evolution-sha-c+
                    :candidate-id candidate-id
                    :executor (%actor actors :executor-1)
                    :evaluator (%actor actors :evaluator-1)
                    :run-complete-p t
                    :task-correct-p t
                    :capability-score-micros 765432
                    :activation-evidence
                    (%runtime-activation-evidence store candidate-id)
                    :duration-ms 321
                    :input-tokens 45
                    :output-tokens 6
                    :estimated-cost-microusd 78)))
       (%evo-apply "RECORD-EVALUATION!" arguments)
       (let* ((events (%evo-call "READ-LEDGER" store))
              (event (%event-of-kind events :evaluation))
              (expected-keys
                '(:event :timestamp :candidate-id :run-id :campaign-id
                  :benchmark-id :split :task-id :replicate-index
                  :evaluation-plan-sha256 :executor-config-sha256
                  :scorer-config-sha256 :executor-did :evaluator-did
                  :run-complete-p :task-correct-p :capability-score-micros
                  :activation-evidence :duration-ms :input-tokens
                  :output-tokens :estimated-cost-microusd
                  :executor-signature :evaluator-signature
                  :seq :previous-hash :event-hash)))
         (check (equal expected-keys
                       (loop for key in event by #'cddr collect key))
                "the persisted event uses the exact closed field order")
         (check (string= "campaign-envelope" (getf event :campaign-id)))
         (check (string= "benchmark-envelope" (getf event :benchmark-id)))
         (check (= 7 (getf event :replicate-index)))
         (check (getf event :run-complete-p))
         (check (equal (%runtime-activation-evidence store candidate-id)
                       (getf event :activation-evidence)))
         (check (%valid-signature-hex-p (getf event :executor-signature)))
         (check (%valid-signature-hex-p (getf event :evaluator-signature)))
         (let ((verify-actors (%evo-function "%VERIFY-EVENT-ACTORS")))
           (dolist (mutation
                     `((:campaign-id "campaign-altered")
                       (:benchmark-id "benchmark-altered")
                       (:replicate-index 8)
                       (:evaluation-plan-sha256 ,+evolution-sha-b+)
                       (:executor-config-sha256 ,+evolution-sha-c+)
                       (:scorer-config-sha256 ,+evolution-sha-a+)
                       (:run-complete-p nil)))
             (check (not (funcall verify-actors
                                  store
                                  (%plist-put event (first mutation)
                                              (second mutation))))
                    (format nil "both signatures bind added field ~S"
                            (first mutation))))
           (let* ((signature (getf event :executor-signature))
                  (altered (copy-seq signature)))
             (setf (char altered 0)
                   (if (char= (char altered 0) #\0) #\1 #\0))
             (check (not (funcall verify-actors
                                  store
                                  (%plist-put event :executor-signature
                                              altered)))
                    "an altered actor signature is rejected"))))
       (let ((ledger-count (length (%evo-call "READ-LEDGER" store))))
         (dolist (missing '(:campaign-id :benchmark-id :replicate-index
                            :evaluation-plan-sha256
                            :executor-config-sha256 :scorer-config-sha256
                            :run-complete-p))
           (let ((without
                   (cons store (%plist-without (cdr arguments) missing))))
             (check (%signals-error-p
                     (lambda () (%evo-apply "RECORD-EVALUATION!" without)))
                    (format nil "omitted envelope field ~S is rejected"
                            missing))
             (check (= ledger-count
                       (length (%evo-call "READ-LEDGER" store))))))
         (dolist (invalid
                   `((:campaign-id "")
                     (:benchmark-id "")
                     (:replicate-index 0)
                     (:evaluation-plan-sha256 "bad")
                     (:executor-config-sha256 "bad")
                     (:scorer-config-sha256 "bad")
                     (:run-complete-p :yes)))
           (let ((changed (copy-list (cdr arguments))))
             (setf (getf changed (first invalid)) (second invalid))
             (check (%signals-error-p
                     (lambda ()
                       (%evo-apply "RECORD-EVALUATION!"
                                   (cons store changed))))
                    (format nil "invalid envelope field ~S is rejected"
                            (first invalid)))
             (check (= ledger-count
                       (length (%evo-call "READ-LEDGER" store))))))
         (let ((unicode-digests
                 (list (make-string 64 :initial-element (code-char #x0661))
                       (make-string 64 :initial-element (code-char #xff11)))))
           (dolist (field '(:evaluation-plan-sha256
                            :executor-config-sha256
                            :scorer-config-sha256))
             (dolist (digest unicode-digests)
               (let ((changed (copy-list (cdr arguments))))
                 (setf (getf changed field) digest)
                 (check (%signals-error-p
                         (lambda ()
                           (%evo-apply "RECORD-EVALUATION!"
                                       (cons store changed))))
                        (format nil "~S rejects non-ASCII decimal digits"
                                field))
                 (check (= ledger-count
                           (length (%evo-call "READ-LEDGER" store)))))))))
       (%record-evaluation store actors candidate-id
                           "NIL" "task-nil-string" 765432
                           :campaign-id "campaign-envelope"
                           :benchmark-id "benchmark-envelope"
                           :replicate-index 8)
       (check (find "NIL" (%evo-call "READ-LEDGER" store)
                    :key (lambda (event) (getf event :run-id))
                    :test #'equal)
              "a valid run identifier cannot collide with missing plist keys")
       (%close-test-store store)))))

;; ------------------------------- TEST-037/038/039 / comparison isolation ---

(defun test-evolution-unmatched-comparison-cells ()
  (dolist (variant
            `((:benchmark-id "benchmark-other")
              (:task-id "task-other")
              (:replicate-index 9)
              (:executor :executor-2)
              (:evaluator :evaluator-2)
              (:evaluation-plan-sha256 ,+evolution-sha-b+)
              (:executor-config-sha256 ,+evolution-sha-a+)
              (:scorer-config-sha256 ,+evolution-sha-a+)))
    (%call-with-evolution-directory
     (lambda (directory)
       (let ((actors (%make-actors)))
         (multiple-value-bind (store store-path baseline baseline-id
                               candidate candidate-id)
             (%make-candidate-pair directory actors)
           (declare (ignore store-path baseline candidate))
           (dotimes (offset 3)
             (let* ((index (1+ offset))
                    (executor (if (oddp index) :executor-1 :executor-2))
                    (evaluator (if (oddp index) :evaluator-1 :evaluator-2))
                    (common (list :replicate-index index
                                  :executor executor :evaluator evaluator))
                    (candidate-options (copy-list common))
                    (baseline-task "task-1")
                    (candidate-task "task-1"))
               (when (zerop offset)
                 (if (eq (first variant) :task-id)
                     (setf candidate-task (second variant))
                     (setf (getf candidate-options (first variant))
                           (second variant))))
               (apply #'%record-evaluation store actors baseline-id
                      (format nil "cell-~(~A~)-b~D" (first variant) index)
                      baseline-task 500000 common)
               (apply #'%record-evaluation store actors candidate-id
                      (format nil "cell-~(~A~)-c~D" (first variant) index)
                      candidate-task 800000 candidate-options)))
           (let ((decision (%make-decision store baseline-id candidate-id
                                           (%actor actors :authorizer))))
             (check (not (getf (getf decision :gates)
                               :comparison-cells-match))
                    (format nil "cell dimension ~S is comparison-bound"
                            (first variant)))
             (check (member :comparison-cells-match
                            (getf decision :failed-gates))))
           (%close-test-store store)))))))

(defun test-evolution-duplicate-candidate-cells ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline baseline-id candidate))
         (%record-evaluation store actors candidate-id
                             "duplicate-cell-a" "task-1" 800000
                             :replicate-index 1)
         (let ((before (length (%evo-call "READ-LEDGER" store))))
           (check (%signals-error-p
                   (lambda ()
                     (%record-evaluation store actors candidate-id
                                         "duplicate-cell-b" "task-1" 900000
                                         :replicate-index 1)))
                  "a unique run id cannot duplicate a candidate cell")
           (check (= before (length (%evo-call "READ-LEDGER" store)))
                  "duplicate-cell rejection has no ledger effect"))
         (%close-test-store store)))
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair (merge-pathnames "valid/" directory) actors)
         (declare (ignore store-path baseline candidate))
         (%record-comparison-matrix store actors baseline-id candidate-id)
         (let ((decision (%make-decision store baseline-id candidate-id
                                         (%actor actors :authorizer))))
           (check (getf (getf decision :gates) :candidate-cells-unique)
                  "a valid comparison reports unique candidate cells"))
         (%close-test-store store))))))

(defun test-evolution-campaign-split-isolation ()
  (dolist (exposed '(:feedback :development :selection))
    (dolist (direction '(:exposed-first :held-out-first))
      (%call-with-evolution-directory
       (lambda (directory)
         (let ((actors (%make-actors)))
           (multiple-value-bind (store store-path baseline baseline-id
                                 candidate candidate-id)
               (%make-candidate-pair directory actors)
             (declare (ignore store-path baseline candidate))
             (flet ((record-exposed ()
                      (%record-evaluation
                       store actors baseline-id
                       (format nil "split-~(~A~)-~(~A~)-exposed"
                               exposed direction)
                       "task-shared" 500000 :split exposed
                       :campaign-id "campaign-split"
                       :benchmark-id "benchmark-split"
                       :replicate-index 1))
                    (record-held-out ()
                      (%record-evaluation
                       store actors candidate-id
                       (format nil "split-~(~A~)-~(~A~)-held"
                               exposed direction)
                       "task-shared" 800000 :split :held-out
                       :campaign-id "campaign-split"
                       :benchmark-id "benchmark-split"
                       :replicate-index 2)))
               (if (eq direction :exposed-first)
                   (record-exposed)
                   (record-held-out))
               (let ((before (length (%evo-call "READ-LEDGER" store))))
                 (check (%signals-error-p
                         (lambda ()
                           (if (eq direction :exposed-first)
                               (record-held-out)
                               (record-exposed))))
                        (format nil "~S contamination is rejected ~S"
                                exposed direction))
                 (check (= before (length (%evo-call "READ-LEDGER" store)))
                        "split contamination never appends")
                 (if (eq direction :exposed-first)
                     (%record-evaluation
                      store actors candidate-id
                      (format nil "split-~(~A~)-other-held" exposed)
                      "task-shared" 800000 :split :held-out
                      :campaign-id "campaign-split"
                      :benchmark-id "benchmark-other"
                      :replicate-index 2)
                     (%record-evaluation
                      store actors baseline-id
                      (format nil "split-~(~A~)-other-exposed" exposed)
                      "task-shared" 500000 :split exposed
                      :campaign-id "campaign-split"
                      :benchmark-id "benchmark-other"
                      :replicate-index 1))
                 (check (= (1+ before)
                           (length (%evo-call "READ-LEDGER" store)))
                        "the same task under another benchmark remains valid")))
             (%close-test-store store))))))))

;; ----------------------------- TEST-040/041 / replicate methodology ---

(defun test-evolution-complete-replicate-counting ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         ;; Two event rows on each side still represent only one replicate.
         (%record-paired-cell store actors baseline-id candidate-id
                              "rows-r1-a" 1 500000 800000
                              :task-id "task-a"
                              :executor :executor-1 :evaluator :evaluator-1)
         (%record-paired-cell store actors baseline-id candidate-id
                              "rows-r1-b" 1 500000 800000
                              :task-id "task-b"
                              :executor :executor-2 :evaluator :evaluator-2)
         (let ((decision (%make-decision store baseline-id candidate-id
                                         (%actor actors :authorizer)
                                         :minimum-repetitions 2)))
           (check (getf (getf decision :gates) :replicate-templates-match))
           (check (not (getf (getf decision :gates)
                             :minimum-held-out-repetitions-met))
                  "event rows cannot substitute for distinct replicates"))
         (%close-test-store store)))
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair (merge-pathnames "mismatch/" directory)
                                 actors)
         (declare (ignore store-path baseline candidate))
         (dotimes (offset 3)
           (let* ((index (1+ offset))
                  (task (if (= index 3) "task-other" "task-1"))
                  (executor (if (oddp index) :executor-1 :executor-2))
                  (evaluator (if (oddp index) :evaluator-1 :evaluator-2)))
             (%record-paired-cell store actors baseline-id candidate-id
                                  (format nil "template-r~D" index)
                                  index 500000 800000
                                  :task-id task
                                  :executor executor :evaluator evaluator)))
         (let ((decision (%make-decision store baseline-id candidate-id
                                         (%actor actors :authorizer))))
           (check (getf (getf decision :gates) :comparison-cells-match))
           (check (not (getf (getf decision :gates)
                             :replicate-templates-match)))
           (check (not (getf (getf decision :gates)
                             :minimum-held-out-repetitions-met))
                  "mismatched templates do not count as true replicates"))
         (%close-test-store store)))
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair (merge-pathnames "actor-mismatch/" directory)
                                 actors)
         (declare (ignore store-path baseline candidate))
         (loop for index from 1 to 3
               for baseline-executor = (if (oddp index)
                                           :executor-1 :executor-2)
               for baseline-evaluator = (if (oddp index)
                                            :evaluator-1 :evaluator-2)
               for candidate-executor = (if (oddp index)
                                            :executor-2 :executor-1)
               for candidate-evaluator = (if (oddp index)
                                             :evaluator-2 :evaluator-1)
               do (%record-evaluation
                   store actors baseline-id
                   (format nil "actor-mismatch-b~D" index)
                   "task-1" 500000
                   :campaign-id "actor-mismatch"
                   :replicate-index index
                   :executor baseline-executor
                   :evaluator baseline-evaluator)
                  (%record-evaluation
                   store actors candidate-id
                   (format nil "actor-mismatch-c~D" index)
                   "task-1" 800000
                   :campaign-id "actor-mismatch"
                   :replicate-index index
                   :executor candidate-executor
                   :evaluator candidate-evaluator))
         (let ((decision
                 (%make-decision store baseline-id candidate-id
                                 (%actor actors :authorizer)
                                 :campaign-id "actor-mismatch")))
           (check (getf (getf decision :gates) :replicate-templates-match)
                  "actor identities are outside the protocol template")
           (check (not (getf (getf decision :gates)
                             :comparison-cells-match)))
           (check (not (getf (getf decision :gates)
                             :minimum-held-out-repetitions-met))
                  "actor-mismatched cells are not complete replicates")
           (check (not (getf (getf decision :gates)
                             :minimum-distinct-executors-met))
                  "executor minimum is counted only in the common cells"))
         (%close-test-store store)))
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair (merge-pathnames "valid/" directory) actors)
         (declare (ignore store-path baseline candidate))
         (%record-comparison-matrix store actors baseline-id candidate-id)
         (let ((decision (%make-decision store baseline-id candidate-id
                                         (%actor actors :authorizer))))
           (check (getf (getf decision :gates) :replicate-templates-match))
           (check (getf (getf decision :gates)
                        :minimum-held-out-repetitions-met)
                  "three matched protocol replicates meet the default"))
         (%close-test-store store))))))

(defun test-evolution-conservative-replicate-noise-gate ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         (%record-comparison-matrix
          store actors baseline-id candidate-id
          :baseline-scores '(500000 500000 500000)
          :candidate-scores '(1000000 750000 750000))
         (let ((decision (%make-decision
                          store baseline-id candidate-id
                          (%actor actors :authorizer)
                          :minimum-capability-delta-micros 300000)))
           (check (>= (getf decision :capability-delta-micros) 300000)
                  "the pooled mean is a tempting false positive")
           (check (= 250000
                     (getf decision :conservative-capability-delta-micros)))
           (check (not (getf (getf decision :gates)
                             :replicate-capability-delta-met))
                  "one lucky replicate cannot hide weaker replicates")
           (check (not (getf decision :eligible-p))))
         (%close-test-store store)))
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair (merge-pathnames "equality/" directory) actors)
         (declare (ignore store-path baseline candidate))
         (%record-comparison-matrix
          store actors baseline-id candidate-id
          :baseline-scores '(500000 500000 500000)
          :candidate-scores '(800000 800000 800000))
         (let ((decision (%make-decision
                          store baseline-id candidate-id
                          (%actor actors :authorizer)
                          :minimum-capability-delta-micros 300000)))
           (check (= 300000
                     (getf decision :conservative-capability-delta-micros)))
           (check (getf (getf decision :gates)
                        :replicate-capability-delta-met)
                  "equality at the positive threshold passes"))
         (%close-test-store store))))))

;; ------------------------------ TEST-042/043/044 / efficiency budgets ---

(defun test-evolution-separated-efficiency-report ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         (loop for index from 1 to 3
               for baseline-input in '(10 20 30)
               for baseline-output in '(1 2 3)
               for candidate-input in '(12 24 36)
               for candidate-output in '(2 4 6)
               for baseline-cost in '(5 10 15)
               for candidate-cost in '(7 14 21)
               for executor = (if (oddp index) :executor-1 :executor-2)
               for evaluator = (if (oddp index) :evaluator-1 :evaluator-2)
               do (%record-paired-cell
                   store actors baseline-id candidate-id
                   (format nil "efficiency-r~D" index) index 500000 700000
                   :executor executor :evaluator evaluator
                   :baseline-options
                   (list :input-tokens baseline-input
                         :output-tokens baseline-output
                         :cost baseline-cost)
                   :candidate-options
                   (list :input-tokens candidate-input
                         :output-tokens candidate-output
                         :cost candidate-cost)))
         (let ((decision (%make-decision
                          store baseline-id candidate-id
                          (%actor actors :authorizer)
                          :maximum-execution-token-increase 18
                          :maximum-runtime-cost-increase-microusd 12)))
           (check (= 66 (getf decision :baseline-execution-tokens-total)))
           (check (= 84 (getf decision :candidate-execution-tokens-total)))
           (check (= 22 (getf decision
                              :baseline-execution-tokens-mean-per-event)))
           (check (= 28 (getf decision
                              :candidate-execution-tokens-mean-per-event)))
           (check (= 18 (getf decision :execution-token-delta)))
           (check (= 30
                     (getf decision :baseline-runtime-cost-microusd-total)))
           (check (= 42
                     (getf decision :candidate-runtime-cost-microusd-total)))
           (check (= 10
                     (getf decision
                           :baseline-runtime-cost-microusd-mean-per-event)))
           (check (= 14
                     (getf decision
                           :candidate-runtime-cost-microusd-mean-per-event)))
           (check (= 12 (getf decision :runtime-cost-delta-microusd)))
           (check (= 1200 (getf decision :development-cost-microusd)))
           (check (getf (getf decision :gates)
                        :execution-token-increase-within-limit))
           (check (getf (getf decision :gates)
                        :runtime-cost-increase-within-limit)))
         (%close-test-store store))))))

(defun %resource-gate-decision (directory actors token-increase cost-increase
                                maximum-token-increase maximum-cost-increase)
  (multiple-value-bind (store store-path baseline baseline-id
                        candidate candidate-id)
      (%make-candidate-pair directory actors)
    (declare (ignore store-path baseline candidate))
    (loop for index from 1 to 3
          for executor = (if (oddp index) :executor-1 :executor-2)
          for evaluator = (if (oddp index) :evaluator-1 :evaluator-2)
          do (%record-paired-cell
              store actors baseline-id candidate-id
              (format nil "budget-r~D" index) index 500000 700000
              :executor executor :evaluator evaluator
              :baseline-options '(:input-tokens 9 :output-tokens 1 :cost 10)
              :candidate-options
              (list :input-tokens (+ 9 (if (= index 1) token-increase 0))
                    :output-tokens 1
                    :cost (+ 10 (if (= index 1) cost-increase 0)))))
    (values store
            (%make-decision
             store baseline-id candidate-id (%actor actors :authorizer)
             :maximum-execution-token-increase maximum-token-increase
             :maximum-runtime-cost-increase-microusd maximum-cost-increase))))

(defun test-evolution-execution-token-increase-ceiling ()
  (dolist (case '((2 3 t) (3 3 t) (4 3 nil)))
    (%call-with-evolution-directory
     (lambda (directory)
       (let ((actors (%make-actors)))
         (multiple-value-bind (store decision)
             (%resource-gate-decision directory actors
                                      (first case) 0 (second case) 0)
           (check (= (first case) (getf decision :execution-token-delta)))
           (check (eq (third case)
                      (getf (getf decision :gates)
                            :execution-token-increase-within-limit))
                  (format nil "token increase ~D against ceiling ~D"
                          (first case) (second case)))
           (check (getf (getf decision :gates)
                        :runtime-cost-increase-within-limit))
           (%close-test-store store)))))))

(defun test-evolution-runtime-cost-increase-ceiling ()
  (dolist (case '((2 3 t) (3 3 t) (4 3 nil)))
    (%call-with-evolution-directory
     (lambda (directory)
       (let ((actors (%make-actors)))
         (multiple-value-bind (store decision)
             (%resource-gate-decision directory actors
                                      0 (first case) 0 (second case))
           (check (= (first case)
                     (getf decision :runtime-cost-delta-microusd)))
           (check (eq (third case)
                      (getf (getf decision :gates)
                            :runtime-cost-increase-within-limit))
                  (format nil "runtime cost increase ~D against ceiling ~D"
                          (first case) (second case)))
           (check (getf (getf decision :gates)
                        :execution-token-increase-within-limit))
           (%close-test-store store)))))))

;; ------------------------------- TEST-045 / executor-config transfer ---

(defun test-evolution-per-executor-config-transfer-gate ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors))
           (baseline-image (%make-image directory "cohort-b.core" #(45 1)))
           (candidate-image (%make-image directory "cohort-c.core" #(45 2))))
       (labels ((one-store (name reverse-p)
                  (let* ((store (%open-test-store
                                 (merge-pathnames (format nil "~A/" name)
                                                  directory)
                                 actors))
                         (baseline (%freeze store baseline-image
                                            (%actor actors :creator)))
                         (candidate (%freeze store candidate-image
                                             (%actor actors :creator-2)))
                         (baseline-id (%candidate-id baseline))
                         (candidate-id (%candidate-id candidate))
                         (rows
                           (loop for index from 1 to 3 append
                             (list
                              (list baseline-id
                                    (format nil "cohort-b~D-a" index)
                                    "task-a" 500000 index
                                    +evolution-sha-b+ :executor-1 :evaluator-1)
                              (list candidate-id
                                    (format nil "cohort-c~D-a" index)
                                    "task-a" 900000 index
                                    +evolution-sha-b+ :executor-1 :evaluator-1)
                              (list baseline-id
                                    (format nil "cohort-b~D-b" index)
                                    "task-b" 500000 index
                                    +evolution-sha-c+ :executor-1 :evaluator-2)
                              (list candidate-id
                                    (format nil "cohort-c~D-b" index)
                                    "task-b" 400000 index
                                    +evolution-sha-c+ :executor-1 :evaluator-2)))))
                    (when reverse-p (setf rows (reverse rows)))
                    (dolist (row rows)
                      (destructuring-bind
                          (id run task score index config executor evaluator) row
                        (%record-evaluation
                         store actors id run task score
                         :campaign-id "cohort"
                         :replicate-index index
                         :executor-config-sha256 config
                         :executor executor :evaluator evaluator)))
                    (values
                     store
                     (%make-decision
                      store baseline-id candidate-id
                      (%actor actors :authorizer)
                      :campaign-id "cohort"
                      :minimum-capability-delta-micros 100000)))))
         (multiple-value-bind (store-a decision-a)
             (one-store "forward" nil)
           (multiple-value-bind (store-b decision-b)
               (one-store "reverse" t)
             (check (= 150000 (getf decision-a :capability-delta-micros)))
             (check (= 150000
                       (getf decision-a
                             :conservative-capability-delta-micros)))
             (check (getf (getf decision-a :gates)
                          :replicate-capability-delta-met))
             (check (not (getf (getf decision-a :gates)
                               :per-executor-config-capability-delta-met))
                    "pooled gains cannot hide one executor/config regression")
             (check (some (lambda (record)
                            (minusp (getf record :capability-delta-micros)))
                          (getf decision-a :executor-capability-deltas)))
             (check (every (lambda (record)
                             (string= (%did actors :executor-1)
                                      (getf record :executor-did)))
                           (getf decision-a :executor-capability-deltas))
                    "one executor is evaluated independently per configuration")
             (check (= 2 (length (remove-duplicates
                                   (mapcar
                                    (lambda (record)
                                      (getf record :executor-config-sha256))
                                    (getf decision-a
                                          :executor-capability-deltas))
                                   :test #'string=)))
                    "executor configuration digest is part of the cohort key")
             (check (equal (getf decision-a :executor-capability-deltas)
                           (getf decision-b :executor-capability-deltas))
                    "executor/config cohort order is deterministic")
             (%close-test-store store-b))
           (%close-test-store store-a)))))))

;; ---------------------------- TEST-046 / activation coverage and grammar ---

(defun test-evolution-changed-component-activation-coverage ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline baseline-id candidate))
         (let* ((digest
                  (getf (%evo-call "READ-CANDIDATE-MANIFEST"
                                   store candidate-id)
                        :image-sha256))
                (prompt
                  (list :component "prompt/system" :kind :runtime-hit
                        :artifact-sha256 digest))
                (tools
                  (list :component "tools/weather" :kind :runtime-hit
                        :artifact-sha256 digest))
                (invalid-evidence
                  (list
                   (list tools prompt)
                   (list prompt prompt)
                   (list (list :component "prompt/system"
                               :kind :unknown-kind
                               :artifact-sha256 digest))
                   (list (append prompt (list :detail "extra"))))))
           (loop for evidence in invalid-evidence
                 for label in '("unsorted" "duplicate" "unknown-kind"
                                "extra-key")
                 for index from 1
                 for before = (length (%evo-call "READ-LEDGER" store))
                 do (check
                     (%signals-error-p
                      (lambda ()
                        (%record-evaluation
                         store actors candidate-id
                         (format nil "activation-invalid-~D" index)
                         "task-invalid" 800000
                         :campaign-id "activation-invalid"
                         :replicate-index index
                         :activation-evidence evidence)))
                     (format nil "~A activation evidence is rejected" label))
                    (check (= before
                              (length (%evo-call "READ-LEDGER" store)))
                           "invalid activation evidence has no ledger effect")))
         (%close-test-store store)))
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair (merge-pathnames "negative/" directory)
                                 actors)
         (declare (ignore store-path baseline candidate))
         (let* ((digest
                  (getf (%evo-call "READ-CANDIDATE-MANIFEST"
                                   store candidate-id)
                        :image-sha256))
                (prompt-hit
                  (list :component "prompt/system" :kind :runtime-hit
                        :artifact-sha256 digest))
                (tools-reachable
                  (list :component "tools/weather" :kind :reachable
                        :artifact-sha256 digest))
                (tools-wrong-digest
                  (list :component "tools/weather" :kind :runtime-hit
                        :artifact-sha256 +evolution-sha-a+)))
           (loop for index from 1 to 3
                 for executor = (if (oddp index) :executor-1 :executor-2)
                 for evaluator = (if (oddp index) :evaluator-1 :evaluator-2)
                 for evidence in (list (list prompt-hit tools-reachable)
                                       (list tools-wrong-digest)
                                       nil)
                 do (%record-paired-cell
                     store actors baseline-id candidate-id
                     (format nil "activation-negative-r~D" index)
                     index 500000 700000
                     :campaign-id "activation-negative"
                     :executor executor :evaluator evaluator
                     :baseline-options '(:activation-evidence nil)
                     :candidate-options
                     (list :activation-evidence evidence))))
         (let ((decision
                 (%make-decision store baseline-id candidate-id
                                 (%actor actors :authorizer)
                                 :campaign-id "activation-negative")))
           (check (not (getf (getf decision :gates)
                             :changed-components-activated))
                  "reachable and wrong-digest observations do not activate")
           (check (equal '(:changed-components-activated)
                         (getf decision :failed-gates))
                  "omitting one changed component isolates activation failure"))
         (%close-test-store store)))
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair (merge-pathnames "union/" directory) actors)
         (declare (ignore store-path baseline candidate))
         (let ((coverage (%runtime-activation-evidence store candidate-id)))
           (loop for index from 1 to 3
                 for executor = (if (oddp index) :executor-1 :executor-2)
                 for evaluator = (if (oddp index) :evaluator-1 :evaluator-2)
                 do (%record-paired-cell
                     store actors baseline-id candidate-id
                     (format nil "activation-union-r~D" index)
                     index 500000 700000
                     :campaign-id "activation-union"
                     :executor executor :evaluator evaluator
                     :baseline-options '(:activation-evidence nil)
                     :candidate-options
                     (list :activation-evidence
                           (if (= index 2) coverage nil)))))
         (let ((decision
                 (%make-decision store baseline-id candidate-id
                                 (%actor actors :authorizer)
                                 :campaign-id "activation-union")))
           (check (getf (getf decision :gates)
                        :changed-components-activated)
                  "candidate evidence union covers changed components")
           (check (getf decision :eligible-p)
                  "empty individual evidence lists do not fail union coverage"))
         (%close-test-store store))))))

;; ------------------------------- TEST-047 / complete-run attestation ---

(defun test-evolution-complete-run-attestation ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         (loop for index from 1 to 3
               for executor = (if (oddp index) :executor-1 :executor-2)
               for evaluator = (if (oddp index) :evaluator-1 :evaluator-2)
               do (%record-paired-cell
                   store actors baseline-id candidate-id
                   (format nil "complete-r~D" index)
                   index 500000 700000
                   :campaign-id "complete-run"
                   :executor executor :evaluator evaluator
                   :candidate-options
                   (list :run-complete-p (not (= index 2)))))
         (let ((decision
                 (%make-decision store baseline-id candidate-id
                                 (%actor actors :authorizer)
                                 :campaign-id "complete-run")))
           (check (getf (getf decision :gates)
                        :comparison-cells-match))
           (check (getf (getf decision :gates)
                        :replicate-capability-delta-met))
           (check (getf (getf decision :gates)
                        :per-executor-config-capability-delta-met))
           (check (getf (getf decision :gates)
                        :execution-token-increase-within-limit))
           (check (getf (getf decision :gates)
                        :runtime-cost-increase-within-limit))
           (check (not (getf (getf decision :gates) :runs-complete))
                  "one incomplete matched event fails the completion gate")
           (check (not (getf (getf decision :gates)
                             :minimum-held-out-repetitions-met))
                  "an incomplete protocol replicate does not count")
           (check (not (getf decision :eligible-p)))
           (let ((before (length (%evo-call "READ-LEDGER" store))))
             (check (%signals-error-p
                     (lambda ()
                       (%evo-call "PROMOTE-CANDIDATE!" store decision
                                  :pointer :canary
                                  :authorizer (%actor actors :authorizer))))
                    "an incomplete formal run cannot be promoted")
             (check (= before (length (%evo-call "READ-LEDGER" store)))
                    "rejected incomplete-run promotion has no ledger effect")
             (check (null (%evo-call "READ-POINTER" store :canary))
                    "rejected incomplete-run promotion cannot change pointer")))
         (%close-test-store store))))))

;; --------------------------- TEST-048/049 / authorizer role separation ---

(defun test-evolution-authorizer-roster-separation ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (dolist (case `(("executor-overlap/" ,(%did actors :executor-1))
                       ("evaluator-overlap/" ,(%did actors :evaluator-1))))
         (let ((path (merge-pathnames (first case) directory)))
           (check (%signals-error-p
                   (lambda ()
                     (%open-test-store
                      path actors :authorizer-dids (list (second case)))))
                  (format nil "authorizer overlap is rejected for ~A"
                          (first case)))
           (check (not (probe-file path))
                  "roster overlap is rejected before creating store files")))
       (let* ((path (merge-pathnames "disjoint/" directory))
              (store (%open-test-store path actors)))
         (check (probe-file path)
                "three pairwise-disjoint trust rosters are accepted")
         (%close-test-store store))))))

(defun test-evolution-creator-authorizer-separation ()
  (dolist (authorizer-key '(:creator :creator-2))
    (%call-with-evolution-directory
     (lambda (directory)
       (let* ((actors (%make-actors))
              (store
                (%open-test-store
                 (merge-pathnames "store/" directory) actors
                 :authorizer-dids (list (%did actors authorizer-key))))
              (baseline-image
                (%make-image directory "creator-baseline.core" #(49 1)))
              (candidate-image
                (%make-image directory "creator-candidate.core" #(49 2)))
              (baseline
                (%freeze store baseline-image (%actor actors :creator)))
              (candidate
                (%freeze store candidate-image (%actor actors :creator-2)))
              (baseline-id (%candidate-id baseline))
              (candidate-id (%candidate-id candidate)))
         (%record-comparison-matrix
          store actors baseline-id candidate-id
          :campaign-id "creator-authorizer"
          :prefix "creator-authorizer")
         (let ((decision
                 (%make-decision store baseline-id candidate-id
                                 (%actor actors authorizer-key)
                                 :campaign-id "creator-authorizer")))
           (check (getf (getf decision :gates)
                        :trusted-authorizer-signature))
           (check (not (getf (getf decision :gates)
                             :authorizer-creators-separated))
                  (format nil "authorizer ~S differs from neither own creation"
                          authorizer-key))
           (check (not (getf decision :eligible-p)))
           (let ((before (length (%evo-call "READ-LEDGER" store))))
             (check (%signals-error-p
                     (lambda ()
                       (%evo-call "PROMOTE-CANDIDATE!" store decision
                                  :pointer :canary
                                  :authorizer (%actor actors authorizer-key))))
                    "a compared creator cannot authorize promotion")
             (check (= before (length (%evo-call "READ-LEDGER" store)))
                    "creator-authorizer rejection has no ledger effect")
             (check (null (%evo-call "READ-POINTER" store :canary))
                    "creator-authorizer rejection cannot change pointer")))
         (%close-test-store store))))))

;; ---------------------------- TEST-050 / single evaluation-plan context ---

(defun test-evolution-single-evaluation-plan-context ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         ;; Every replicate has the same two-row protocol template.  The only
         ;; invalid context is that the template itself contains two plans.
         (loop for index from 1 to 3
               do (%record-paired-cell
                   store actors baseline-id candidate-id
                   (format nil "mixed-plan-r~D-a" index)
                   index 500000 700000
                   :campaign-id "mixed-plan"
                   :task-id "task-a"
                   :executor :executor-1 :evaluator :evaluator-1
                   :evaluation-plan-sha256 +evolution-sha-a+)
                  (%record-paired-cell
                   store actors baseline-id candidate-id
                   (format nil "mixed-plan-r~D-b" index)
                   index 500000 700000
                   :campaign-id "mixed-plan"
                   :task-id "task-b"
                   :executor :executor-2 :evaluator :evaluator-2
                   :evaluation-plan-sha256 +evolution-sha-b+))
         (let ((decision
                 (%make-decision store baseline-id candidate-id
                                 (%actor actors :authorizer)
                                 :campaign-id "mixed-plan")))
           (check (getf (getf decision :gates) :comparison-cells-match)
                  "both sides can have exact matched mixed-plan cells")
           (check (getf (getf decision :gates) :replicate-templates-match)
                  "identical multi-plan templates still match by replicate")
           (check (getf (getf decision :gates)
                        :minimum-held-out-repetitions-met)
                  "all three multi-plan protocol replicates are complete")
           (check (not (getf (getf decision :gates)
                             :single-evaluation-plan-context))
                  "a comparison cannot mix evaluation-plan digests")
           (check (equal '(:single-evaluation-plan-context)
                         (getf decision :failed-gates))
                  "the single-plan gate is the isolated failure")
           (check (not (getf decision :eligible-p))))
         (%close-test-store store))))))

;; -------------------------------- TEST-012, TEST-014, TEST-020 / metrics ---

(defun test-evolution-held-out-metrics-correctness-and-diagnostics ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         (%record-comparison-matrix
          store actors baseline-id candidate-id
          :candidate-correct '(t nil t)
          :candidate-scores '(900000 950000 990000))
         (let* ((events (%evo-call "READ-LEDGER" store))
                (sample (find "matrix-c1" events :key (lambda (event)
                                                       (getf event :run-id))
                              :test #'string=))
                (decision (%make-decision store baseline-id candidate-id
                                          (%actor actors :authorizer))))
           (check (eq :held-out (getf sample :split)))
           (check (= 900000 (getf sample :capability-score-micros)))
           (check (equal (%runtime-activation-evidence store candidate-id)
                         (getf sample :activation-evidence)))
           (check (= 100 (getf sample :duration-ms)))
           (check (= 20 (getf sample :input-tokens)))
           (check (= 10 (getf sample :output-tokens)))
           (check (= 30 (getf sample :estimated-cost-microusd)))
           (check (not (getf decision :eligible-p))
                  "higher capability cannot hide a correctness regression")
           (check (not (getf (getf decision :gates) :correctness-retained)))
           (check (member :correctness-retained
                          (getf decision :failed-gates))))
         (%close-test-store store))))))

(defun test-evolution-missing-gate-report ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (let* ((empty-store
                (%open-test-store (merge-pathnames "missing-candidates/"
                                                   directory)
                                  actors))
              (ledger-before
                (%read-string (%evo-call "LEDGER-PATH" empty-store)))
              (head-before
                (%read-string (%evo-call "LEDGER-HEAD-PATH" empty-store))))
         (check (%signals-error-p
                 (lambda ()
                   (%make-decision empty-store "baseline" "candidate"
                                   (%actor actors :authorizer))))
                "a decision requires both referenced frozen candidates")
         (check (string= ledger-before
                         (%read-string (%evo-call "LEDGER-PATH" empty-store))))
         (check (string= head-before
                         (%read-string
                          (%evo-call "LEDGER-HEAD-PATH" empty-store)))
                "missing-candidate rejection preserves ledger and head")
         (%close-test-store empty-store))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         (let* ((decision (%make-decision store baseline-id candidate-id
                                          (%actor actors :authorizer)))
                (failed (getf decision :failed-gates))
                (ledger-count (length (%evo-call "READ-LEDGER" store))))
           (check (not (getf decision :eligible-p)))
           (check (listp (getf decision :gates)))
           (dolist (gate '(:minimum-held-out-repetitions-met
                           :minimum-distinct-executors-met
                           :correctness-retained
                           :changed-components-activated
                           :runs-complete
                           :replicate-capability-delta-met
                           :per-executor-config-capability-delta-met))
             (check (member gate failed)
                    (format nil "missing evidence reports ~S" gate)))
           (check (%signals-error-p
                   (lambda ()
                     (%evo-call "PROMOTE-CANDIDATE!" store decision
                                :pointer :canary
                                :authorizer (%actor actors :authorizer))))
                  "an ineligible decision cannot change a pointer")
           (check (null (%evo-call "READ-POINTER" store :canary)))
           (check (= ledger-count (length (%evo-call "READ-LEDGER" store)))
                  "ineligible promotion appends no event"))
         (%close-test-store store))))))

;; ------------------------------- TEST-013, TEST-018, TEST-031 / decision ---

(defun test-evolution-repetition-and-executor-boundaries ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         (check (%signals-error-p
                 (lambda () (%make-decision store baseline-id candidate-id
                                             (%actor actors :authorizer)
                                             :minimum-repetitions 1)))
                "the repetition minimum cannot be less than two")
         (check (%signals-error-p
                 (lambda () (%make-decision store baseline-id candidate-id
                                             (%actor actors :authorizer)
                                             :minimum-executors 1)))
                "the executor minimum cannot be less than two")
         ;; Two repetitions all from one executor meet only one boundary.
         (dotimes (index 2)
           (%record-evaluation store actors baseline-id
                               (format nil "boundary-b~D" (1+ index))
                               "task-1" 500000
                               :replicate-index (1+ index)
                               :executor :executor-1 :evaluator :evaluator-1)
           (%record-evaluation store actors candidate-id
                               (format nil "boundary-c~D" (1+ index))
                               "task-1" 800000
                               :replicate-index (1+ index)
                               :executor :executor-1 :evaluator :evaluator-1))
         (let ((decision (%make-decision store baseline-id candidate-id
                                         (%actor actors :authorizer)
                                         :minimum-repetitions 2
                                         :minimum-executors 2)))
           (check (getf (getf decision :gates)
                        :minimum-held-out-repetitions-met))
           (check (not (getf (getf decision :gates)
                             :minimum-distinct-executors-met))))
         ;; One added event for each harness introduces the second executor.
         (%record-evaluation store actors baseline-id "boundary-b3" "task-1"
                             500000 :replicate-index 3
                             :executor :executor-2 :evaluator :evaluator-2)
         (%record-evaluation store actors candidate-id "boundary-c3" "task-1"
                             800000 :replicate-index 3
                             :executor :executor-2 :evaluator :evaluator-2)
         (let ((explicit-two (%make-decision store baseline-id candidate-id
                                             (%actor actors :authorizer)
                                             :minimum-repetitions 2
                                             :minimum-executors 2))
               (default-three (%make-decision store baseline-id candidate-id
                                              (%actor actors :authorizer))))
           (check (getf explicit-two :eligible-p))
           (check (getf default-three :eligible-p)
                  "the default three-run, two-executor matrix is eligible"))
         (%close-test-store store))))))

(defun %decision-comparable-fields (decision)
  (mapcar (lambda (key) (list key (getf decision key)))
          '(:gates :failed-gates :eligible-p
            :baseline-capability-mean-micros
            :candidate-capability-mean-micros
            :capability-delta-micros
            :replicate-capability-deltas
            :conservative-capability-delta-micros
            :executor-capability-deltas
            :baseline-execution-tokens-total
            :candidate-execution-tokens-total
            :baseline-execution-tokens-mean-per-event
            :candidate-execution-tokens-mean-per-event
            :execution-token-delta
            :baseline-runtime-cost-microusd-total
            :candidate-runtime-cost-microusd-total
            :baseline-runtime-cost-microusd-mean-per-event
            :candidate-runtime-cost-microusd-mean-per-event
            :runtime-cost-delta-microusd
            :development-cost-microusd)))

(defun test-evolution-decision-all-events-and-order-determinism ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors))
           (baseline-image (%make-image directory "order-b.core" #(11 11)))
           (candidate-image (%make-image directory "order-c.core" #(22 22))))
       (labels ((one-store (suffix order)
                  (let* ((path (merge-pathnames (format nil "~A/" suffix)
                                                directory))
                         (store (%open-test-store path actors))
                         (baseline (%freeze store baseline-image
                                            (%actor actors :creator)))
                         (candidate (%freeze store candidate-image
                                             (%actor actors :creator-2)))
                         (baseline-id (%candidate-id baseline))
                         (candidate-id (%candidate-id candidate)))
                    (%record-comparison-matrix
                     store actors baseline-id candidate-id
                     :candidate-scores '(700000 800000 900000)
                     :order order :prefix "order")
                    ;; This fourth valid event is below the threshold.  A
                    ;; selectable-subset implementation would incorrectly pass.
                    (%record-evaluation store actors candidate-id
                                        "order-c4" "task-1" 0
                                        :campaign-id "order"
                                        :replicate-index 4
                                        :executor :executor-2
                                        :evaluator :evaluator-1)
                    (%record-evaluation store actors baseline-id
                                        "order-b4" "task-1" 600000
                                        :campaign-id "order"
                                        :replicate-index 4
                                        :executor :executor-2
                                        :evaluator :evaluator-1)
                    (values store baseline-id candidate-id
                            (%make-decision store baseline-id candidate-id
                                            (%actor actors :authorizer)
                                            :campaign-id "order")))))
         (multiple-value-bind (store-a baseline-a candidate-a decision-a)
             (one-store "forward" :forward)
           (check (= 600000 (getf decision-a :baseline-capability-mean-micros)))
           (check (= 600000 (getf decision-a :candidate-capability-mean-micros))
                  "the decision consumes the low fourth run")
           (check (= 0 (getf decision-a :capability-delta-micros)))
           (check (= 120 (getf decision-a
                                :baseline-runtime-cost-microusd-total)))
           (check (= 120 (getf decision-a
                                :candidate-runtime-cost-microusd-total))
                  "separate cost totals include every held-out run")
           (check (= 1200 (getf decision-a :development-cost-microusd)))
           (check (not (getf decision-a :eligible-p)))
           (dolist (case '(("reverse" :reverse)
                           ("rotate-1" 1)
                           ("rotate-2" 2)
                           ("rotate-3" 3)
                           ("rotate-4" 4)))
             (multiple-value-bind (store-b baseline-b candidate-b decision-b)
                 (one-store (first case) (second case))
               (check (string= baseline-a baseline-b)
                      "shuffled stores use the identical baseline candidate")
               (check (string= candidate-a candidate-b)
                      "shuffled stores use the identical evolved candidate")
               (check (equal (%decision-comparable-fields decision-a)
                             (%decision-comparable-fields decision-b))
                      (format nil "order ~S cannot alter calculated results"
                              (second case)))
               (%close-test-store store-b)))
           (check (%signals-error-p
                   (lambda ()
                     (%evo-call "MAKE-DECISION!"
                                store-a baseline-a candidate-a
                                :campaign-id "order"
                                :run-ids '("order-c1")
                                :authorizer (%actor actors :authorizer))))
                  "callers cannot select an evidence subset")
           (check (and (%valid-sha256-p (getf decision-a :evidence-head))
                       (%valid-sha256-p (getf decision-a :event-hash)))
                  "the decision binds its evidence head and event hash")
           (%close-test-store store-a)))))))

(defun test-evolution-decision-form-coherence ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         (%record-comparison-matrix store actors baseline-id candidate-id)
         (let* ((decision (%make-decision store baseline-id candidate-id
                                          (%actor actors :authorizer)))
                (validate (%evo-function "%VALIDATE-DECISION-EVENT"))
                (validate-context
                  (%evo-function "%VALIDATE-DECISION-AGAINST-EVENTS"))
                (prior-events
                  (butlast (%evo-call "READ-LEDGER" store))))
           (check (funcall validate decision)
                  "the emitted decision satisfies its semantic schema")
           (check (funcall validate-context store decision prior-events)
                  "the emitted decision exactly matches its evidence prefix")
           (dolist (key
                     '(:baseline-capability-mean-micros
                       :candidate-capability-mean-micros
                       :capability-delta-micros
                       :replicate-capability-deltas
                       :conservative-capability-delta-micros
                       :executor-capability-deltas
                       :baseline-execution-tokens-total
                       :candidate-execution-tokens-total
                       :baseline-execution-tokens-mean-per-event
                       :candidate-execution-tokens-mean-per-event
                       :execution-token-delta
                       :baseline-runtime-cost-microusd-total
                       :candidate-runtime-cost-microusd-total
                       :baseline-runtime-cost-microusd-mean-per-event
                       :candidate-runtime-cost-microusd-mean-per-event
                       :runtime-cost-delta-microusd
                       :development-cost-microusd))
             (check (%signals-error-p
                     (lambda ()
                       (funcall validate (%plist-without decision key))))
                    (format nil "derived decision field ~S is mandatory" key)))
           (let ((gate-keys +evolution-decision-gate-keys+))
             (dolist (key gate-keys)
               (check (%signals-error-p
                       (lambda ()
                         (funcall
                          validate
                          (%plist-put
                           decision :gates
                           (%plist-without (getf decision :gates) key)))))
                      (format nil "gate field ~S is mandatory" key))
               (check (%signals-error-p
                       (lambda ()
                         (funcall
                          validate
                          (%plist-put
                           decision :gates
                           (%plist-put (getf decision :gates) key :invalid)))))
                      (format nil "gate field ~S is exactly Boolean" key))))
           (dolist (key '(:baseline-execution-tokens-mean-per-event
                          :candidate-execution-tokens-mean-per-event
                          :baseline-runtime-cost-microusd-mean-per-event
                          :candidate-runtime-cost-microusd-mean-per-event
                          :development-cost-microusd))
             (let ((altered
                     (%resign-decision-for-validation
                      (%plist-put decision key (1+ (getf decision key)))
                      (%actor actors :authorizer))))
               (check (%signals-error-p
                       (lambda ()
                         (funcall validate-context store altered prior-events)))
                      (format nil "derived value ~S is evidence-exact" key))))
           (let ((altered
                   (%resign-decision-for-validation
                    (%plist-put
                     (%plist-put decision
                                 :baseline-capability-mean-micros
                                 (1+ (getf decision
                                          :baseline-capability-mean-micros)))
                     :candidate-capability-mean-micros
                     (1+ (getf decision
                              :candidate-capability-mean-micros)))
                    (%actor actors :authorizer))))
             (check (%signals-error-p
                     (lambda ()
                       (funcall validate-context store altered prior-events)))
                    "aggregate capability means are evidence-exact"))
           (dolist (case
                     '((:baseline-execution-tokens-total
                        :candidate-execution-tokens-total)
                       (:baseline-runtime-cost-microusd-total
                        :candidate-runtime-cost-microusd-total)))
             (let ((altered (copy-list decision)))
               (dolist (key case)
                 (setf (getf altered key) (1+ (getf altered key))))
               (setf altered
                     (%resign-decision-for-validation
                      altered (%actor actors :authorizer)))
               (check (%signals-error-p
                       (lambda ()
                         (funcall validate-context store altered prior-events)))
                      (format nil "separate totals ~S are evidence-exact" case))))
           (let* ((records (getf decision :replicate-capability-deltas))
                  (record (copy-list (first records))))
             (incf (getf record :baseline-capability-mean-micros))
             (incf (getf record :candidate-capability-mean-micros))
             (let ((altered
                     (%resign-decision-for-validation
                      (%plist-put decision :replicate-capability-deltas
                                  (cons record (rest records)))
                      (%actor actors :authorizer))))
               (check (%signals-error-p
                       (lambda ()
                         (funcall validate-context store altered prior-events)))
                      "replicate means are exact evidence-derived values")))
           (let* ((records (getf decision :executor-capability-deltas))
                  (record (copy-list (first records))))
             (incf (getf record :baseline-capability-mean-micros))
             (incf (getf record :candidate-capability-mean-micros))
             (let ((altered
                     (%resign-decision-for-validation
                      (%plist-put decision :executor-capability-deltas
                                  (cons record (rest records)))
                      (%actor actors :authorizer))))
               (check (%signals-error-p
                       (lambda ()
                         (funcall validate-context store altered prior-events)))
                      "executor/config means are exact evidence-derived values")))
           (dolist (key +evolution-decision-gate-keys+)
             (let* ((gates (%plist-put (getf decision :gates) key nil))
                    (altered
                      (%resign-decision-for-validation
                       (%plist-put
                        (%plist-put
                         (%plist-put decision :gates gates)
                         :failed-gates (list key))
                        :eligible-p nil)
                       (%actor actors :authorizer))))
               (check (%signals-error-p
                       (lambda ()
                         (funcall validate-context store altered prior-events)))
                      (format nil "gate ~S is evidence-derived" key))))
           (check (%signals-error-p
                   (lambda ()
                     (funcall validate
                              (%plist-put decision :capability-delta-micros
                                          (1+ (getf decision
                                                   :capability-delta-micros))))))
                  "the aggregate capability delta is derived")
           (let* ((records (getf decision :replicate-capability-deltas))
                  (record (%plist-put
                           (first records) :capability-delta-micros
                           (1+ (getf (first records)
                                    :capability-delta-micros)))))
             (check (%signals-error-p
                     (lambda ()
                       (funcall
                        validate
                        (%plist-put decision :replicate-capability-deltas
                                    (cons record (rest records))))))
                    "every per-replicate delta is derived"))
           (check (%signals-error-p
                   (lambda ()
                     (funcall
                      validate
                      (%plist-put decision :replicate-capability-deltas
                                  (reverse
                                   (getf decision
                                         :replicate-capability-deltas))))))
                  "replicate delta records are deterministically sorted")
           (check (%signals-error-p
                   (lambda ()
                     (funcall
                      validate
                      (%plist-put
                       decision :conservative-capability-delta-micros
                       (1+ (getf decision
                                :conservative-capability-delta-micros))))))
                  "the conservative delta is the minimum replicate delta")
           (let* ((records (getf decision :executor-capability-deltas))
                  (record (%plist-put
                           (first records) :capability-delta-micros
                           (1+ (getf (first records)
                                    :capability-delta-micros)))))
             (check (%signals-error-p
                     (lambda ()
                       (funcall
                        validate
                        (%plist-put decision :executor-capability-deltas
                                    (cons record (rest records))))))
                    "every executor/config delta is derived"))
           (check (%signals-error-p
                   (lambda ()
                     (funcall
                      validate
                      (%plist-put decision :executor-capability-deltas
                                  (reverse
                                   (getf decision
                                         :executor-capability-deltas))))))
                  "executor/config delta records are deterministically sorted")
           (check (%signals-error-p
                   (lambda ()
                     (funcall validate
                              (%plist-put decision :execution-token-delta
                                          (1+ (getf decision
                                                   :execution-token-delta))))))
                  "the execution-token delta is derived from separate totals")
           (check (%signals-error-p
                   (lambda ()
                     (funcall
                      validate
                      (%plist-put decision :runtime-cost-delta-microusd
                                  (1+ (getf decision
                                           :runtime-cost-delta-microusd))))))
                  "the runtime-cost delta is derived from separate totals")
           (dolist (key '(:replicate-capability-delta-met
                          :per-executor-config-capability-delta-met
                          :execution-token-increase-within-limit
                          :runtime-cost-increase-within-limit))
             (let* ((gates (%plist-put (getf decision :gates) key nil))
                    (altered
                      (%plist-put
                       (%plist-put
                        (%plist-put decision :gates gates)
                        :failed-gates (list key))
                       :eligible-p nil)))
               (check (%signals-error-p
                       (lambda () (funcall validate altered)))
                      (format nil "derived gate ~S follows report values" key))))
           (check (%signals-error-p
                   (lambda ()
                     (funcall validate
                              (%plist-put decision :evidence-head
                                          +evolution-sha-a+))))
                  "evidence-head must equal previous-hash")
           (check (%signals-error-p
                   (lambda ()
                     (funcall validate
                              (%plist-put decision :failed-gates
                                          '(:replicate-capability-delta-met)))))
                  "failed gates must exactly correspond to false gate values")
           (check (%signals-error-p
                   (lambda ()
                     (funcall validate
                              (%plist-put decision :eligible-p nil))))
                  "eligibility is true exactly when no gate failed"))
         (%close-test-store store))))))

(defun test-evolution-persisted-decision-context-rederivation ()
  "TEST-053: persisted decisions are re-derived from their evidence prefix."
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         (%record-comparison-matrix store actors baseline-id candidate-id)
         (let* ((decision (%make-decision store baseline-id candidate-id
                                          (%actor actors :authorizer)))
                (events (%evo-call "READ-LEDGER" store))
                (altered
                  (%plist-put
                   decision :development-cost-microusd
                   (1+ (getf decision :development-cost-microusd))))
                (resigned
                  (%resign-decision-for-validation
                   altered (%actor actors :authorizer)))
                (without-hash (%plist-without resigned :event-hash))
                (forged
                  (append
                   without-hash
                   (list :event-hash
                         (funcall (%evo-function "%SHA256-VALUE")
                                  without-hash))))
                (forged-events (append (butlast events) (list forged)))
                (ledger-path (%evo-call "LEDGER-PATH" store)))
           ;; Model a persisted record whose actor and terminal-head signatures
           ;; are valid but whose report is inconsistent with signed run data.
           ;; The store's reader must still reject it before promotion.
           (%write-string
            ledger-path
            (with-output-to-string (stream)
              (dolist (event forged-events)
                (write-string
                 (funcall (%evo-function "%PERSISTED-FORM-STRING")
                          event "Persisted decision Red Gate")
                 stream)
                (terpri stream))))
           (funcall (%evo-function "%WRITE-HEAD")
                    store (length forged-events) (getf forged :event-hash))
           (check (%signals-error-p
                   (lambda () (%evo-call "READ-LEDGER" store)))
                  "ledger read re-derives a decision from its evidence prefix")
           (check (%signals-error-p
                   (lambda ()
                     (%evo-call "PROMOTE-CANDIDATE!" store forged
                                :pointer :canary
                                :authorizer (%actor actors :authorizer))))
                  "promotion rejects an evidence-inconsistent persisted decision")
           (check (null (probe-file (%evo-call "POINTER-PATH" store :canary)))
                  "rejected persisted decision cannot create a pointer"))
         (%close-test-store store))))))

;; ----------------------------- TEST-015, TEST-016, TEST-028, TEST-029 ---

(defun %promote-with-pointer-observer (store decision old-id new-id authorizer)
  "Promote once while a raw concurrent reader observes the pointer file."
  (let ((observed (list old-id))
        (done nil)
        (lock (sb-thread:make-mutex :name "evolution-pointer-observer"))
        (started (sb-thread:make-semaphore :count 0)))
    (let ((observer
            (sb-thread:make-thread
             (lambda ()
               (sb-thread:signal-semaphore started)
               (loop
                 (sb-thread:with-mutex (lock)
                   (when done (return)))
                 (let ((value
                         (handler-case
                             (let ((form
                                     (%evo-call "%READ-POINTER-FORM"
                                                store :canary)))
                               (and form (getf form :candidate-id)))
                           (error () :partial-read-error))))
                   (sb-thread:with-mutex (lock)
                     (push value observed)))
                 (sb-thread:thread-yield)))
             :name "evolution-pointer-observer")))
      (sb-thread:wait-on-semaphore started)
      (%evo-call "PROMOTE-CANDIDATE!" store decision
                 :pointer :canary :authorizer authorizer)
      (sb-thread:with-mutex (lock) (setf done t))
      (sb-thread:join-thread observer)
      (push (%evo-call "READ-POINTER" store :canary) observed)
      (check (every (lambda (value)
                      (and (stringp value)
                           (or (string= old-id value)
                               (string= new-id value))))
                    observed)
             "concurrent readers see only complete old or new values")
      observed)))

(defun test-evolution-trusted-promotion-pointers-and-rollback ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         (%record-comparison-matrix store actors baseline-id candidate-id)
         (let ((decision (%make-decision store baseline-id candidate-id
                                         (%actor actors :authorizer)))
               (candidate-image-before
                 (%read-octets
                  (%evo-call "CANDIDATE-IMAGE-PATH" store candidate-id))))
           (check (getf decision :eligible-p))
           (check (%valid-signature-hex-p
                   (getf decision :authorization-signature)))
           (let ((ledger-before (length (%evo-call "READ-LEDGER" store))))
             (check (%signals-error-p
                     (lambda ()
                       (%evo-call "PROMOTE-CANDIDATE!" store decision
                                  :pointer :canary
                                  :authorizer (%actor actors :outsider))))
                    "an untrusted signer cannot promote")
             (check (null (%evo-call "READ-POINTER" store :canary)))
             (check (= ledger-before (length (%evo-call "READ-LEDGER" store)))))
           (let ((*current-agent*
                   (make-instance 'agent :id 'candidate-context
                                         :capability "candidate")))
             (check (%signals-error-p
                     (lambda ()
                       (%evo-call "PROMOTE-CANDIDATE!" store decision
                                  :pointer :canary
                                  :authorizer (%actor actors :authorizer))))
                    "candidate context cannot promote itself"))
           (check (null (%evo-call "READ-POINTER" store :canary)))
           (check (%signals-error-p
                   (lambda ()
                     (%evo-call "PROMOTE-CANDIDATE!" store decision
                                :pointer :production
                                :authorizer (%actor actors :authorizer))))
                  "only canary and active pointer names are supported")
           (%evo-call "PROMOTE-CANDIDATE!" store decision
                      :pointer :canary :authorizer (%actor actors :authorizer))
           (check (string= candidate-id
                           (%evo-call "READ-POINTER" store :canary)))
           (let* ((no-op-decision
                    (%make-decision store baseline-id candidate-id
                                    (%actor actors :authorizer)))
                  (ledger-count (length (%evo-call "READ-LEDGER" store))))
             (check (%signals-error-p
                     (lambda ()
                       (%evo-call "PROMOTE-CANDIDATE!" store no-op-decision
                                  :pointer :canary
                                  :authorizer (%actor actors :authorizer))))
                    "a promotion must change the selected candidate")
             (check (= ledger-count (length (%evo-call "READ-LEDGER" store))))
             (check (string= candidate-id
                             (%evo-call "READ-POINTER" store :canary))))
           (check (equalp candidate-image-before
                          (%read-octets
                           (%evo-call "CANDIDATE-IMAGE-PATH" store candidate-id)))
                  "promotion cannot mutate candidate bytes"))
         ;; A new current decision permits an independent ACTIVE pointer.
         (let ((active-decision (%make-decision store baseline-id candidate-id
                                                (%actor actors :authorizer))))
           (%evo-call "PROMOTE-CANDIDATE!" store active-decision
                      :pointer :active :authorizer (%actor actors :authorizer)))
         (check (string= candidate-id (%evo-call "READ-POINTER" store :active)))
         ;; Freeze and qualify another candidate, then move only CANARY.
         (let* ((next-image (%make-image directory "next.core" #(30 31 32)))
                (next-manifest (%freeze store next-image (%actor actors :creator-2)))
                (next-id (%candidate-id next-manifest))
                (next-image-before
                  (%read-octets
                   (%evo-call "CANDIDATE-IMAGE-PATH" store next-id))))
           (%record-comparison-matrix store actors baseline-id next-id
                                      :prefix "next")
           (let ((next-decision (%make-decision store baseline-id next-id
                                                (%actor actors :authorizer)
                                                :campaign-id "next")))
             (%promote-with-pointer-observer
              store next-decision candidate-id next-id
              (%actor actors :authorizer)))
           (check (string= next-id (%evo-call "READ-POINTER" store :canary)))
           (check (string= candidate-id (%evo-call "READ-POINTER" store :active))
                  "canary promotion leaves active unchanged")
           (%evo-call "ROLLBACK-POINTER!" store :canary
                      :authorizer (%actor actors :authorizer))
           (check (string= candidate-id (%evo-call "READ-POINTER" store :canary))
                  "rollback restores the recorded prior candidate")
           (check (string= candidate-id (%evo-call "READ-POINTER" store :active)))
           (check (equalp next-image-before
                          (%read-octets
                           (%evo-call "CANDIDATE-IMAGE-PATH" store next-id)))
                  "pointer updates leave the second candidate unchanged")
           ;; A deterministic partial-file fixture verifies that the reader
           ;; never turns an incomplete value into an observed candidate.
           (let* ((pointer-path (%evo-call "POINTER-PATH" store :canary))
                  (pointer-form (%read-string pointer-path)))
             (unwind-protect
                  (progn
                    (%write-string pointer-path "(:candidate-id \"partial")
                    (check (%signals-error-p
                            (lambda () (%evo-call "READ-POINTER"
                                                 store :canary)))
                           "an incomplete pointer form is never observed"))
               (%write-string pointer-path pointer-form)))
           (check (string= candidate-id (%evo-call "READ-POINTER" store :canary)))
           (let ((events (%evo-call "READ-LEDGER" store)))
             (check (= 3 (length (%events-of-kind events :promotion))))
             (check (= 1 (length (%events-of-kind events :rollback)))))
           ;; TEST-061: a previously valid authorizer signature is scoped to
           ;; its exact evidence head and cannot authorize a later transition.
           (let* ((old-rollback
                    (%event-of-kind (%evo-call "READ-LEDGER" store) :rollback))
                  (fresh (%make-decision store baseline-id next-id
                                         (%actor actors :authorizer)
                                         :campaign-id "next")))
             (%evo-call "PROMOTE-CANDIDATE!" store fresh
                        :pointer :canary
                        :authorizer (%actor actors :authorizer))
             (let* ((events-before (%evo-call "READ-LEDGER" store))
                    (replay-payload
                      (%plist-without-keys
                       old-rollback '(:seq :previous-hash :event-hash))))
               (check (%signals-error-p
                       (lambda ()
                         (funcall (%evo-function "%APPEND-EVENT-UNLOCKED")
                                  store replay-payload events-before)))
                      "old rollback authorization cannot be replayed at a new head")
               (check (= (length events-before)
                         (length (%evo-call "READ-LEDGER" store))))
               (check (string= next-id
                               (%evo-call "READ-POINTER" store :canary))))))
         (%close-test-store store))))))

;; ------------------------------------- TEST-017, TEST-034 / stale/tamper ---

(defun test-evolution-signed-manifest-substitution-rejected ()
  "TEST-034: a valid manifest for another frozen ID cannot rewrite history."
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         (%record-comparison-matrix store actors baseline-id candidate-id)
         (%make-decision store baseline-id candidate-id
                         (%actor actors :authorizer))
         (let* ((arguments
                  (%base-freeze-arguments (%actor actors :creator)))
                (source (%evo-call "CANDIDATE-IMAGE-PATH" store candidate-id)))
           (setf (getf arguments :created-at) "2026-09-05T00:00:00Z"
                 (getf arguments :theory-fingerprint) +evolution-sha-c+)
           (let* ((alternate
                    (%freeze store source (%actor actors :creator)
                             :arguments arguments))
                  (alternate-id (%candidate-id alternate))
                  (target-path
                    (%evo-call "CANDIDATE-MANIFEST-PATH" store candidate-id))
                  (original (%read-string target-path)))
             (check (not (string= candidate-id alternate-id)))
             (unwind-protect
                  (progn
                    (%write-form target-path alternate)
                    (check (not (%evo-call "VERIFY-LEDGER" store))
                           "another valid signed manifest cannot satisfy this ID")
                    (check (%signals-error-p
                            (lambda () (%evo-call "READ-LEDGER" store)))
                           "historical replay anchors manifests to freeze evidence"))
               (%write-string target-path original))
             (check (%evo-call "VERIFY-LEDGER" store)
                    "restoring the anchored manifest restores verification")))
         (%close-test-store store))))))

(defun test-evolution-freeze-manifest-anchoring ()
  "TEST-034: every freeze retains its exact signed manifest during replay."
  (%call-with-evolution-directory
   (lambda (directory)
     (let* ((actors (%make-actors))
            (store (%open-test-store (merge-pathnames "store/" directory)
                                     actors))
            (image (%make-image directory "freeze-anchor.core" #(3 4 5)))
            (manifest (%freeze store image (%actor actors :creator)))
            (candidate-id (%candidate-id manifest))
            (manifest-path
              (%evo-call "CANDIDATE-MANIFEST-PATH" store candidate-id))
            (manifest-before (%read-string manifest-path)))
       (delete-file manifest-path)
       (check (not (%evo-call "VERIFY-LEDGER" store))
              "a lone freeze cannot survive manifest deletion")
       (check (%signals-error-p
               (lambda () (%evo-call "READ-LEDGER" store))))
       (%write-string manifest-path manifest-before)
       (check (%evo-call "VERIFY-LEDGER" store))
       (%write-string manifest-path "nil\n")
       (check (not (%evo-call "VERIFY-LEDGER" store))
              "a lone freeze cannot survive manifest corruption")
       (%write-string manifest-path manifest-before)
       (%record-evaluation store actors candidate-id
                           "feedback-anchor" "feedback-task" 500000
                           :campaign-id "feedback-anchor"
                           :split :feedback)
       (delete-file manifest-path)
       (check (not (%evo-call "VERIFY-LEDGER" store))
              "feedback-only history still requires its frozen manifest")
       (check (%signals-error-p
               (lambda () (%evo-call "READ-LEDGER" store))))
       (%write-string manifest-path manifest-before)
       (check (%evo-call "VERIFY-LEDGER" store)
              "restoring the exact frozen manifest restores replay")
       (%close-test-store store)))))

(defun test-evolution-stale-decision-and-image-tamper ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         (%record-comparison-matrix store actors baseline-id candidate-id)
         (let ((decision (%make-decision store baseline-id candidate-id
                                         (%actor actors :authorizer))))
           (%record-evaluation store actors baseline-id "late-run-b" "task-1"
                               600000 :replicate-index 4
                               :executor :executor-2 :evaluator :evaluator-1)
           (%record-evaluation store actors candidate-id "late-run-c" "task-1"
                               900000 :replicate-index 4
                               :executor :executor-2 :evaluator :evaluator-1)
           (check (%signals-error-p
                   (lambda ()
                     (%evo-call "PROMOTE-CANDIDATE!" store decision
                                :pointer :canary
                                :authorizer (%actor actors :authorizer))))
                  "new evidence makes the prior decision stale")
           (check (null (%evo-call "READ-POINTER" store :canary))))
         (let* ((image-path (%evo-call "CANDIDATE-IMAGE-PATH" store candidate-id))
                (image-before (%read-octets image-path)))
           (setf (aref image-before 0) (logxor #xff (aref image-before 0)))
           (%write-octets image-path image-before)
           (check (%rejected-p
                   (lambda () (%evo-call "VERIFY-CANDIDATE" store candidate-id)))
                  "one changed image byte invalidates the candidate")
           (let* ((invalid-decision
                    (%make-decision store baseline-id candidate-id
                                    (%actor actors :authorizer)))
                  (ledger-count (length (%evo-call "READ-LEDGER" store))))
             (check (not (getf (getf invalid-decision :gates)
                               :candidate-digest-valid)))
             (check (= 1200
                       (getf invalid-decision :development-cost-microusd))
                    "image invalidity does not erase signed development cost")
             (check (%signals-error-p
                     (lambda ()
                       (%evo-call "PROMOTE-CANDIDATE!" store invalid-decision
                                  :pointer :canary
                                  :authorizer (%actor actors :authorizer))))
                    "a mutated candidate cannot be promoted")
             (check (null (%evo-call "READ-POINTER" store :canary)))
             (check (= ledger-count (length (%evo-call "READ-LEDGER" store)))
                    "failed promotion appends no event")))
         (%close-test-store store))))))

(defun test-evolution-rollback-recovers-from-current-image-tamper ()
  "TEST-058: rollback can escape a corrupt current candidate."
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         (%record-comparison-matrix store actors baseline-id candidate-id)
         (let ((decision (%make-decision store baseline-id candidate-id
                                         (%actor actors :authorizer))))
           (%evo-call "PROMOTE-CANDIDATE!" store decision
                      :pointer :canary
                      :authorizer (%actor actors :authorizer)))
         ;; Move the pointer again so the corrupt current candidate has a
         ;; signed predecessor that rollback can restore.
         (let* ((next-image
                  (%make-image directory "rollback-next.core" #(41 42 43)))
                (next-manifest
                  (%freeze store next-image (%actor actors :creator-2)))
                (next-id (%candidate-id next-manifest)))
           (%record-comparison-matrix store actors baseline-id next-id
                                      :prefix "rollback-next")
           (let ((next-decision
                   (%make-decision store baseline-id next-id
                                   (%actor actors :authorizer)
                                   :campaign-id "rollback-next")))
             (%evo-call "PROMOTE-CANDIDATE!" store next-decision
                        :pointer :canary
                        :authorizer (%actor actors :authorizer)))
           (let* ((image-path (%evo-call "CANDIDATE-IMAGE-PATH" store next-id))
                  (tampered (%read-octets image-path)))
             (setf (aref tampered 0) (logxor #xff (aref tampered 0)))
             (%write-octets image-path tampered))
           (check (listp (%evo-call "READ-LEDGER" store))
                  "historical evidence remains readable after image tamper")
           (let ((rollback
                   (handler-case
                       (%evo-call "ROLLBACK-POINTER!" store :canary
                                  :authorizer (%actor actors :authorizer))
                     (error () nil))))
             (check rollback
                    "rollback accepts a corrupt current candidate")
             (check (and rollback (eq :rollback (getf rollback :event)))))
           (check (string= candidate-id
                           (%evo-call "READ-POINTER" store :canary))
                  "rollback restores the verified prior candidate"))
         (%close-test-store store))))))

(defun test-evolution-rollback-descendant-prior-of-corrupt-current ()
  "TEST-058: current image exemption follows identity through prior lineage."
  (%call-with-evolution-directory
   (lambda (directory)
     (let* ((actors (%make-actors))
            (store (%open-test-store (merge-pathnames "store/" directory)
                                     actors))
            (root-image (%make-image directory "ancestor.core" #(51 52 53)))
            (root (%freeze store root-image (%actor actors :creator)))
            (root-id (%candidate-id root))
            (child-image (%make-image directory "descendant.core" #(61 62 63)))
            (child
              (%freeze store child-image (%actor actors :creator-2)
                       :parent-id root-id
                       :parent-image-sha256 (getf root :image-sha256)))
            (child-id (%candidate-id child)))
       (%record-comparison-matrix store actors root-id child-id
                                  :prefix "descendant-child")
       (%evo-call "PROMOTE-CANDIDATE!"
                  store
                  (%make-decision store root-id child-id
                                  (%actor actors :authorizer)
                                  :campaign-id "descendant-child")
                  :pointer :canary
                  :authorizer (%actor actors :authorizer))
       (%record-comparison-matrix store actors child-id root-id
                                  :prefix "descendant-root")
       (%evo-call "PROMOTE-CANDIDATE!"
                  store
                  (%make-decision store child-id root-id
                                  (%actor actors :authorizer)
                                  :campaign-id "descendant-root")
                  :pointer :canary
                  :authorizer (%actor actors :authorizer))
       (check (string= root-id (%evo-call "READ-POINTER" store :canary)))
       (let* ((root-path (%evo-call "CANDIDATE-IMAGE-PATH" store root-id))
              (tampered (%read-octets root-path)))
         (setf (aref tampered 0) (logxor #xff (aref tampered 0)))
         (%write-octets root-path tampered))
       (check (%evo-call "ROLLBACK-POINTER!" store :canary
                         :authorizer (%actor actors :authorizer))
              "rollback exempts the corrupt current image in prior lineage")
       (check (string= child-id (%evo-call "READ-POINTER" store :canary))
              "rollback restores the verified descendant prior candidate")
       (%close-test-store store)))))

(defun test-evolution-pointer-deletion-fails-closed ()
  "TEST-059: deletion cannot downgrade a signed pointer to never-promoted."
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore store-path baseline candidate))
         (%record-comparison-matrix store actors baseline-id candidate-id)
         (let* ((decision (%make-decision store baseline-id candidate-id
                                          (%actor actors :authorizer))))
           (%evo-call "PROMOTE-CANDIDATE!" store decision
                      :pointer :canary
                      :authorizer (%actor actors :authorizer))
           (let ((fresh (%make-decision store baseline-id candidate-id
                                        (%actor actors :authorizer)))
                 (pointer-path (%evo-call "POINTER-PATH" store :canary))
                 (ledger-path (%evo-call "LEDGER-PATH" store))
                 (head-path (%evo-call "LEDGER-HEAD-PATH" store)))
             (delete-file pointer-path)
             (let ((ledger-before (%read-string ledger-path))
                   (head-before (%read-string head-path)))
               (check (%signals-error-p
                       (lambda () (%evo-call "READ-POINTER" store :canary)))
                      "missing pointer contradicts signed pointer evidence")
               (check (%signals-error-p
                       (lambda ()
                         (%evo-call "PROMOTE-CANDIDATE!" store fresh
                                    :pointer :canary
                                    :authorizer (%actor actors :authorizer))))
                      "a later promotion cannot erase missing-pointer lineage")
               (check (string= ledger-before (%read-string ledger-path)))
               (check (string= head-before (%read-string head-path)))
               (check (null (probe-file pointer-path))))))
         (%close-test-store store))))))

(defun test-evolution-closed-parser-properties ()
  "TEST-063: generated grammar values round-trip; arbitrary text is inert."
  (let* ((parse (%evo-function "%READ-ONE-FORM-STRING"))
         (serialize (%evo-function "%CANONICAL-STRING"))
         (keywords (append +evolution-decision-gate-keys+
                           '(:event :evaluation :held-out :candidate-id
                             :run-id :campaign-id :active :canary)))
         (state #x5eed1234)
         (valid-roundtrips-p t)
         (fuzz-closure-p t)
         (tools-before (sort (mapcar #'symbol-name (list-tools)) #'string<))
         (packages-before (%package-registry-snapshot)))
    ;; A canonical list with 4,095 253-octet strings and one 252-octet string
    ;; is exactly 1 MiB including quotes, separators, and parentheses.  This
    ;; distinguishes the contract's octet ceiling from a character ceiling.
    (let* ((wide-prefix (make-string 126 :initial-element #\é))
           (wide-253 (concatenate 'string wide-prefix "x"))
           (exact-value (append (make-list 4095 :initial-element wide-253)
                                (list wide-prefix)))
           (exact-text (funcall serialize exact-value))
           (exact-octets (sb-ext:string-to-octets
                          exact-text :external-format :utf-8)))
      (check (= (* 1024 1024) (length exact-octets))
             "multibyte parser fixture is exactly the 1 MiB octet ceiling")
      (check (equalp exact-octets
                     (%evo-call "CANONICAL-BYTES" exact-value))
             "the encoder accepts the exact 1 MiB UTF-8 boundary")
      (check (equal exact-value (funcall parse exact-text "exact octet bound"))
             "the exact UTF-8 octet boundary is accepted")
      (check (= 1 (length (%evo-call "%COMPLETE-LEDGER-LINES"
                                     (concatenate 'string exact-text
                                                  (string #\Newline)))))
             "a ledger line at the exact UTF-8 octet boundary is accepted")
      (let ((oversized (concatenate 'string exact-text " ")))
        (check (%signals-error-p
                (lambda () (funcall parse oversized "oversized octet bound")))
               "one UTF-8 octet beyond the form ceiling is rejected")
        (check (%signals-error-p
                (lambda ()
                  (%evo-call "%COMPLETE-LEDGER-LINES"
                             (concatenate 'string oversized
                                          (string #\Newline)))))
               "one UTF-8 octet beyond the ledger-line ceiling is rejected")
        (check (%signals-error-p
                (lambda ()
                  (%evo-call "CANONICAL-BYTES"
                             (append (butlast exact-value)
                                     (list wide-253)))))
               "the encoder rejects one UTF-8 octet beyond its form ceiling")))
    (labels ((next (limit)
               (setf state (mod (+ (* state 1103515245) 12345) #x80000000))
               (mod state limit))
             (atom-value ()
               (case (next 5)
                 (0 nil)
                 (1 t)
                 (2 (- (next 1000000) 500000))
                 (3 (nth (next (length keywords)) keywords))
                 (otherwise
                  (let* ((alphabet "abcXYZ 019-_\\\"")
                         (value (make-string (next 48))))
                    (dotimes (index (length value) value)
                      (setf (char value index)
                            (char alphabet (next (length alphabet)))))))))
             (value (depth)
               (if (or (zerop depth) (< (next 4) 3))
                   (atom-value)
                   (loop repeat (next 7) collect (value (1- depth)))))
             (try-parse (text)
               (handler-case (values (funcall parse text "parser property") t)
                 (error () (values nil nil)))))
      (loop repeat 1000 do
        (let* ((original (value 4))
               (text (funcall serialize original)))
          (multiple-value-bind (parsed accepted-p) (try-parse text)
            (unless (and accepted-p (equal original parsed))
              (setf valid-roundtrips-p nil)))))
      (let ((alphabet
              (coerce (append (coerce "()[]{}:#.;'\\\"-+ nilt012abcXYZ \t\n" 'list)
                              (list (code-char #x85)))
                      'string)))
        (loop repeat 1000 do
          (let ((text (make-string (next 160))))
            (dotimes (offset (length text))
              (setf (char text offset)
                    (char alphabet (next (length alphabet)))))
            (multiple-value-bind (parsed accepted-p) (try-parse text)
              (when accepted-p
                (multiple-value-bind (reparsed canonical-p)
                    (try-parse (funcall serialize parsed))
                  (unless (and canonical-p (equal parsed reparsed))
                    (setf fuzz-closure-p nil))))))))
    (check valid-roundtrips-p
           "1,000 generated grammar values satisfy parse(serialize(v)) = v")
    (check fuzz-closure-p
           "1,000 arbitrary inputs either reject or canonicalize idempotently")
    (check (equal tools-before
                  (sort (mapcar #'symbol-name (list-tools)) #'string<))
           "parser properties cause no tool-registry effects")
    (check (equal packages-before (%package-registry-snapshot))
           "parser properties intern no packages or symbols"))))

;; --------------------------------------- TEST-021, TEST-030 / readers ---

(defun test-evolution-reader-and-path-attack-corpus ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let* ((actors (%make-actors))
            (store (%open-test-store (merge-pathnames "store/" directory) actors))
            (image (%make-image directory "reader.core" #(7 8 9)))
            (manifest (%freeze store image (%actor actors :creator)))
            (candidate-id (%candidate-id manifest))
            (manifest-path (%evo-call "CANDIDATE-MANIFEST-PATH" store candidate-id))
            (manifest-before (%read-string manifest-path))
            (ledger-before (%read-string (%evo-call "LEDGER-PATH" store)))
            (tools-before (sort (mapcar #'symbol-name (list-tools)) #'string<))
            (registry-before (%package-registry-snapshot)))
       (setf *evolution-reader-attack-fired* nil)
       (%write-string manifest-path
                      (format nil
                              "#.(setf anuna-imago.test::*evolution-reader-attack-fired* t)~%"))
       (check (%signals-error-p
               (lambda () (%evo-call "READ-CANDIDATE-MANIFEST"
                                     store candidate-id))))
       (check (null *evolution-reader-attack-fired*) "reader evaluation is disabled")
       (%write-string manifest-path
                      (concatenate 'string manifest-before
                                   (format nil "(:extra t)~%")))
       (check (%signals-error-p
               (lambda () (%evo-call "READ-CANDIDATE-MANIFEST"
                                     store candidate-id)))
              "a second complete form is rejected")
       (%write-string manifest-path "(:unknown-field t)\n")
       (check (%signals-error-p
               (lambda () (%evo-call "READ-CANDIDATE-MANIFEST"
                                     store candidate-id)))
              "unknown manifest keys are rejected")
       (%write-form manifest-path (%plist-put manifest :image-file "../outside"))
       (check (%signals-error-p
               (lambda () (%evo-call "READ-CANDIDATE-MANIFEST"
                                     store candidate-id)))
              "manifest image traversal is rejected before opening")
       (%write-form manifest-path (%plist-put manifest :image-sha256 "not-a-digest"))
       (check (%signals-error-p
               (lambda () (%evo-call "READ-CANDIDATE-MANIFEST"
                                     store candidate-id))))
       (%write-form manifest-path (%plist-put manifest :creator-did
                                             "did:key:zNotEd25519"))
       (check (%signals-error-p
               (lambda () (%evo-call "READ-CANDIDATE-MANIFEST"
                                     store candidate-id))))
       (%write-form manifest-path (%plist-put manifest :creator-signature
                                             (make-string 127 :initial-element #\a)))
       (check (%signals-error-p
               (lambda () (%evo-call "READ-CANDIDATE-MANIFEST"
                                     store candidate-id))))
       ;; Reader recognition is closed and allocation-bounded.  In particular,
       ;; an unknown keyword or package-qualified symbol must never intern an
       ;; attacker-selected symbol or mutate the package registry.
       (let ((attack-name
               (format nil "IMAGO-EVOLUTION-ATTACK-~D-~D"
                       (get-universal-time) (random 1000000000))))
         (check (null (find-symbol attack-name :keyword)))
         (%write-string manifest-path
                        (format nil "(:~A nil)~%" attack-name))
         (check (%signals-error-p
                 (lambda () (%evo-call "READ-CANDIDATE-MANIFEST"
                                       store candidate-id)))
                "unknown keywords are rejected without reader interning")
         (check (null (find-symbol attack-name :keyword))
                "hostile keyword text is never interned")
         (%write-string manifest-path
                        (format nil "cl-user::~A~%" attack-name))
         (check (%signals-error-p
                 (lambda () (%evo-call "READ-CANDIDATE-MANIFEST"
                                       store candidate-id)))
                "package-qualified symbols are outside the grammar")
         (check (null (find-symbol attack-name :cl-user))))
       (%write-string
        manifest-path
        (concatenate 'string
                     (make-string 80 :initial-element #\()
                     "nil"
                     (make-string 80 :initial-element #\))
                     (string #\Newline)))
       (check (%signals-error-p
               (lambda () (%evo-call "READ-CANDIDATE-MANIFEST"
                                     store candidate-id)))
              "deep forms are rejected at the parser depth bound")
       (%write-string manifest-path
                      (format nil "(:version ~A)~%"
                              (make-string 33 :initial-element #\9)))
       (check (%signals-error-p
               (lambda () (%evo-call "READ-CANDIDATE-MANIFEST"
                                     store candidate-id)))
              "oversized integers are rejected before bignum construction")
       (%write-string manifest-path
                      (format nil "(:version \"~A\")~%"
                              (make-string 65537 :initial-element #\x)))
       (check (%signals-error-p
               (lambda () (%evo-call "READ-CANDIDATE-MANIFEST"
                                     store candidate-id)))
              "oversized strings are rejected before decoded allocation")
       (%write-string manifest-path
                      (make-string (1+ (* 1024 1024))
                                   :initial-element #\Space))
       (check (%signals-error-p
               (lambda () (%evo-call "READ-CANDIDATE-MANIFEST"
                                     store candidate-id)))
              "oversized persisted forms are rejected before input buffering")
       (%write-string manifest-path manifest-before)
       (check (equal manifest
                     (%evo-call "READ-CANDIDATE-MANIFEST" store candidate-id)))
       (check (%signals-error-p
               (lambda () (%evo-call "READ-CANDIDATE-MANIFEST"
                                     store "../escape")))
              "candidate traversal is rejected before path construction")
       (check (%signals-error-p
               (lambda () (%evo-call "READ-POINTER" store "../escape")))
              "pointer traversal is rejected before path construction")
       (check (string= ledger-before
                       (%read-string (%evo-call "LEDGER-PATH" store)))
              "reader failures have no ledger effect")
       (check (null (%evo-call "READ-POINTER" store :canary)))
       (let ((pointer-path (%evo-call "POINTER-PATH" store :canary)))
         (%write-string
          pointer-path
          (format nil
                  "#.(setf anuna-imago.test::*evolution-reader-attack-fired* t)~%"))
         (check (%signals-error-p
                 (lambda () (%evo-call "READ-POINTER" store :canary)))
                "pointer readers also disable reader evaluation")
         (check (null *evolution-reader-attack-fired*))
         (check (null (%evo-call "READ-POINTER" store :active))
                "a rejected canary form cannot affect the active pointer"))
       (check (equal tools-before
                     (sort (mapcar #'symbol-name (list-tools)) #'string<))
              "readers cannot mutate the process tool registry")
       (check (equal registry-before (%package-registry-snapshot))
              "hostile readers cannot mutate the package registry")
       (%close-test-store store)))))

;; -------------------------------------------- TEST-006 / full round trip ---

(defun test-evolution-signed-responsibility-reload ()
  (%call-with-evolution-directory
   (lambda (directory)
     (let ((actors (%make-actors)))
       (multiple-value-bind (store store-path baseline baseline-id
                             candidate candidate-id)
           (%make-candidate-pair directory actors)
         (declare (ignore baseline candidate))
         (%record-comparison-matrix store actors baseline-id candidate-id)
         (let ((decision (%make-decision store baseline-id candidate-id
                                         (%actor actors :authorizer))))
           (%evo-call "PROMOTE-CANDIDATE!" store decision
                      :pointer :canary :authorizer (%actor actors :authorizer)))
         (%close-test-store store)
         (let* ((reopened (%open-test-store store-path actors))
                (events (%evo-call "READ-LEDGER" reopened))
                (freeze (%event-of-kind events :freeze))
                (evaluation (%event-of-kind events :evaluation))
                (decision (%event-of-kind events :decision))
                (promotion (%event-of-kind events :promotion)))
           (check (%evo-call "VERIFY-LEDGER" reopened))
           (check (%evo-call "VERIFY-CANDIDATE" reopened candidate-id))
           (check (string= candidate-id
                           (%evo-call "READ-POINTER" reopened :canary)))
           (dolist (did (list (getf freeze :creator-did)
                              (getf evaluation :executor-did)
                              (getf evaluation :evaluator-did)
                              (getf decision :authorizer-did)
                              (getf promotion :authorizer-did)))
             (check (and (stringp did)
                         (string= "did:key:z6Mk" did :end2 12))))
           (dolist (signature
                     (list (getf freeze :creator-signature)
                           (getf evaluation :executor-signature)
                           (getf evaluation :evaluator-signature)
                           (getf decision :authorization-signature)
                           (getf promotion :authorizer-signature)))
             (check (%valid-signature-hex-p signature)))
           (%close-test-store reopened)))))))

;; ---------------------------------------------------------------- runner ---

(defun run-evolution-tests ()
  (format t "~%========================================~%")
  (format t " SPEC-014 evolution control-plane Red Gate~%")
  (format t "========================================~%")
  (let ((*failures* 0))
    (%run-evolution-case "TEST-005 optional load boundary"
                         #'test-evolution-optional-load-boundary)
    ;; Every later case resolves the optional package dynamically.
    (when (find-package "ANUNA-IMAGO.EVOLUTION")
      (%run-evolution-case "TEST-007/019 freeze identity and immutability"
                           #'test-evolution-freeze-copy-hash-immutability-and-identity)
      (%run-evolution-case "TEST-056 ledger-size preflight"
                           #'test-evolution-ledger-size-preflight)
      (%run-evolution-case "TEST-057 Unicode control strings"
                           #'test-evolution-rejects-unicode-control-strings)
      (%run-evolution-case "TEST-060 authority signing preflight"
                           #'test-evolution-authority-signing-preflight)
      (%run-evolution-case "TEST-062 aggregate serialization bounds"
                           #'test-evolution-aggregate-serialization-bounds)
      (%run-evolution-case "TEST-009/026 surface and filesystem scope"
                           #'test-evolution-freeze-surface-and-symlink-scope)
      (%run-evolution-case "TEST-026 managed-entry symlink confinement"
                           #'test-evolution-managed-entry-symlink-confinement)
      (%run-evolution-case "TEST-008/032 lineage round trip"
                           #'test-evolution-lineage-and-surface-round-trip)
      (%run-evolution-case "TEST-008 persisted freeze evidence"
                           #'test-evolution-persisted-freeze-evidence-required)
      (%run-evolution-case "TEST-006/033 canonical bytes and signatures"
                           #'test-evolution-canonical-bytes-and-actor-signatures)
      (%run-evolution-case "TEST-010/027/034 ledger chain and replay"
                           #'test-evolution-ledger-chain-head-and-replay)
      (%run-evolution-case "TEST-066 evaluation requires prior freeze"
                           #'test-evolution-evaluation-requires-prior-freeze)
      (%run-evolution-case "TEST-011/035 disjoint role rosters"
                           #'test-evolution-disjoint-role-rosters)
      (%run-evolution-case "TEST-036 signed protocol envelope"
                           #'test-evolution-signed-protocol-envelope)
      (%run-evolution-case "TEST-037 unmatched comparison cells"
                           #'test-evolution-unmatched-comparison-cells)
      (%run-evolution-case "TEST-038 duplicate candidate cells"
                           #'test-evolution-duplicate-candidate-cells)
      (%run-evolution-case "TEST-039 campaign split isolation"
                           #'test-evolution-campaign-split-isolation)
      (%run-evolution-case "TEST-040 complete replicate counting"
                           #'test-evolution-complete-replicate-counting)
      (%run-evolution-case "TEST-041 conservative replicate noise gate"
                           #'test-evolution-conservative-replicate-noise-gate)
      (%run-evolution-case "TEST-042 separated efficiency report"
                           #'test-evolution-separated-efficiency-report)
      (%run-evolution-case "TEST-043 execution-token ceiling"
                           #'test-evolution-execution-token-increase-ceiling)
      (%run-evolution-case "TEST-044 runtime-cost ceiling"
                           #'test-evolution-runtime-cost-increase-ceiling)
      (%run-evolution-case "TEST-045 executor/config transfer gate"
                           #'test-evolution-per-executor-config-transfer-gate)
      (%run-evolution-case "TEST-046 changed-component activation coverage"
                           #'test-evolution-changed-component-activation-coverage)
      (%run-evolution-case "TEST-047 complete-run attestation"
                           #'test-evolution-complete-run-attestation)
      (%run-evolution-case "TEST-048 authorizer roster separation"
                           #'test-evolution-authorizer-roster-separation)
      (%run-evolution-case "TEST-049 creator-authorizer separation"
                           #'test-evolution-creator-authorizer-separation)
      (%run-evolution-case "TEST-050 single evaluation-plan context"
                           #'test-evolution-single-evaluation-plan-context)
      (%run-evolution-case "TEST-012/014 correctness and metric separation"
                           #'test-evolution-held-out-metrics-correctness-and-diagnostics)
      (%run-evolution-case "TEST-020 actionable missing gates"
                           #'test-evolution-missing-gate-report)
      (%run-evolution-case "TEST-013 repetition and executor boundaries"
                           #'test-evolution-repetition-and-executor-boundaries)
      (%run-evolution-case "TEST-018/031 deterministic all-event decision"
                           #'test-evolution-decision-all-events-and-order-determinism)
      (%run-evolution-case "TEST-020 decision semantic coherence"
                           #'test-evolution-decision-form-coherence)
      (%run-evolution-case "TEST-053 persisted decision context"
                           #'test-evolution-persisted-decision-context-rederivation)
      (%run-evolution-case "TEST-015/016/028/029 trusted promotion and rollback"
                           #'test-evolution-trusted-promotion-pointers-and-rollback)
      (%run-evolution-case "TEST-017/034 stale and tampered candidate denial"
                           #'test-evolution-stale-decision-and-image-tamper)
      (%run-evolution-case "TEST-034 signed manifest substitution denial"
                           #'test-evolution-signed-manifest-substitution-rejected)
      (%run-evolution-case "TEST-034 freeze manifest anchoring"
                           #'test-evolution-freeze-manifest-anchoring)
      (%run-evolution-case "TEST-058 rollback after current-image tamper"
                           #'test-evolution-rollback-recovers-from-current-image-tamper)
      (%run-evolution-case "TEST-058 descendant-prior rollback"
                           #'test-evolution-rollback-descendant-prior-of-corrupt-current)
      (%run-evolution-case "TEST-059 pointer deletion denial"
                           #'test-evolution-pointer-deletion-fails-closed)
      (%run-evolution-case "TEST-063 closed-parser properties"
                           #'test-evolution-closed-parser-properties)
      (%run-evolution-case "TEST-021/030 reader and path attack corpus"
                           #'test-evolution-reader-and-path-attack-corpus)
      (%run-evolution-case "TEST-006 signed responsibility reload"
                           #'test-evolution-signed-responsibility-reload))
    (cond ((zerop *failures*)
           (format t "~%PASS — SPEC-014 evolution control plane~%")
           t)
          (t
           (format t "~%FAIL — ~D failures in SPEC-014 evolution tests~%"
                   *failures*)
           nil))))

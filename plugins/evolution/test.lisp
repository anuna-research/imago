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
(defparameter +evolution-sha-a+ (make-string 64 :initial-element #\a))
(defparameter +evolution-sha-b+ (make-string 64 :initial-element #\b))
(defparameter +evolution-sha-c+ (make-string 64 :initial-element #\c))

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
   (with-output-to-string (stream)
     (let ((*package* (find-package :keyword))
           (*print-base* 10)
           (*print-radix* nil)
           (*print-case* :downcase)
           (*print-pretty* nil)
           (*print-circle* nil)
           (*print-escape* t)
           (*print-readably* t))
       (prin1 form stream)
       (when trailing-newline (terpri stream))))))

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

(defun %valid-sha256-p (value)
  (and (stringp value)
       (= 64 (length value))
       (every (lambda (character)
                (or (digit-char-p character)
                    (find character "abcdef" :test #'char=)))
              value)))

(defun %valid-signature-hex-p (value)
  (and (stringp value)
       (= 128 (length value))
       (every (lambda (character)
                (or (digit-char-p character)
                    (find character "abcdef" :test #'char=)))
              value)))

(defun %valid-candidate-id-p (value)
  (and (stringp value)
       (<= 1 (length value) 63)
       (or (digit-char-p (char value 0))
           (find (char value 0) "abcdefghijklmnopqrstuvwxyz" :test #'char=))
       (every (lambda (character)
                (or (digit-char-p character)
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

(defun %record-evaluation (store actors candidate-id run-id task-id score
                           &key (executor :executor-1)
                                (evaluator :evaluator-1)
                                (correct-p t)
                                (activation-evidence '("tool:dispatch:1"))
                                (duration-ms 100)
                                (input-tokens 20)
                                (output-tokens 10)
                                (cost 30)
                                (split :held-out))
  (%evo-call "RECORD-EVALUATION!"
             store
             :run-id run-id
             :split split
             :task-id task-id
             :candidate-id candidate-id
             :executor (%actor actors executor)
             :evaluator (%actor actors evaluator)
             :task-correct-p correct-p
             :capability-score-micros score
             :activation-evidence activation-evidence
             :duration-ms duration-ms
             :input-tokens input-tokens
             :output-tokens output-tokens
             :estimated-cost-microusd cost))

(defun %record-comparison-matrix (store actors baseline-id candidate-id
                                  &key (candidate-correct '(t t t))
                                       (candidate-scores '(700000 800000 900000))
                                       (order :forward)
                                       (prefix "matrix"))
  (let* ((baseline
           (list
            (list baseline-id (format nil "~A-b1" prefix) "task-1" 500000
                  :executor :executor-1 :evaluator :evaluator-1)
            (list baseline-id (format nil "~A-b2" prefix) "task-2" 600000
                  :executor :executor-2 :evaluator :evaluator-2)
            (list baseline-id (format nil "~A-b3" prefix) "task-3" 700000
                  :executor :executor-1 :evaluator :evaluator-2)))
         (candidate
           (loop for index from 1
                 for score in candidate-scores
                 for correct in candidate-correct
                 collect
                 (list candidate-id (format nil "~A-c~D" prefix index)
                       (format nil "task-~D" index) score
                       :correct-p correct
                       :executor (if (oddp index) :executor-1 :executor-2)
                       :evaluator (if (= index 1) :evaluator-1 :evaluator-2))))
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
                       &key (minimum-repetitions 3)
                            (minimum-executors 2)
                            (minimum-capability-delta-micros 100000))
  (%evo-call "MAKE-DECISION!"
             store baseline-id candidate-id
             :minimum-held-out-repetitions minimum-repetitions
             :minimum-distinct-executors minimum-executors
             :minimum-capability-delta-micros minimum-capability-delta-micros
             :authorizer authorizer))

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
       (%write-octets source #(9 9 9))
       (check (equalp copy-before (%read-octets copy-path))
              "later source mutation cannot alter frozen bytes")
       (%close-test-store store-a)
       (%close-test-store store-b)))))

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
            :split :held-out
            :task-id "task-1"
            :executor-did ,+evolution-fixture-did+
            :evaluator-did ,+evolution-fixture-did+
            :task-correct-p t
            :capability-score-micros 750000
            :activation-evidence ("tool:dispatch:1")
            :duration-ms 123
            :input-tokens 45
            :output-tokens 6
            :estimated-cost-microusd 78))
        (decision
          `(:event :decision
            :timestamp ,+evolution-fixed-time+
            :candidate-id "c-fixed"
            :baseline-id "b-fixed"
            :evidence-head ,+evolution-sha-b+
            :gates (:candidate-digest-valid t :baseline-digest-valid t)
            :baseline-capability-mean-micros 500000
            :candidate-capability-mean-micros 750000
            :capability-delta-micros 250000
            :runtime-cost-microusd 78
            :development-cost-microusd 12
            :eligible-p t))
        (head `(:seq 7 :event-hash ,+evolution-sha-c+)))
    (list
     (list :manifest manifest
           "(:version 1 :candidate-id \"c-fixed\" :parent-id nil :parent-image-sha256 nil :image-file \"agent.core\" :image-sha256 \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\" :creator-did \"did:key:z6MktwupdmLXVVqTzCw4i46r4uGyosGXRnR3XjN4Zq7oMMsw\" :created-at \"2026-09-04T00:00:00Z\" :theory-fingerprint \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\" :prompt-schema-sha256 \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\" :tool-schema-sha256 \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\" :changed-components (\"prompt/system\") :budgets (:development-cost-microusd 12 :wall-time-ms 34 :input-tokens 56 :output-tokens 78) :activation-evidence (\"prompt/system:sha256:aa\"))"
           "0077eec6c4bebed589a902542ebf53f43ff1198f0b1705ee008fa351154242af0abe5f3b735251bd37a39d752f45ead393c6b0ac5b717616ce1a2a315c552d0f")
     (list :event event
           "(:event :evaluation :timestamp \"2026-09-04T00:00:00Z\" :candidate-id \"c-fixed\" :run-id \"run-1\" :split :held-out :task-id \"task-1\" :executor-did \"did:key:z6MktwupdmLXVVqTzCw4i46r4uGyosGXRnR3XjN4Zq7oMMsw\" :evaluator-did \"did:key:z6MktwupdmLXVVqTzCw4i46r4uGyosGXRnR3XjN4Zq7oMMsw\" :task-correct-p t :capability-score-micros 750000 :activation-evidence (\"tool:dispatch:1\") :duration-ms 123 :input-tokens 45 :output-tokens 6 :estimated-cost-microusd 78)"
           "7276ded67e06cf428a18b563f7d31e0a874f6ad92767f1ab93242427bb179f3f0d546642dcca4f2fe073c014fce6faaa7672d1354d4e7fffc055745e47fa5f06")
     (list :decision decision
           "(:event :decision :timestamp \"2026-09-04T00:00:00Z\" :candidate-id \"c-fixed\" :baseline-id \"b-fixed\" :evidence-head \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\" :gates (:candidate-digest-valid t :baseline-digest-valid t) :baseline-capability-mean-micros 500000 :candidate-capability-mean-micros 750000 :capability-delta-micros 250000 :runtime-cost-microusd 78 :development-cost-microusd 12 :eligible-p t)"
           "003223ee82545092c1ffa9eff66cd39e643334a6f1501e9f6656b3cf4e4ee7f6393101087c6af66edce51b57e5eb1864e3db23a5b7ea5c23d0d0bf38087e020b")
     (list :head head
           "(:seq 7 :event-hash \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\")"
           "4b48f4958fe2da0dadab2db37f7eb6bc8128b0c2c1a485f59d02fe2920a9aaf4183b286b864f0412a0f215c6262de92e9974bfa81885436c92750d3daa0cbc08"))))

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
                               bytes-1 (hex->bytes expected-signature))))))
    (dolist (bad (list 1.5 'not-a-keyword '(1 . 2)
                       (format nil "control~Ccharacter" #\Newline)))
      (check (%signals-error-p
              (lambda () (%evo-call "CANONICAL-BYTES" (list :value bad))))
             (format nil "canonical grammar rejects ~S" bad))))
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
         (check (%evo-call "VERIFY-CANDIDATE" store candidate-id)))
       (%close-test-store store)))))

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
           (check (equal '("tool:dispatch:1")
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
                           :activation-evidence-present
                           :capability-delta-met))
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
                               (format nil "boundary-b~D" index)
                               (format nil "task-~D" index) 500000
                               :executor :executor-1 :evaluator :evaluator-1)
           (%record-evaluation store actors candidate-id
                               (format nil "boundary-c~D" index)
                               (format nil "task-~D" index) 800000
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
         (%record-evaluation store actors baseline-id "boundary-b2" "task-2"
                             500000 :executor :executor-2 :evaluator :evaluator-2)
         (%record-evaluation store actors candidate-id "boundary-c2" "task-2"
                             800000 :executor :executor-2 :evaluator :evaluator-2)
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
            :runtime-cost-microusd
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
                                        "order-c4" "task-4" 0
                                        :executor :executor-2
                                        :evaluator :evaluator-1)
                    (%record-evaluation store actors baseline-id
                                        "order-b4" "task-4" 600000
                                        :executor :executor-2
                                        :evaluator :evaluator-1)
                    (values store baseline-id candidate-id
                            (%make-decision store baseline-id candidate-id
                                            (%actor actors :authorizer))))))
         (multiple-value-bind (store-a baseline-a candidate-a decision-a)
             (one-store "forward" :forward)
           (check (= 600000 (getf decision-a :baseline-capability-mean-micros)))
           (check (= 600000 (getf decision-a :candidate-capability-mean-micros))
                  "the decision consumes the low fourth run")
           (check (= 0 (getf decision-a :capability-delta-micros)))
           (check (= 240 (getf decision-a :runtime-cost-microusd))
                  "runtime cost includes all eight held-out runs")
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
                (validate (%evo-function "%VALIDATE-DECISION-EVENT")))
           (check (funcall validate decision)
                  "the emitted decision satisfies its semantic schema")
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
                                          '(:capability-delta-met)))))
                  "failed gates must exactly correspond to false gate values")
           (check (%signals-error-p
                   (lambda ()
                     (funcall validate
                              (%plist-put decision :eligible-p nil))))
                  "eligibility is true exactly when no gate failed"))
         (%close-test-store store))))))

;; ----------------------------- TEST-015, TEST-016, TEST-028, TEST-029 ---

(defun %promote-with-pointer-observer (store decision old-id new-id authorizer)
  "Promote once while another thread repeatedly validates the pointer file."
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
                             (%evo-call "READ-POINTER" store :canary)
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
                                                (%actor actors :authorizer))))
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
             (check (= 1 (length (%events-of-kind events :rollback))))))
         (%close-test-store store))))))

;; ------------------------------------- TEST-017, TEST-034 / stale/tamper ---

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
           (%record-evaluation store actors candidate-id "late-run" "task-late"
                               900000 :executor :executor-2
                               :evaluator :evaluator-1)
           (check (%signals-error-p
                   (lambda ()
                     (%evo-call "PROMOTE-CANDIDATE!" store decision
                                :pointer :canary
                                :authorizer (%actor actors :authorizer))))
                  "new evidence makes the prior decision stale")
           (check (null (%evo-call "READ-POINTER" store :canary))))
         (let* ((fresh (%make-decision store baseline-id candidate-id
                                       (%actor actors :authorizer)))
                (image-path (%evo-call "CANDIDATE-IMAGE-PATH" store candidate-id))
                (image-before (%read-octets image-path))
                (ledger-count (length (%evo-call "READ-LEDGER" store))))
           (setf (aref image-before 0) (logxor #xff (aref image-before 0)))
           (%write-octets image-path image-before)
           (check (%rejected-p
                   (lambda () (%evo-call "VERIFY-CANDIDATE" store candidate-id)))
                  "one changed image byte invalidates the candidate")
           (check (%signals-error-p
                   (lambda ()
                     (%evo-call "PROMOTE-CANDIDATE!" store fresh
                                :pointer :canary
                                :authorizer (%actor actors :authorizer))))
                  "a mutated candidate cannot be promoted")
           (check (null (%evo-call "READ-POINTER" store :canary)))
           (check (= ledger-count (length (%evo-call "READ-LEDGER" store)))
                  "failed promotion appends no event"))
         (%close-test-store store))))))

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
       (%write-form manifest-path (append manifest '(:unknown-field t)))
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
                              (make-string 21 :initial-element #\9)))
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
      (%run-evolution-case "TEST-011/035 disjoint role rosters"
                           #'test-evolution-disjoint-role-rosters)
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
      (%run-evolution-case "TEST-015/016/028/029 trusted promotion and rollback"
                           #'test-evolution-trusted-promotion-pointers-and-rollback)
      (%run-evolution-case "TEST-017/034 stale and tampered candidate denial"
                           #'test-evolution-stale-decision-and-image-tamper)
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

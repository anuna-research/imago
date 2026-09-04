;;;; receipt-log.lisp — append-only content-addressed receipt log (M5)
;;;;
;;;; Every accepted ask and emitted reply is appended to a per-process log.
;;;; Storage is a single line-oriented file: each entry is a CL plist
;;;; printed with PRIN1 (so READ recovers it exactly). Content addressing
;;;; uses MD5 from SBCL's sb-md5 contrib — deliberately NOT ironclad
;;;; (deferring Quicklisp setup to M6+). The hash here is for dedup, not
;;;; cryptographic protection; see ADR-001 for the SBCL commitment.
;;;;
;;;; Per the 2k cut: NO replay-as-API. Reads happen via tail/grep/jq from
;;;; the shell, or via READ-RECEIPTS for tests/inspection.

(in-package #:anuna-imago)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-md5))

;; Receipt files are an ingress boundary: an evaluator with ordinary file
;; write authority can append bytes to a known log and a later inspection or
;; reopen must never interpret those bytes as code.  Keep the accepted wire
;; representation deliberately smaller than Common Lisp's full reader.
(defparameter +receipt-maximum-form-characters+ 4194304)
(defparameter +receipt-maximum-form-depth+ 320)
(defparameter +receipt-maximum-form-nodes+ 20000)
(defparameter +receipt-maximum-token-characters+ 512)
(defparameter +receipt-maximum-string-characters+ 65536)
(defparameter +receipt-maximum-summary-characters+ 1000000)
(defparameter +receipt-maximum-log-octets+ 67108864)

(defparameter +receipt-entry-keys+
  '(:receipt-id :seq :direction :dialect :verb :content-hash :timestamp
    :agent-id :producer-id :status
    :tool :form :form-hash :result-phase :result-tag :elapsed-ms
    :result-summary))

(defparameter +receipt-general-entry-keys+
  '(:receipt-id :seq :direction :dialect :verb :content-hash :timestamp
    :agent-id :producer-id :status))

(defparameter +receipt-selfmod-entry-keys+
  '(:tool :agent-id :timestamp :form :form-hash :result-phase :result-tag
    :elapsed-ms :result-summary))

(defparameter +receipt-reader-symbol-tokens+
  '("NIL" "T" "HARNESS-EVAL"
    ":RECEIPT-ID" ":SEQ" ":DIRECTION" ":DIALECT" ":VERB"
    ":CONTENT-HASH" ":TIMESTAMP" ":AGENT-ID" ":PRODUCER-ID" ":STATUS"
    ":TOOL" ":FORM" ":FORM-HASH" ":RESULT-PHASE" ":RESULT-TAG"
    ":ELAPSED-MS" ":RESULT-SUMMARY"
    ":INBOUND" ":OUTBOUND" ":RECEIVED" ":SENT"
    ":PRE-FILTER" ":REASONER" ":EVALUATED" ":ROLLBACK" ":EVALUATION"
    ":OK" ":REJECTED" ":VETOED" ":ERROR" ":TIMEOUT"
    ":INDEX" ":SYMBOL" ":KIND" ":CONDITION-TYPE" ":MESSAGE"
    ":RULE" ":REASON" ":FORM-ID" ":GOAL" ":DERIVATION" ":HINT"
    ":VALUE" ":VALUE-FINGERPRINT" ":ROLLBACK-INDICES")
  "The complete non-numeric symbol vocabulary accepted from receipt bytes.")

(defparameter +receipt-summary-keywords+
  '(:index :symbol :kind :condition-type :message :rule :reason :form-id
    :goal :derivation :hint :value :value-fingerprint :rollback-indices)
  "Finite plist-key vocabulary preserved inside inert audit summaries.")

(defun %receipt-whitespace-p (character)
  (member character '(#\Space #\Tab #\Newline #\Return #\Page)
          :test #'char=))

(defun %receipt-unicode-scalar-character-p (character)
  (let ((code (char-code character)))
    (and (<= code #x10FFFF)
         (not (<= #xD800 code #xDFFF)))))

(defun %receipt-simple-string (value)
  "Copy string-like VALUE to the simple string syntax our wire grammar uses."
  (coerce value 'simple-string))

(defun %receipt-integer-token-p (token)
  (let* ((length (length token))
         (start (if (and (plusp length)
                         (member (char token 0) '(#\+ #\-) :test #'char=))
                    1
                    0)))
    (and (< start length)
         (loop for index from start below length
               always (digit-char-p (char token index) 10)))))

(defun %receipt-token-allowed-p (token)
  "Recognize a token without interning it or consulting ambient packages."
  (or (%receipt-integer-token-p token)
      (member (string-upcase token) +receipt-reader-symbol-tokens+
              :test #'string=)))

(defun %read-receipt-source (stream)
  "Read one bounded parenthesized receipt source from STREAM without invoking
the Lisp reader.  Sharp dispatch, comments, reader quoting, raw symbol escapes,
oversized tokens, invalid Unicode, and excessive nesting fail closed."
  (let ((first
          (loop for character = (read-char stream nil :eof)
                until (or (eq character :eof)
                          (not (%receipt-whitespace-p character)))
                finally (return character))))
    (when (eq first :eof)
      (return-from %read-receipt-source :eof))
    (unless (char= first #\()
      (error "Receipt entry must begin with an opening parenthesis."))
    (let ((buffer (make-array 256 :element-type 'character
                                  :adjustable t :fill-pointer 0))
          (depth 0)
          (in-string nil)
          (in-bar-symbol nil)
          (escaped nil)
          (source-nodes 0)
          (token-characters 0)
          (token (make-array 32 :element-type 'character
                                :adjustable t :fill-pointer 0))
          (string-characters 0))
      (labels ((emit (character)
                 (unless (%receipt-unicode-scalar-character-p character)
                   (error "Receipt source contains invalid Unicode."))
                 (when (>= (fill-pointer buffer)
                           +receipt-maximum-form-characters+)
                   (error "Receipt entry exceeds the source-size bound."))
                 (vector-push-extend character buffer))
               (charge-node ()
                 (when (> (incf source-nodes)
                          +receipt-maximum-form-nodes+)
                   (error "Receipt entry exceeds the pre-read node bound.")))
               (finish-token ()
                 (when (plusp (fill-pointer token))
                   (let ((text (coerce token 'string)))
                     (unless (%receipt-token-allowed-p text)
                       (error "Receipt entry contains an unknown symbol token.")))
                   (charge-node)
                   (setf (fill-pointer token) 0
                         token-characters 0)))
               (ordinary-token-character (character)
                 (incf token-characters)
                 (when (> token-characters +receipt-maximum-token-characters+)
                   (error "Receipt token exceeds the length bound."))
                 (vector-push-extend character token))
               (process (character)
                 (emit character)
                 (cond
                   (escaped
                    (setf escaped nil)
                    (when in-string
                      (incf string-characters)))
                   (in-string
                    (cond
                      ((char= character #\\) (setf escaped t))
                      ((char= character #\") (setf in-string nil))
                      (t
                       (incf string-characters)
                       (when (> string-characters
                                +receipt-maximum-string-characters+)
                         (error "Receipt string exceeds the length bound.")))))
                   (in-bar-symbol
                    (error "Escaped symbol syntax is forbidden in receipts."))
                   (t
                    (case character
                      (#\"
                       (finish-token)
                       (charge-node)
                       (setf in-string t string-characters 0
                             token-characters 0))
                      (#\|
                       (error "Escaped symbol syntax is forbidden in receipts."))
                      (#\(
                       (finish-token)
                       (charge-node)
                       (incf depth)
                       (when (> depth +receipt-maximum-form-depth+)
                         (error "Receipt entry exceeds the nesting bound.")))
                      (#\)
                       (finish-token)
                       (decf depth)
                       (when (minusp depth)
                         (error "Receipt entry has an unmatched parenthesis.")))
                      ((#\Space #\Tab #\Newline #\Return #\Page)
                       (finish-token))
                      ((#\# #\; #\' #\` #\, #\\)
                       (error "Receipt entry uses forbidden reader syntax."))
                      (otherwise (ordinary-token-character character)))))))
        (process first)
        (loop
          (when (and (zerop depth) (not in-string) (not in-bar-symbol))
            (return (coerce buffer 'string)))
          (let ((character (read-char stream nil :eof)))
            (when (eq character :eof)
              (error "Receipt entry ended before its closing parenthesis."))
            (process character)))))))

(defun %proper-receipt-list-p (value)
  "Whether VALUE is a finite proper list, without allocating a copy."
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

(defun %receipt-summary-plist-p (value)
  (or (null value)
      (and (%proper-receipt-list-p value)
           (evenp (length value))
           (loop for cursor on value by #'cddr
                 always (member (car cursor) +receipt-summary-keywords+
                                :test #'eq)))))

(defun %receipt-entry-keys-exact-p (entry keys)
  (and (= (length entry) (* 2 (length keys)))
       (every (lambda (key)
                (loop for cursor on entry by #'cddr
                      thereis (eq key (car cursor))))
              keys)))

(defun %receipt-entry-shape-p (entry)
  "Recognize one of the two complete persisted receipt record schemas."
  (and (%proper-receipt-list-p entry)
       (cond
         ((getf entry :receipt-id)
          (and (%receipt-entry-keys-exact-p
                entry +receipt-general-entry-keys+)
               (stringp (getf entry :receipt-id))
               (typep (getf entry :seq) '(integer 0 *))
               (member (getf entry :direction) '(:inbound :outbound))
               (or (null (getf entry :dialect))
                   (stringp (getf entry :dialect)))
               (or (null (getf entry :verb))
                   (stringp (getf entry :verb)))
               (stringp (getf entry :content-hash))
               (= 32 (length (getf entry :content-hash)))
               (stringp (getf entry :timestamp))
               (stringp (getf entry :agent-id))
               (stringp (getf entry :producer-id))
               (member (getf entry :status) '(:received :sent))))
         ((getf entry :tool)
          (and (%receipt-entry-keys-exact-p
                entry +receipt-selfmod-entry-keys+)
               (eq (getf entry :tool) 'harness-eval)
               (stringp (getf entry :agent-id))
               (stringp (getf entry :timestamp))
               (stringp (getf entry :form))
               (let ((hash (getf entry :form-hash)))
                 (or (null hash) (and (stringp hash) (= 32 (length hash)))))
               (member (getf entry :result-phase)
                       '(:pre-filter :reasoner :evaluated :rollback :evaluation))
               (member (getf entry :result-tag)
                       '(:ok :rejected :vetoed :error :timeout))
               (typep (getf entry :elapsed-ms) '(integer 0 *))
               (%receipt-summary-plist-p (getf entry :result-summary))))
         (t nil))))

(defun %receipt-entry-structure-p (entry)
  "Recognize the bounded data-only plist grammar emitted by this module."
  (unless (and (%proper-receipt-list-p entry) (evenp (length entry))
               (%receipt-entry-shape-p entry))
    (return-from %receipt-entry-structure-p nil))
  (let ((keys (make-hash-table :test #'eq)))
    (loop for cursor on entry by #'cddr
          for key = (car cursor)
          do (unless (and (member key +receipt-entry-keys+ :test #'eq)
                          (not (gethash key keys)))
               (return-from %receipt-entry-structure-p nil))
             (setf (gethash key keys) t)))
  (let ((pending (list (cons entry 0)))
        (nodes 0))
    (loop while pending
          for item = (pop pending)
          for value = (car item)
          for depth = (cdr item)
          do (incf nodes)
             (when (or (> nodes +receipt-maximum-form-nodes+)
                       (> depth +receipt-maximum-form-depth+))
               (return-from %receipt-entry-structure-p nil))
             (typecase value
               (cons
                (push (cons (car value) (1+ depth)) pending)
                ;; The CDR is the current list's spine, not an additional
                ;; semantic nesting level.  Flat evidence may be long while
                ;; still respecting the node bound.
                (push (cons (cdr value) depth) pending))
               (string
                (unless (and (<= (length value)
                                 +receipt-maximum-string-characters+)
                             (loop for character across value
                                   always
                                   (%receipt-unicode-scalar-character-p
                                    character)))
                  (return-from %receipt-entry-structure-p nil)))
               (symbol
                (when (> (length (symbol-name value))
                         +receipt-maximum-token-characters+)
                  (return-from %receipt-entry-structure-p nil)))
               ((or number character) nil)
               (t (return-from %receipt-entry-structure-p nil))))
    t))

(defun %reject-receipt-sharp-reader (stream character)
  (declare (ignore stream character))
  (error "Sharp reader syntax is forbidden in receipt entries."))

(defun %read-receipt-locked (stream)
  "Read one closed, bounded receipt entry with code execution disabled."
  (let ((source (%read-receipt-source stream)))
    (when (eq source :eof)
      (return-from %read-receipt-locked :eof))
    (let ((readtable (copy-readtable nil)))
      (set-macro-character #\# #'%reject-receipt-sharp-reader nil readtable)
      (let ((*readtable* readtable)
            (*read-eval* nil)
            (*read-suppress* nil)
            (*read-base* 10)
            (*read-default-float-format* 'single-float)
            (*break-on-signals* nil)
            (*package* (find-package :anuna-imago)))
        (multiple-value-bind (entry end)
            (read-from-string source nil :eof)
          (unless (and (not (eq entry :eof))
                       (= end (length source))
                       (%receipt-entry-structure-p entry))
            (error "Receipt entry is outside the closed data grammar."))
          entry)))))

(defun %receipt-file-size (path)
  (with-open-file (stream path :direction :input :if-does-not-exist nil
                               :element-type '(unsigned-byte 8))
    (if stream (file-length stream) 0)))

(defun %ensure-receipt-file-size! (path &optional (additional-octets 0))
  (when (> (+ (%receipt-file-size path) additional-octets)
           +receipt-maximum-log-octets+)
    (error "Receipt log exceeds the configured file-size bound."))
  t)

(defun %write-receipt-entry! (log entry)
  "Validate and append exactly one writer-domain receipt entry."
  (unless (%receipt-entry-structure-p entry)
    (error "Receipt writer produced data outside the closed grammar."))
  (let* ((*print-pretty* nil) (*print-readably* nil) (*print-circle* nil)
         (*print-length* nil) (*print-level* nil) (*print-base* 10)
         (*print-radix* nil) (*print-case* :upcase) (*print-array* t)
         (*print-gensym* t) (*package* (find-package :anuna-imago))
         (wire (%receipt-simple-string (prin1-to-string entry)))
         (octets (length (sb-ext:string-to-octets
                          wire :external-format :utf-8))))
    (when (> (length wire) +receipt-maximum-form-characters+)
      (error "Receipt writer exceeded the entry-size bound."))
    (%ensure-receipt-file-size! (receipt-log-path log) (1+ octets))
    (write-string wire (%receipt-log-stream log))
    (terpri (%receipt-log-stream log))
    (force-output (%receipt-log-stream log))
    entry))

;; --------------------------------------------------------------- class ---

(defclass receipt-log ()
  ((path   :initarg :path :reader receipt-log-path)
   (stream :initform nil  :accessor %receipt-log-stream)
   (seqs   :initform (make-hash-table :test 'equal) :reader %receipt-log-seqs
           :documentation "Map: receipt-id → highest seq written.")
   (lock   :initform (sb-thread:make-mutex :name "receipt-log")
           :reader  %receipt-log-lock))
  (:documentation "Append-only content-addressed log. Thread-safe."))

(defmethod print-object ((log receipt-log) stream)
  (print-unreadable-object (log stream :type t :identity t)
    (format stream "~A receipts=~D"
            (receipt-log-path log)
            (hash-table-count (%receipt-log-seqs log)))))

;; ------------------------------------------------------ open / close ---

(defun open-receipt-log (path)
  "Open or create the log at PATH. Recovers per-receipt seq counters from
existing entries so subsequent APPEND-RECEIPT! produces monotonic seqs."
  (%ensure-receipt-file-size! path)
  (let ((log (make-instance 'receipt-log :path path)))
    (%recover-seqs! log)
    (setf (%receipt-log-stream log)
          (open path :direction :output
                     :if-exists :append
                     :if-does-not-exist :create
                     :element-type 'character))
    log))

(defun close-receipt-log! (log)
  "Close the underlying stream. Idempotent."
  (sb-thread:with-mutex ((%receipt-log-lock log))
    (when (%receipt-log-stream log)
      (close (%receipt-log-stream log))
      (setf (%receipt-log-stream log) nil))))

(defun %recover-seqs! (log)
  "Scan existing entries to recover the next-seq table."
  (with-open-file (s (receipt-log-path log)
                     :direction :input
                     :if-does-not-exist nil)
    (when s
      (loop for entry = (%read-receipt-locked s)
            until (eq entry :eof)
            do (let ((rid (getf entry :receipt-id))
                     (seq (getf entry :seq)))
                 (when (and rid (integerp seq))
                   (let ((current (gethash rid (%receipt-log-seqs log) -1)))
                     (when (> seq current)
                       (setf (gethash rid (%receipt-log-seqs log)) seq)))))))))

;; --------------------------------------------------------- content-hash ---

(defun content-hash (body)
  "Hex-encoded MD5 of BODY. Accepts a string (UTF-8 encoded) or a byte
vector. Used for content-addressed receipt entries — dedup, not crypto."
  (let* ((bytes (etypecase body
                  (string (sb-ext:string-to-octets body :external-format :utf-8))
                  ((vector (unsigned-byte 8)) body)))
         (digest (sb-md5:md5sum-sequence bytes)))
    (%receipt-simple-string
     (with-output-to-string (s)
       (loop for b across digest
             do (format s "~(~2,'0x~)" b))))))

;; --------------------------------------------------------- timestamp ---

(defun iso-8601-now ()
  "Current UTC time as `YYYY-MM-DDTHH:MM:SSZ`."
  (multiple-value-bind (sec min hr day month year)
      (decode-universal-time (get-universal-time) 0)
    (%receipt-simple-string
     (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
             year month day hr min sec))))

;; ------------------------------------------------------ append ---

(defun append-receipt! (log &key receipt-id direction dialect verb
                                 body agent-id producer-id (status :received))
  "Append a receipt entry. Computes :seq, :content-hash, :timestamp.
Returns the entry plist that was written. Thread-safe; multiple writers
  are serialised on a per-log mutex."
  (check-type receipt-id string)
  (check-type direction (member :inbound :outbound))
  (check-type status (member :received :sent))
  (let ((*print-pretty* nil) (*print-readably* nil) (*print-circle* nil)
        (*print-length* nil) (*print-level* nil) (*print-base* 10)
        (*print-radix* nil) (*print-case* :upcase) (*print-array* t)
        (*print-gensym* t) (*package* (find-package :anuna-imago)))
    (flet ((text (value)
             (%receipt-simple-string (princ-to-string (or value "?"))))
           (optional-text (value)
             (and value (%receipt-simple-string (princ-to-string value)))))
      (sb-thread:with-mutex ((%receipt-log-lock log))
        (let* ((safe-id (%receipt-simple-string receipt-id))
               (current (gethash safe-id (%receipt-log-seqs log) -1))
               (next-seq (1+ current))
               (entry (list :receipt-id safe-id
                            :seq next-seq
                            :direction direction
                            :dialect (optional-text dialect)
                            :verb (optional-text verb)
                            :content-hash (content-hash (or body ""))
                            :timestamp (iso-8601-now)
                            :agent-id (text agent-id)
                            :producer-id (text producer-id)
                            :status status)))
          (prog1 (%write-receipt-entry! log entry)
            ;; Publish the sequence only after every grammar/size preflight
            ;; and the durable append have succeeded.
            (setf (gethash safe-id (%receipt-log-seqs log)) next-seq)))))))

;; ------------------------------------------------------ read ---

(defun read-receipts (path &key limit)
  "Read closed-grammar entries from PATH, optionally retaining its final LIMIT."
  (when (and limit (or (not (integerp limit)) (minusp limit) (> limit 1000)))
    (error "Receipt read limit must be an integer from 0 through 1000."))
  (%ensure-receipt-file-size! path)
  (with-open-file (s path :direction :input :if-does-not-exist nil)
    (when s
      (if (null limit)
          (loop for entry = (%read-receipt-locked s)
                until (eq entry :eof)
                collect entry)
          (let ((ring (make-array (max 1 limit)))
                (count 0))
            (loop for entry = (%read-receipt-locked s)
                  until (eq entry :eof)
                  do (when (plusp limit)
                       (setf (aref ring (mod count limit)) entry))
                     (incf count))
            (loop with retained = (min count limit)
                  for offset below retained
                  collect (aref ring (mod (+ (- count retained) offset)
                                          limit))))))))

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
      (loop for entry = (handler-case (read s nil :eof) (error () :eof))
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
    (with-output-to-string (s)
      (loop for b across digest
            do (format s "~(~2,'0x~)" b)))))

;; --------------------------------------------------------- timestamp ---

(defun iso-8601-now ()
  "Current UTC time as `YYYY-MM-DDTHH:MM:SSZ`."
  (multiple-value-bind (sec min hr day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
            year month day hr min sec)))

;; ------------------------------------------------------ append ---

(defun append-receipt! (log &key receipt-id direction dialect verb
                                 body agent-id producer-id (status :received))
  "Append a receipt entry. Computes :seq, :content-hash, :timestamp.
Returns the entry plist that was written. Thread-safe; multiple writers
are serialised on a per-log mutex."
  (check-type receipt-id string)
  (check-type direction (member :inbound :outbound))
  (sb-thread:with-mutex ((%receipt-log-lock log))
    (let* ((current (gethash receipt-id (%receipt-log-seqs log) -1))
           (next-seq (1+ current))
           (entry (list :receipt-id receipt-id
                        :seq next-seq
                        :direction direction
                        :dialect dialect
                        :verb verb
                        :content-hash (content-hash (or body ""))
                        :timestamp (iso-8601-now)
                        :agent-id (princ-to-string (or agent-id "?"))
                        :producer-id (princ-to-string (or producer-id "?"))
                        :status status)))
      (setf (gethash receipt-id (%receipt-log-seqs log)) next-seq)
      (let ((*print-pretty* nil)
            (*print-readably* t))
        (prin1 entry (%receipt-log-stream log)))
      (terpri (%receipt-log-stream log))
      (force-output (%receipt-log-stream log))
      entry)))

;; ------------------------------------------------------ read ---

(defun read-receipts (path)
  "Read all entries from PATH. For tests/inspection only; production
readers should tail/grep/jq the file directly per the 2k 'no replay API' cut."
  (with-open-file (s path :direction :input :if-does-not-exist nil)
    (when s
      (loop for entry = (handler-case (read s nil :eof) (error () :eof))
            until (eq entry :eof)
            collect entry))))

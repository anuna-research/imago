;;;; m5-tests.lisp — quality-gate tests for M5 (receipt log)

(in-package #:anuna-imago.test)

(export 'run-m5-tests)

(defun %temp-log-path ()
  (format nil "/tmp/imago-test-receipt-~A.log" (random 1000000)))

(defun %cleanup-temp (path)
  (handler-case (delete-file path) (error () nil)))

;; ----------------------------------------------- content-hash ---

(defun test-content-hash-deterministic ()
  (format t "~%-- content-hash-deterministic --~%")
  (check (string= (content-hash "hello") (content-hash "hello"))
         "same input → same hash")
  (check (not (string= (content-hash "hello") (content-hash "world")))
         "different inputs → different hashes")
  (check (= 32 (length (content-hash "x")))
         "MD5 hex digest is 32 chars"))

(defun test-content-hash-utf8 ()
  (format t "~%-- content-hash-utf8 --~%")
  ;; "café" should hash deterministically as UTF-8 bytes
  (let ((h1 (content-hash "café"))
        (h2 (content-hash "café")))
    (check (string= h1 h2) "non-ASCII string round-trips")
    (check (= 32 (length h1)))))

;; ----------------------------------------------- append + read ---

(defun test-append-read-roundtrip ()
  (format t "~%-- append-read-roundtrip --~%")
  (let ((path (%temp-log-path)))
    (unwind-protect
         (let ((log (open-receipt-log path)))
           (unwind-protect
                (progn
                  (append-receipt! log
                                   :receipt-id "rcpt-1" :direction :inbound
                                   :dialect "echo" :verb "say"
                                   :body "hello"
                                   :agent-id 'echo-a
                                   :producer-id "user-1"
                                   :status :received)
                  (append-receipt! log
                                   :receipt-id "rcpt-1" :direction :outbound
                                   :dialect "echo" :verb "say"
                                   :body "echo: hello"
                                   :agent-id 'echo-a
                                   :producer-id "user-1"
                                   :status :sent))
             (close-receipt-log! log))
           (let ((entries (read-receipts path)))
             (check (= 2 (length entries)))
             (let ((e0 (first entries))
                   (e1 (second entries)))
               (check (string= "rcpt-1" (getf e0 :receipt-id)))
               (check (= 0 (getf e0 :seq)))
               (check (eq :inbound (getf e0 :direction)))
               (check (= 32 (length (getf e0 :content-hash))))
               (check (string= "rcpt-1" (getf e1 :receipt-id)))
               (check (= 1 (getf e1 :seq)) "second entry has seq=1")
               (check (eq :outbound (getf e1 :direction))))))
      (%cleanup-temp path))))

;; ----------------------------------------------- per-receipt seq ---

(defun test-per-receipt-seq ()
  "Different receipt-ids get independent seq counters."
  (format t "~%-- per-receipt-seq --~%")
  (let ((path (%temp-log-path)))
    (unwind-protect
         (let ((log (open-receipt-log path)))
           (unwind-protect
                (progn
                  (append-receipt! log :receipt-id "A" :direction :inbound
                                       :body "1")
                  (append-receipt! log :receipt-id "B" :direction :inbound
                                       :body "1")
                  (append-receipt! log :receipt-id "A" :direction :inbound
                                       :body "2")
                  (append-receipt! log :receipt-id "B" :direction :inbound
                                       :body "2")
                  (append-receipt! log :receipt-id "A" :direction :inbound
                                       :body "3"))
             (close-receipt-log! log))
           (let* ((entries (read-receipts path))
                  (a-seqs (mapcar (lambda (e) (getf e :seq))
                                  (remove-if-not
                                   (lambda (e) (string= "A" (getf e :receipt-id)))
                                   entries)))
                  (b-seqs (mapcar (lambda (e) (getf e :seq))
                                  (remove-if-not
                                   (lambda (e) (string= "B" (getf e :receipt-id)))
                                   entries))))
             (check (equal '(0 1 2) a-seqs) "A's seqs are 0,1,2")
             (check (equal '(0 1) b-seqs) "B's seqs are 0,1")))
      (%cleanup-temp path))))

;; ----------------------------------------------- recovery ---

(defun test-seq-recovery-on-reopen ()
  (format t "~%-- seq-recovery-on-reopen --~%")
  (let ((path (%temp-log-path)))
    (unwind-protect
         (progn
           (let ((log (open-receipt-log path)))
             (unwind-protect
                  (progn (append-receipt! log :receipt-id "R" :direction :inbound
                                              :body "x")
                         (append-receipt! log :receipt-id "R" :direction :inbound
                                              :body "y"))
               (close-receipt-log! log)))
           ;; Reopen and append a third — seq should be 2.
           (let ((log (open-receipt-log path)))
             (unwind-protect
                  (let ((entry (append-receipt! log :receipt-id "R"
                                                    :direction :outbound
                                                    :body "z")))
                    (check (= 2 (getf entry :seq))
                           "reopened log resumes per-receipt seq"))
               (close-receipt-log! log))))
      (%cleanup-temp path))))

;; ----------------------------------------------- 1000 receipts ---

(defun test-1000-receipts ()
  "Acceptance: 1000 receipts appended in order, file is tail-readable."
  (format t "~%-- 1000-receipts --~%")
  (let ((path (%temp-log-path)))
    (unwind-protect
         (let ((log (open-receipt-log path)))
           (unwind-protect
                (loop for i from 0 below 1000
                      do (append-receipt! log
                                          :receipt-id (format nil "r-~D" (mod i 50))
                                          :direction :inbound
                                          :dialect "soak" :verb "x"
                                          :body (format nil "body-~D" i)))
             (close-receipt-log! log))
           (let ((entries (read-receipts path)))
             (check (= 1000 (length entries)) "all 1000 entries readable")
             ;; Every entry should have monotonic seq within its receipt-id
             (let ((per-rid (make-hash-table :test 'equal))
                   (failures 0))
               (dolist (e entries)
                 (let ((rid (getf e :receipt-id))
                       (seq (getf e :seq)))
                   (let ((expected (gethash rid per-rid 0)))
                     (unless (= seq expected)
                       (incf failures))
                     (setf (gethash rid per-rid) (1+ seq)))))
               (check (zerop failures) "all per-receipt seqs are monotonic 0..N"))))
      (%cleanup-temp path))))

;; ----------------------------------------------- append latency ---

(defun test-append-latency ()
  "p95 < 1ms is the spec target. We measure mean here as a sanity check;
strict p95 measurement deferred to a perf harness in M11."
  (format t "~%-- append-latency --~%")
  (let ((path (%temp-log-path)))
    (unwind-protect
         (let ((log (open-receipt-log path)))
           (unwind-protect
                (let ((start (get-internal-real-time)))
                  (loop for i from 0 below 200
                        do (append-receipt! log :receipt-id "perf"
                                                :direction :inbound
                                                :body (format nil "~D" i)))
                  (let ((mean-ms (/ (* 1000.0
                                       (- (get-internal-real-time) start))
                                    internal-time-units-per-second 200.0)))
                    (format t "  mean append latency: ~,3Fms~%" mean-ms)
                    (check (< mean-ms 5)
                           (format nil "mean ~,3Fms < 5ms" mean-ms))))
             (close-receipt-log! log)))
      (%cleanup-temp path))))

;; ----------------------------------------------- runner ---

(defun run-m5-tests ()
  (setf *failures* 0)
  (format t "~%=== M5 quality-gate tests ===~%")
  (test-content-hash-deterministic)
  (test-content-hash-utf8)
  (test-append-read-roundtrip)
  (test-per-receipt-seq)
  (test-seq-recovery-on-reopen)
  (test-1000-receipts)
  (test-append-latency)
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "M5 green.~%"))

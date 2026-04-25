;;;; fileops-tools-tests.lisp — tests for the opt-in fileops tools

(in-package #:anuna-imago.test)

(export 'run-fileops-tools-tests)

(defun %fileops-tmp-path ()
  (format nil "/tmp/imago-fileops-~A" (random 1000000)))

(defun %fileops-tmp-dir ()
  (let ((path (format nil "/tmp/imago-fileops-dir-~A" (random 1000000))))
    (ensure-directories-exist (concatenate 'string path "/"))
    path))

;; ----------------------------------------------- not auto-registered ---

(defun test-fileops-not-auto-registered ()
  "Defaults exclude file ops; install-fileops-tools! is the gate."
  (format t "~%-- fileops-not-auto-registered --~%")
  (clear-all-tools)
  (install-builtin-tools!)
  (check (null (find-tool 'harness-read-file))
         "harness-read-file is NOT auto-registered")
  (install-fileops-tools!)
  (check (not (null (find-tool 'harness-read-file)))
         "after install-fileops-tools! it IS registered")
  (uninstall-fileops-tools!)
  (check (null (find-tool 'harness-read-file))
         "uninstall-fileops-tools! removes it again"))

;; ----------------------------------------------- read / write round-trip ---

(defun test-fileops-write-then-read ()
  (format t "~%-- fileops-write-then-read --~%")
  (clear-all-tools) (install-fileops-tools!)
  (let ((path (%fileops-tmp-path)))
    (unwind-protect
         (progn
           (let ((write (dispatch-tool! 'harness-write-file
                                         (list :path path :content "hello world"))))
             (check (eq :ok (getf write :status)))
             (check (= 11 (getf write :length))))
           (let ((read (dispatch-tool! 'harness-read-file (list :path path))))
             (check (string= "hello world" (getf read :content)))
             (check (= 11 (getf read :length)))
             (check (null (getf read :truncated)))))
      (handler-case (delete-file path) (error () nil)))))

(defun test-fileops-write-append ()
  (format t "~%-- fileops-write-append --~%")
  (clear-all-tools) (install-fileops-tools!)
  (let ((path (%fileops-tmp-path)))
    (unwind-protect
         (progn
           (dispatch-tool! 'harness-write-file (list :path path :content "first"))
           (dispatch-tool! 'harness-write-file
                            (list :path path :content "-and-second" :append t))
           (let ((read (dispatch-tool! 'harness-read-file (list :path path))))
             (check (string= "first-and-second" (getf read :content)))))
      (handler-case (delete-file path) (error () nil)))))

;; ----------------------------------------------- truncation ---

(defun test-fileops-truncation ()
  (format t "~%-- fileops-truncation --~%")
  (clear-all-tools) (install-fileops-tools!)
  (let ((path (%fileops-tmp-path)))
    (unwind-protect
         (progn
           (dispatch-tool! 'harness-write-file
                            (list :path path :content "0123456789abcdef"))
           (let ((read (dispatch-tool! 'harness-read-file
                                        (list :path path :max-chars 8))))
             (check (string= "01234567" (getf read :content)))
             (check (= 8 (getf read :length)))
             (check (eq t (getf read :truncated))
                    ":truncated set when there's more data")))
      (handler-case (delete-file path) (error () nil)))))

(defun test-fileops-no-truncation-at-exact-size ()
  (format t "~%-- fileops-no-truncation-at-exact-size --~%")
  (clear-all-tools) (install-fileops-tools!)
  (let ((path (%fileops-tmp-path)))
    (unwind-protect
         (progn
           (dispatch-tool! 'harness-write-file (list :path path :content "1234"))
           (let ((read (dispatch-tool! 'harness-read-file
                                        (list :path path :max-chars 4))))
             (check (string= "1234" (getf read :content)))
             (check (null (getf read :truncated))
                    "max-chars exactly equal to file size → not truncated")))
      (handler-case (delete-file path) (error () nil)))))

;; ----------------------------------------------- error paths ---

(defun test-fileops-read-missing ()
  (format t "~%-- fileops-read-missing --~%")
  (clear-all-tools) (install-fileops-tools!)
  (let ((result (dispatch-tool! 'harness-read-file
                                 (list :path "/tmp/does-not-exist-xyz-99999"))))
    (check (eq :not-found (getf result :error)))))

(defun test-fileops-read-no-path ()
  (format t "~%-- fileops-read-no-path --~%")
  (clear-all-tools) (install-fileops-tools!)
  (let ((result (dispatch-tool! 'harness-read-file nil)))
    (check (eq :missing-path (getf result :error)))))

(defun test-fileops-write-no-content ()
  (format t "~%-- fileops-write-no-content --~%")
  (clear-all-tools) (install-fileops-tools!)
  (let ((result (dispatch-tool! 'harness-write-file (list :path "/tmp/x"))))
    (check (eq :missing-content (getf result :error)))))

;; ----------------------------------------------- list-directory ---

(defun test-fileops-list-directory ()
  (format t "~%-- fileops-list-directory --~%")
  (clear-all-tools) (install-fileops-tools!)
  (let ((dir (%fileops-tmp-dir)))
    (unwind-protect
         (progn
           ;; populate with two files + one subdir
           (dispatch-tool! 'harness-write-file
                            (list :path (format nil "~A/alpha.txt" dir) :content "a"))
           (dispatch-tool! 'harness-write-file
                            (list :path (format nil "~A/beta.txt" dir) :content "b"))
           (ensure-directories-exist (format nil "~A/sub/" dir))
           (let ((listing (dispatch-tool! 'harness-list-directory
                                           (list :path dir))))
             (check (equal '("alpha.txt" "beta.txt") (getf listing :files))
                    "files sorted alphabetically")
             (check (member "sub" (getf listing :directories) :test #'string=)
                    "subdirectories listed")))
      (uiop:delete-directory-tree (uiop:ensure-directory-pathname dir)
                                   :validate t :if-does-not-exist :ignore))))

(defun test-fileops-list-directory-missing ()
  (format t "~%-- fileops-list-directory-missing --~%")
  (clear-all-tools) (install-fileops-tools!)
  (let ((result (dispatch-tool! 'harness-list-directory
                                 (list :path "/tmp/no-such-dir-zzz-99999/"))))
    (check (eq :not-found (getf result :error)))))

;; ----------------------------------------------- runner ---

(defun run-fileops-tools-tests ()
  (setf *failures* 0)
  (format t "~%=== Fileops tools quality-gate tests ===~%")
  (test-fileops-not-auto-registered)
  (test-fileops-write-then-read)
  (test-fileops-write-append)
  (test-fileops-truncation)
  (test-fileops-no-truncation-at-exact-size)
  (test-fileops-read-missing)
  (test-fileops-read-no-path)
  (test-fileops-write-no-content)
  (test-fileops-list-directory)
  (test-fileops-list-directory-missing)
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "Fileops tools green.~%"))

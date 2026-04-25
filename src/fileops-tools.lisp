;;;; fileops-tools.lisp — opt-in file-system tools
;;;;
;;;; Activated by calling (install-fileops-tools!) — these are NOT
;;;; auto-registered. The Spindle reasoner is expected to gate dangerous
;;;; calls via :on-tool-call rules like
;;;;
;;;;   (forbidden harness-write-file "/etc/...")
;;;;   (forbidden harness-read-file "/.ssh/...")
;;;;
;;;; The tool handlers themselves apply NO path sanitisation — gating is
;;;; the reasoner's job, and that's where the audit trail belongs.
;;;;
;;;; HTTP fetch, web search, and shell exec are deliberately out of scope
;;;; for this module — route those through MCP servers or per-project
;;;; tool modules so their schema churn doesn't pin imago to one provider.

(in-package #:anuna-imago)

(defparameter *fileops-max-read-chars* (* 1024 1024)
  "Default upper bound on characters HARNESS-READ-FILE will return.
Override per-call via :max-chars; override globally by SETF-ing this.")

;; ---------------------------------------------------------- handlers ---

(defun %tool-read-file (args)
  (let ((path (getf args :path))
        (max  (or (getf args :max-chars) *fileops-max-read-chars*)))
    (cond
      ((null path) (list :error :missing-path))
      ((not (probe-file path))
       (list :error :not-found :path path))
      (t
       (with-open-file (s path :direction :input :external-format :utf-8)
         (let* ((buf (make-string max))
                (n   (read-sequence buf s))
                (truncated (and (= n max)
                                (peek-char nil s nil nil)
                                t)))
           (list :path      path
                 :length    n
                 :truncated truncated
                 :content   (subseq buf 0 n))))))))

(defun %tool-write-file (args)
  (let ((path    (getf args :path))
        (content (getf args :content))
        (append-p (getf args :append)))
    (cond
      ((null path) (list :error :missing-path))
      ((null content) (list :error :missing-content))
      (t
       (with-open-file (s path :direction :output
                               :external-format :utf-8
                               :if-exists (if append-p :append :supersede)
                               :if-does-not-exist :create)
         (write-sequence content s))
       (list :path path :length (length content) :status :ok)))))

(defun %tool-list-directory (args)
  (let ((path (getf args :path)))
    (cond
      ((null path) (list :error :missing-path))
      ((not (probe-file path))
       (list :error :not-found :path path))
      (t
       (let* ((dir (uiop:ensure-directory-pathname path))
              (files (uiop:directory-files dir))
              (subs  (uiop:subdirectories dir)))
         (list :path path
               :files (sort (mapcar #'file-namestring files) #'string<)
               :directories
               (sort (mapcar (lambda (p)
                               (car (last (pathname-directory p))))
                             subs)
                     #'string<)))))))

;; ---------------------------------------------------------- registration ---

(defun install-fileops-tools! ()
  "Opt-in: register HARNESS-READ-FILE, HARNESS-WRITE-FILE, and
HARNESS-LIST-DIRECTORY. Idempotent — safe to re-call after CLEAR-ALL-TOOLS.

Configure the reasoner before exposing these to an agent. Without
gating, an agent that gets prompt-injected can read or overwrite
anything the harness process has filesystem access to."
  (register-tool!
   (make-tool :name 'harness-read-file
              :description "Read a UTF-8 file. Truncates at :max-chars (default 1048576) and sets :truncated when it would have read more."
              :permission :read
              :schema '((:path :type :string :required-p t
                         :description "Filesystem path to read.")
                        (:max-chars :type :integer :required-p nil
                         :description "Maximum characters to return (default 1048576)."))
              :handler #'%tool-read-file))
  (register-tool!
   (make-tool :name 'harness-write-file
              :description "Write a UTF-8 string to a file. Overwrites by default; pass :append true to append."
              :permission :write
              :schema '((:path :type :string :required-p t
                         :description "Filesystem path to write.")
                        (:content :type :string :required-p t
                         :description "UTF-8 content to write.")
                        (:append :type :boolean :required-p nil
                         :description "If true, append; otherwise overwrite (default nil)."))
              :handler #'%tool-write-file))
  (register-tool!
   (make-tool :name 'harness-list-directory
              :description "List immediate file names and subdirectory names under PATH (sorted)."
              :permission :read
              :schema '((:path :type :string :required-p t
                         :description "Directory path to list."))
              :handler #'%tool-list-directory)))

(defun uninstall-fileops-tools! ()
  "Remove the fileops tools from the registry. Idempotent."
  (unregister-tool! 'harness-read-file)
  (unregister-tool! 'harness-write-file)
  (unregister-tool! 'harness-list-directory))

(defparameter *fileops-tool-names*
  '(harness-read-file harness-write-file harness-list-directory)
  "Names of the opt-in fileops tools. Convenience for agents that want
all of them — call (install-fileops-tools!) first, then list them in
:tools alongside *builtin-tool-names*.")

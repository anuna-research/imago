;;;; plugins/zai/zai.lisp — Z.ai GLM Coding Plan provider plugin
;;;;
;;;; The Z.ai GLM Coding Plan exposes its API in **Anthropic-compatible**
;;;; shape (Messages API, x-api-key auth) — NOT OpenAI-compatible. So this
;;;; plugin is a thin convenience constructor over the existing
;;;; ANTHROPIC-PROVIDER, not a separate driver. The real driver is
;;;; src/providers/anthropic.lisp; we just pre-fill the right endpoint,
;;;; default model, and an opencode-auth.json key reader.
;;;;
;;;; Refs:
;;;;   - https://docs.z.ai/devpack/faq
;;;;   - https://aiengineerguide.com/til/anthropic-api-format-glm-coding-plan/
;;;;
;;;; Available models per Z.ai docs (Apr 2026): glm-5.1, glm-5-turbo,
;;;; glm-4.7, glm-4.5-air. Other names will be rejected by the upstream.
;;;;
;;;; Usage:
;;;;   (ql:quickload :imago/zai)
;;;;   ;; Either pass :api-key directly:
;;;;   (make-zai-coding-provider :api-key "your-z-ai-key" :model "glm-5.1")
;;;;   ;; Or read it from your existing opencode config:
;;;;   (make-zai-coding-provider :api-key (read-opencode-zai-key))
;;;;   ;; Or fall back to ZAI_API_KEY env (handled by anthropic-provider's
;;;;   ;; auth-headers — but it'll look for ANTHROPIC_API_KEY by default,
;;;;   ;; so for env-var use you'd export ANTHROPIC_API_KEY=<your-zai-key>).

(in-package #:anuna-imago)

(defparameter *zai-coding-base-url* "https://api.z.ai/api/anthropic"
  "GLM Coding Plan Anthropic-compatible endpoint. The driver appends
/v1/messages — same path shape as api.anthropic.com.")

(defparameter *zai-default-model* "glm-5.1"
  "Default model. Z.ai accepts glm-5.1, glm-5-turbo, glm-4.7, glm-4.5-air
on the Coding Plan as of Apr 2026.")

(defparameter *zai-opencode-auth-path* "~/.local/share/opencode/auth.json"
  "Default location of opencode's auth.json — a JSON object keyed by
provider slug, e.g. {\"zai-coding-plan\": {\"type\": \"api\", \"key\": \"…\"}}.
Operators with a different opencode install can pass :path to
READ-OPENCODE-ZAI-KEY directly.")

(defun read-opencode-zai-key (&key (path *zai-opencode-auth-path*)
                                    (slug "zai-coding-plan"))
  "Read SLUG's API key out of an opencode auth.json file. Returns the
key string, or NIL if the file or slug is missing.

The format opencode writes is:
  { \"<slug>\": { \"type\": \"api\", \"key\": \"<key>\" }, … }
We don't validate the type; we just plumb the :key field."
  (let ((expanded (uiop:native-namestring (translate-logical-pathname
                                            (merge-pathnames path)))))
    (handler-case
        (let* ((bytes (uiop:read-file-string expanded))
               (parsed (com.inuoe.jzon:parse bytes))
               (entry  (and (hash-table-p parsed)
                            (gethash slug parsed))))
          (when (hash-table-p entry)
            (gethash "key" entry)))
      (error () nil))))

(defun make-zai-coding-provider (&key api-key model base-url max-tokens
                                       opencode-slug)
  "Build an ANTHROPIC-PROVIDER configured for the Z.ai GLM Coding Plan.

Resolution order for :api-key:
  1. :api-key arg (if given)
  2. (read-opencode-zai-key :slug OPENCODE-SLUG) when :opencode-slug is
     non-nil — defaults to NIL (no opencode read by default).
  3. anthropic-provider's own ANTHROPIC_API_KEY env-var fallback (deferred
     to request-time inside auth-headers).

Defaults:
  :base-url   → \"https://api.z.ai/api/anthropic\"
  :model      → \"glm-5.1\"
  :max-tokens → inherits anthropic-provider default (4096).

Other Coding Plan models: \"glm-5-turbo\", \"glm-4.7\", \"glm-4.5-air\"."
  (let ((resolved-key (or api-key
                          (and opencode-slug
                               (read-opencode-zai-key :slug opencode-slug)))))
    (apply #'make-anthropic-provider
           (append (when resolved-key (list :api-key resolved-key))
                   (list :base-url (or base-url *zai-coding-base-url*))
                   (list :model    (or model    *zai-default-model*))
                   (when max-tokens (list :max-tokens max-tokens))))))

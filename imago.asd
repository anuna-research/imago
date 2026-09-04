;;;; imago.asd — ASDF system definition for anuna-imago
;;;;
;;;; The system grows milestone by milestone (see plan.spl).
;;;; Total budget ~1830 LOC excluding tests.

(defsystem #:imago
  :name "imago"
  :description "anuna-imago: minimal hackable agent harness on SBCL — 2k LOC variant of SPEC-011"
  :version "0.1.0"
  :author "Hugo O'Connor <hugo.oconnor@gmail.com>"
  :license "Apache-2.0"
  :homepage "https://codeberg.org/anuna/anuna-imago"
  :source-control (:git "https://codeberg.org/anuna/anuna-imago.git")
  :depends-on (#:dexador #:com.inuoe.jzon #:cffi #:cffi-libffi
                ;; M7 production transport: websocket-driver wraps
                ;; handshake + framing (provides the WSD package with
                ;; the wsd: nickname covering client + on/send/close).
                #:websocket-driver
                ;; Ed25519 keypairs + signatures for did:key identity.
                #:ironclad)
  :components
  ((:module "src"
    :components ((:file "packages")
                 (:file "mailbox"    :depends-on ("packages"))
                 (:file "supervisor" :depends-on ("packages" "mailbox"))
                 (:file "agent"      :depends-on ("packages" "mailbox"))
                 (:file "hooks"      :depends-on ("packages" "mailbox"))
                 (:file "tools"      :depends-on ("packages"))
                 (:file "receipt-log" :depends-on ("packages"))
                 (:file "builtin-tools" :depends-on ("packages" "agent" "tools"
                                                     "hooks" "receipt-log"
                                                     "save-image" "reasoner"
                                                     "main"))
                 (:file "fileops-tools" :depends-on ("packages" "tools"))
                 (:file "cbcl-ffi"   :depends-on ("packages"))
                 (:file "turn-loop"  :depends-on ("packages" "agent" "mailbox"
                                                  "hooks" "tools"))
                 (:file "gateway"    :depends-on ("packages" "mailbox" "agent"
                                                  "turn-loop" "receipt-log"
                                                  "identity"))
                 (:file "wss-transport"
                                     :depends-on ("packages" "mailbox" "gateway"))
                 (:file "producer-gateway"
                                     :depends-on ("packages" "mailbox" "gateway"))
                 (:file "reasoner"   :depends-on ("packages" "hooks" "save-image"))
                 (:module "providers"
                  :depends-on ("packages" "turn-loop" "tools" "save-image")
                  :components ((:file "stub")
                               (:file "anthropic"  :depends-on ("stub"))))
                 ;; OpenRouter is shipped as a plugin — see imago/openrouter
                 ;; sub-system below. Not loaded by default.
                 (:file "save-image" :depends-on ("packages" "hooks"
                                                   "receipt-log"))
                 (:file "identity"   :depends-on ("packages" "receipt-log"
                                                   "save-image"))
                 ;; gateway depends on identity so %make-auth-frame can
                 ;; dispatch on AGENT-IDENTITY vs bearer-string.
                 (:file "main"       :depends-on ("packages" "supervisor"
                                                   "agent" "turn-loop"
                                                   "providers" "save-image"))
                 ;; SPEC-012 self-modification port (scaffolded; tool itself
                 ;; is registered explicitly by examples/self-modifying.lisp,
                 ;; NOT loaded here, per REQ-001 / REQ-012).
                 (:file "self-modification" :depends-on ("packages" "tools"
                                                          "hooks" "reasoner"
                                                          "receipt-log"
                                                          "save-image"))))
   ;; examples/self-modifying.lisp is intentionally NOT registered as an ASDF
   ;; component — loading the system MUST NOT install the harness-eval tool
   ;; (REQ-001). Authors who want self-modification load the file explicitly.
   (:module "examples"
    :depends-on ("src")
    :components ((:file "echo")))))

(defsystem #:imago/test
  :name "imago/test"
  :description "anuna-imago test harness"
  :version "0.1.0"
  :license "Apache-2.0"
  :depends-on (#:imago
                ;; M7-WSS test wants a local WebSocket echo server.
                #:clack #:clack-handler-hunchentoot)
  :components
  ((:module "test"
    :components ((:file "m1-tests")
                 (:file "m2-tests" :depends-on ("m1-tests"))
                 (:file "m3-tests" :depends-on ("m1-tests"))
                 (:file "m4-tests" :depends-on ("m1-tests"))
                 (:file "m5-tests" :depends-on ("m1-tests"))
                 (:file "m6-tests" :depends-on ("m1-tests"))
                 (:file "m7-tests" :depends-on ("m1-tests"))
                 (:file "m7-wss-tests" :depends-on ("m1-tests"))
                 (:file "m7-producer-tests" :depends-on ("m1-tests"))
                 (:file "m8-tests" :depends-on ("m1-tests"))
                 (:file "m9-tests" :depends-on ("m1-tests"))
                 (:file "m10-tests" :depends-on ("m1-tests"))
                 (:file "m11-tests" :depends-on ("m1-tests"))
                 (:file "builtin-tools-tests" :depends-on ("m1-tests"))
                 (:file "fileops-tools-tests" :depends-on ("m1-tests"))
                 (:file "identity-tests" :depends-on ("m1-tests"))
                 (:file "m12-tests" :depends-on ("m1-tests"))))))

;; ---------------------------------------------------------------------------
;; Plugins — opt-in subsystems. Load via (ql:quickload :imago/<plugin>) or
;; (asdf:load-system :imago/<plugin>). Not pulled in by the main :imago
;; system — these are explicit imports for capabilities that don't belong
;; in the core 2k LOC harness.
;; ---------------------------------------------------------------------------

(defsystem #:imago/openrouter
  :name "imago/openrouter"
  :description "OpenRouter (OpenAI-compatible) provider driver for imago — opt-in plugin. Use any OpenRouter-served model (GLM, GPT, Gemini, Mistral, Qwen, …) by passing its slug as :model."
  :version "0.1.0"
  :license "Apache-2.0"
  :depends-on (#:imago)
  :components ((:module "plugins/openrouter"
                :components ((:file "openrouter")))))

(defsystem #:imago/openrouter/test
  :name "imago/openrouter/test"
  :description "Test suite for the OpenRouter plugin. Stubbed HTTP — no live API key needed."
  :version "0.1.0"
  :license "Apache-2.0"
  :depends-on (#:imago/openrouter #:imago/test)
  :components ((:module "plugins/openrouter"
                :components ((:file "test")))))

(defsystem #:imago/zai
  :name "imago/zai"
  :description "Z.ai GLM Coding Plan provider plugin — thin wrapper over imago's existing anthropic-provider, since the Coding Plan exposes Anthropic-compatible Messages API. Includes an opencode auth.json key reader."
  :version "0.1.0"
  :license "Apache-2.0"
  :depends-on (#:imago)
  :components ((:module "plugins/zai"
                :components ((:file "zai")))))

(defsystem #:imago/zai/test
  :name "imago/zai/test"
  :description "Test suite for the Z.ai Coding Plan plugin. Stubbed HTTP."
  :version "0.1.0"
  :license "Apache-2.0"
  :depends-on (#:imago/zai #:imago/test)
  :components ((:module "plugins/zai"
                :components ((:file "test")))))

(defsystem #:imago/evolution/test
  :name "imago/evolution/test"
  :description "SPEC-014 Red Gate for the optional harness evolution control plane."
  :version "0.1.0"
  :license "Apache-2.0"
  ;; Deliberately do not depend on IMAGO/EVOLUTION.  The test file must load
  ;; while the production subsystem is absent, then request it dynamically.
  :depends-on (#:imago/test)
  :components ((:module "plugins/evolution"
                :components ((:file "test")))))

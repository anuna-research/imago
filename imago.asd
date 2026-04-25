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
  :depends-on (#:dexador #:com.inuoe.jzon)  ; M8 deps; load-time only when used.
  :components
  ((:module "src"
    :components ((:file "packages")
                 (:file "mailbox"    :depends-on ("packages"))
                 (:file "supervisor" :depends-on ("packages" "mailbox"))
                 (:file "agent"      :depends-on ("packages" "mailbox"))
                 (:file "hooks"      :depends-on ("packages" "mailbox"))
                 (:file "tools"      :depends-on ("packages"))
                 (:file "receipt-log" :depends-on ("packages"))
                 (:file "turn-loop"  :depends-on ("packages" "agent" "mailbox"
                                                  "hooks" "tools"))
                 (:module "providers"
                  :depends-on ("packages" "turn-loop" "tools" "save-image")
                  :components ((:file "stub")
                               (:file "anthropic" :depends-on ("stub"))))
                 (:file "save-image" :depends-on ("packages" "hooks"
                                                   "receipt-log"))
                 (:file "main"       :depends-on ("packages" "supervisor"
                                                   "agent" "turn-loop"
                                                   "providers" "save-image"))))
   (:module "examples"
    :depends-on ("src")
    :components ((:file "echo")))))

(defsystem #:imago/test
  :name "imago/test"
  :description "anuna-imago test harness"
  :version "0.1.0"
  :license "Apache-2.0"
  :depends-on (#:imago)
  :components
  ((:module "test"
    :components ((:file "m1-tests")
                 (:file "m2-tests" :depends-on ("m1-tests"))
                 (:file "m3-tests" :depends-on ("m1-tests"))
                 (:file "m4-tests" :depends-on ("m1-tests"))
                 (:file "m5-tests" :depends-on ("m1-tests"))
                 (:file "m8-tests" :depends-on ("m1-tests"))
                 (:file "m9-tests" :depends-on ("m1-tests"))))))

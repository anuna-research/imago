;;;; packages.lisp — package definitions

(in-package #:cl-user)

(defpackage #:anuna-imago
  (:nicknames #:imago)
  (:use #:cl)
  (:export
   ;; --- M0 ---
   #:agent-main
   #:*version*

   ;; --- M1 / mailbox ---
   #:mailbox
   #:make-mailbox
   #:send!
   #:receive!
   #:peek-mailbox
   #:mailbox-depth
   #:close-mailbox!

   ;; --- M1 / supervisor ---
   #:supervisor
   #:make-supervisor
   #:add-child!
   #:start-supervisor!
   #:drain-supervisor!
   #:list-children
   #:child-state-of
   #:force-restart!
   #:sup-state

   ;; --- M1 / agent ---
   #:agent
   #:agent-id
   #:agent-capability
   #:agent-mailbox
   #:agent-supervisor
   #:agent-provider
   #:agent-tools
   #:agent-system-prompt
   #:agent-theory
   #:agent-state
   #:agent-identity-slot
   #:agent-did
   #:*current-agent*
   #:turn-loop
   #:handle-message
   #:on-spawn
   #:on-shutdown

   ;; --- M2 / hooks ---
   #:*hook-keys*
   #:*excluded-hook-keys*
   #:register-hook
   #:remove-hook
   #:run-hook
   #:list-hooks
   #:clear-all-hooks
   #:shutdown-hook-async-pool

   ;; --- M3 / tools ---
   #:tool
   #:tool-name
   #:tool-description
   #:tool-permission
   #:tool-schema
   #:tool-handler
   #:make-tool
   #:define-tool
   #:register-tool!
   #:unregister-tool!
   #:find-tool
   #:list-tools
   #:clear-all-tools
   #:dispatch-tool!
   #:schema->json-schema
   #:json-schema->schema
   #:tool->anthropic-descriptor
   #:*valid-permissions*
   #:*valid-param-types*

   ;; --- M4 / turn-loop + provider abstraction ---
   #:provider
   #:provider-name
   #:provider-stream!
   #:stream-next-frame!
   #:make-ask
   #:ask-message-p
   #:ask-content
   #:ask-reply-to
   #:make-reply
   #:process-turn
   #:drive-stream
   #:spawn-agent!
   #:ask-agent

   ;; --- M4 / stub provider ---
   #:stub-provider
   #:make-stub-provider
   #:stub-responder

   ;; --- M4 / echo example ---
   #:build-echo-agent
   #:run-echo-demo

   ;; --- M5 / receipt log ---
   #:receipt-log
   #:receipt-log-path
   #:open-receipt-log
   #:close-receipt-log!
   #:append-receipt!
   #:read-receipts
   #:content-hash
   #:iso-8601-now

   ;; --- M9 / image distribution ---
   #:save-image!
   #:pre-save-clean!
   #:*clean-checklist*
   #:register-credential-eraser!
   #:register-receipt-log-for-clean!

   ;; --- M8 / anthropic provider ---
   #:anthropic-provider
   #:make-anthropic-provider
   #:anthropic-api-key
   #:anthropic-model
   #:anthropic-base-url
   #:anthropic-max-tokens
   #:anthropic-version
   #:build-request
   #:auth-headers
   #:*anthropic-http-post*

   ;; --- M6 / cbcl FFI ---
   #:*cbcl-ffi-library-path*
   #:ensure-cbcl-ffi-loaded
   #:parse-message
   #:verify-dialect
   #:message-canonical-p

   ;; --- M7 / gateway ---
   #:gateway
   #:make-gateway
   #:gateway-id
   #:gateway-transport
   #:gateway-state
   #:gateway-agent
   #:gateway-capability
   #:gateway-connect!
   #:gateway-start-pumps!
   #:gateway-disconnect!
   #:gateway-reply-mailbox
   #:transport-open!
   #:transport-send!
   #:transport-recv!
   #:transport-close!
   #:transport-connected-p
   #:mock-transport
   #:make-mock-transport
   #:mock-feed!
   #:mock-drain!
   ;; M7 production transport
   #:wss-transport
   #:make-wss-transport
   #:wss-transport-url
   #:wss-transport-headers
   #:*wss-open-timeout-seconds*

   ;; --- Identity (did:key, Ed25519) ---
   #:agent-identity
   #:generate-identity
   #:identity-did
   #:identity-public-key
   #:identity-public-key-bytes
   #:identity-private-key
   #:encode-did-key
   #:parse-did-key
   #:sign-bytes
   #:sign-string
   #:verify-bytes
   #:verify-signature
   #:bytes->hex
   #:hex->bytes
   #:base58btc-encode
   #:base58btc-decode
   #:make-did-auth-frame
   #:make-did-auth-payload
   #:clear-identity-private-key!
   #:register-identity-for-clean!

   ;; --- Producer gateway (cross-process composition) ---
   #:producer-gateway
   #:make-producer-gateway
   #:producer-gateway-id
   #:producer-gateway-transport
   #:producer-gateway-identity
   #:producer-state
   #:producer-heartbeat-interval
   #:producer-connect!
   #:producer-start-pumps!
   #:producer-disconnect!
   #:producer-ask!
   #:producer-call!
   #:producer-in-flight-count

   ;; --- Built-in tools (post-spec; introspection only) ---
   #:install-builtin-tools!
   #:*builtin-tool-names*
   #:*boot-time*
   #:harness-list-tools
   #:harness-describe-tool
   #:harness-list-hooks
   #:harness-version
   #:harness-now
   #:harness-describe-agent
   #:harness-query-receipts
   #:harness-uuid
   #:harness-stats
   #:harness-query-theory

   ;; --- Opt-in fileops tools ---
   #:install-fileops-tools!
   #:uninstall-fileops-tools!
   #:*fileops-tool-names*
   #:*fileops-max-read-chars*
   #:harness-read-file
   #:harness-write-file
   #:harness-list-directory

   ;; --- M10 / reasoner ---
   #:*reasoner-ipc-call*
   #:*active-theory-handle*
   #:load-theory
   #:query
   #:what-if
   #:why-not
   #:assert-fact!
   #:retract-fact!
   #:proof-result-positive-p
   #:invariant-filter-hook
   #:install-invariant-filter!
   #:uninstall-invariant-filter!

   ;; --- SPEC-012 / self-modification port ---
   ;; Pre-filter (CON-002) + amendment A1 / A2 from ADR-012.
   #:*prefilter-denylist*
   #:%harness-eval-prefilter
   ;; Lift function (CON-003).
   #:%lift-form
   ;; Safety-layer symbol set (ADR-012 §A1, generalised over CON-003).
   #:*safety-layer-symbols*
   ;; Receipt (CON-004) — separate audit log instance for harness-eval.
   #:*harness-eval-audit-log*
   #:%tool-receipt!
   ;; Origin index (CON-005).
   #:*redefine-history*
   #:redefine-history
   #:last-redefinition
   #:all-redefined-symbols
   ;; Rollback register (CON-006 + ADR-013 OQ-004 union shape).
   #:*rollback-register*
   #:rollback!
   #:rollback-records
   #:find-rollback-records-for
   ;; Handler (CON-001).
   #:%harness-eval-handler
   ;; Bounds for result serialisation (ADR-013 OQ-003).
   #:*harness-eval-result-truncate-bytes*
   ;; Tool registration (REQ-001) — installed from examples/self-modifying.lisp.
   #:install-self-modification-tools!
   #:uninstall-self-modification-tools!
   #:*self-modification-tool-names*))

# `:clean t` checklist — what gets flushed at save time

Per CON-008 (SPEC-011) and the SPEC-011 review feedback, the `:clean t`
flag on `save-image!` must have a defined, auditable meaning. This file
mirrors the checklist that lives in code at `*clean-checklist*` in
`src/save-image.lisp` — keep them in sync.

## What `:clean t` flushes (in order)

| Step                       | Why                                                                 |
| -------------------------- | ------------------------------------------------------------------- |
| `:close-receipt-log`       | In-progress writes must hit disk and the file handle must close, otherwise the saved heap holds a half-written receipt and a stale FD. Receipt logs opt in via `register-receipt-log-for-clean!` (M5). |
| `:shutdown-hook-async-pool` | Fire-and-forget worker threads must not survive into the saved image; they hold no useful state and confuse the supervisor on boot. |
| `:drop-credentials`        | Modules that loaded API keys, vault tokens, auth bearer material, or **Ed25519 private keys** from env or constructor args must zero those slots before save. Each module registers a credential-erasing thunk via `register-credential-eraser!` at first use. |
| `:force-gc`                | A full GC before save reclaims any objects freed by the steps above. Per NFR-002 (`<= 60 MB minimal`, `<= 100 MB full`), this matters for image size. |

## Modules that wire the credential eraser

| Module                            | What it clears                                                 | Registered when                          |
| --------------------------------- | -------------------------------------------------------------- | ---------------------------------------- |
| `providers/anthropic.lisp` (M8)   | `api-key` slot on `anthropic-provider`                         | First `make-anthropic-provider` call     |
| `reasoner.lisp` (M10)             | `*active-theory-handle*`                                       | `install-invariant-filter!`              |
| `identity.lisp` (post-spec, did:key) | `private-key` slot on `agent-identity`                       | Caller invokes `register-identity-for-clean!`  |

## What `:clean t` does NOT flush (intentional)

- **Loaded code**. The whole point of saving the image is that compiled
  functions, CLOS classes, and macros come along.
- **Tool registry**. Author-defined tools live in the heap by design —
  the saved image *is* the customised agent.
- **Hook registry** (excluding the async worker pool). Static handler
  registrations are part of the customisation. Only the async worker
  threads are killed; they restart lazily on first fire-and-forget after
  boot.
- **Theory handle reference** itself. A loaded Spindle theory definition
  is part of the agent's static state — it's the *handle pointer* (which
  may carry an IPC socket fd in some configurations) that's released.
- **Public keys / DIDs**. The Ed25519 *public* key and its DID are kept;
  only the private key is zeroed. The image still knows who it claims
  to be — it just can't sign any more until a fresh keypair is loaded
  at boot time (typical pattern: read seed material from env, regenerate
  the keypair, re-attach to the existing agent-identity object).

## What an operator should verify after `:clean t`

After producing an image, the audit gate (acceptance for M9, extended
post-spec for identity) is:

1. **Size**: `ls -lh ./image` ≤ 60 MB minimal, ≤ 100 MB full agent. The
   "full agent" profile bundles dexador, jzon, websocket-driver, cl+ssl,
   ironclad, cffi — typically ~63 MB for a single-provider image.
2. **No plaintext secrets**:
   `strings ./image | grep -E '(sk-[A-Za-z0-9]{20,}|Bearer [A-Za-z0-9]{20,})'`
   returns nothing.
3. **No Ed25519 private-key material**: heuristic — `strings ./image`
   should not contain a 64-byte hex string adjacent to a stored DID.
   Cleaner check: load the image, inspect `(identity-private-key
   <every-known-identity>)`, all NIL.
4. **No in-flight receipts**: `strings ./image | grep -F ':status :received'`
   returns nothing.
5. **Boot to ready** within NFR-001 budget: `time ./image --version`
   ≤ 200 ms p95.

If any check fails, `:clean t` was incomplete — extend `*clean-checklist*`
in `src/save-image.lisp`, register a new credential-eraser thunk where
the secret is owned, and add the module to the table above.

## How modules opt in

A module that owns flushable state (open file handles, secrets, network
connections, **private keys**) should call `register-credential-eraser!`
or `register-receipt-log-for-clean!` at first-use, NOT at load time.

```lisp
;; Example from src/identity.lisp:
(defun register-identity-for-clean! (identity)
  (register-credential-eraser!
   (lambda () (clear-identity-private-key! identity)))
  identity)
```

This keeps the eraser registry empty in pristine images (an image saved
without ever instantiating a provider has no api-key eraser registered)
and only populated when the running agent has actually loaded those
resources.

## Related

- [`src/save-image.lisp`](../src/save-image.lisp) — code form of the
  checklist; the function `pre-save-clean!` walks `*clean-checklist*`.
- [`src/identity.lisp`](../src/identity.lisp) — `register-identity-for-clean!`
  and the symmetric `clear-identity-private-key!`.
- [`ADR-002-identity.md`](./ADR-002-identity.md) — why agents have
  cryptographic identity at all.
- SPEC-011 §"Open questions" item 4 — the original gap this file closes.
- Review feedback "`:clean t` semantics undefined yet load-bearing" —
  addressed by this file.

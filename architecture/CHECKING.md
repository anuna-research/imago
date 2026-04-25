# `:clean t` checklist — what gets flushed at save time

Per CON-008 (SPEC-011) and the SPEC-011 review feedback, the `:clean t`
flag on `save-image!` must have a defined, auditable meaning. This file
mirrors the checklist that lives in code at `*clean-checklist*` in
`src/save-image.lisp` — keep them in sync.

## What `:clean t` flushes (in order)

| Step                      | Why                                                                 |
| ------------------------- | ------------------------------------------------------------------- |
| `:close-receipt-log`      | In-progress writes must hit disk and the file handle must close, otherwise the saved heap holds a half-written receipt and a stale FD. Receipt logs register themselves via `register-receipt-log-for-clean!` (M5+). |
| `:shutdown-hook-async-pool` | Fire-and-forget worker threads must not survive into the saved image; they hold no useful state and confuse the supervisor on boot. |
| `:drop-credentials`       | Modules that loaded API keys, vault tokens, or auth bearer material from env must zero those slots before save. Each module registers a credential-erasing thunk via `register-credential-eraser!`. M8 (Anthropic) will register its api-key clear; M7 (gateway) will register its bearer token clear. |
| `:force-gc`               | A full GC before save reduces image size by reclaiming any objects freed by the steps above. Per NFR-002 (`<= 60 MB minimal`, `<= 100 MB full`), the GC matters. |

## What `:clean t` does NOT flush (intentional)

- **Loaded code**. The whole point of saving the image is that compiled
  functions, CLOS classes, and macros come along.
- **Tool registry**. Author-defined tools live in the heap by design —
  the saved image *is* the customised agent.
- **Hook registry** (excluding async pool). Static handler registrations
  are part of the customisation. Only the async worker threads are killed
  (they restart lazily on first fire-and-forget after boot).
- **Theory handles** (M10+). A loaded Spindle theory is part of the
  agent. Open IPC connections to spindle-rs are not — those will register
  for clean separately when M10 lands.

## What an operator should verify after `:clean t`

After producing an image, the audit gate (acceptance for M9) is:

1. **Size**: `ls -lh ./image` ≤ 60 MB minimal, ≤ 100 MB full.
2. **No plaintext secrets**: `strings ./image | grep -E '(sk-|Bearer )'` returns nothing.
3. **No in-flight receipts**: `strings ./image | grep -F '"status":"received"'` (or
   the s-expression equivalent for our line-oriented log) returns nothing.
4. **Boot to ready** within NFR-001 budget: `time ./image --version` ≤ 200 ms P95.

If any check fails, `:clean t` was incomplete — extend `*clean-checklist*`
in `src/save-image.lisp` and document the addition here.

## How modules opt in

A module that owns flushable state (open file handles, secrets, network
connections) should call `register-credential-eraser!` or
`register-receipt-log-for-clean!` at first-use, NOT at load time. This
keeps the registry empty in pristine images and only populated when the
running agent has actually loaded those resources.

## Related

- `src/save-image.lisp` — code form of the checklist.
- SPEC-011 §"Open questions" item 4 — the original gap this file closes.
- Review feedback `:clean t semantics undefined yet load-bearing` — addressed by this file.

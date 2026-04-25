---
id: ADR-001
title: SBCL as the image runtime
status: accepted
date: 2026-04-25
---

# ADR-001 — SBCL as the image runtime

## Decision

The harness runs on **SBCL (Steel Bank Common Lisp)** as its sole CL implementation. The image-distribution story is `sb-ext:save-lisp-and-die`; the live-debug story is `swank`; the optimization-primitives story (deferred to v2) is `sb-posix:fork`.

## Context

SPEC-011 (open question 1) leaves SBCL vs ECL undecided. The 2k-LOC variant resolves it: SBCL.

## Why SBCL and not ECL

- **Optimiser quality**: SBCL's native compiler is the strongest in the open CL ecosystem. The harness will run hot loops in turn-loop and gateway; performance matters.
- **`save-lisp-and-die` mmap semantics**: SBCL's image format is mmap'd at boot, hitting the NFR-001 cold-start budget (≤ 200 ms P95). ECL has no equivalent.
- **Mature `sb-posix`**: the optimization-primitives roadmap (deferred but planned) uses `sb-posix:fork` for cheap COW variants. ECL's POSIX surface is thinner.
- **Ecosystem parity**: bordeaux-threads, dexador, websocket-driver, cffi, jzon, ironclad — all tested first against SBCL.

## What this commits us to

- **Unix only**: `sb-posix:fork` is a hard POSIX dep (when optimization arrives). Windows is architecturally excluded; this is a deliberate boundary, not an oversight.
- **No embedding**: ECL's main differentiator is being embeddable in a host process. We give that up. The image *is* the host process.
- **Implementation-named primitives in NFRs**: NFR-007 explicitly references `sb-posix:fork`. If we ever switch implementations, that NFR — and the entire optimization-primitives story — has to be revisited. Current bet: we won't.

## What this does *not* commit us to

The CL surface of the harness (`defpackage`, `defclass`, `defmethod`, `defmacro`, `defgeneric`) is portable. Only the implementation-specific primitives (`sb-ext:save-lisp-and-die`, `sb-posix:fork`, `swank`) bind us to SBCL. If a future port to ECL or CCL becomes desirable, those primitives are localised and replaceable.

## References

- SPEC-011 §"Open questions" item 1
- SPEC-011 NFR-001, NFR-007
- SBCL manual §"Saving a Core Image"

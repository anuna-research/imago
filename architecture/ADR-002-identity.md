---
id: ADR-002
title: Agents have did:key cryptographic identity
status: accepted
date: 2026-04-26
---

# ADR-002 — Agents have did:key cryptographic identity

## Decision

Every agent that needs to authenticate to a CBCL router or sign messages
carries an **`agent-identity`** — an Ed25519 keypair plus the W3C
[did:key](https://w3c-ccg.github.io/did-method-key/) DID derived from
its public key.

Implementation: `src/identity.lisp`, ~190 LOC. Backed by `ironclad`
(Ed25519 sign/verify) and a hand-rolled base58btc codec.

## Context

Two pressures converged:

1. **CBCL's R4 invariant.** The protocol spec mandates Ed25519
   signatures on every message. Until this ADR, the harness was
   producing unsigned frames — the producer-gateway shipped with
   `(produce <rid> <cap> <body>)` plaintext. Any router that started
   enforcing R4 would reject every send.
2. **Agent attribution.** Receipt logs, hook decisions, and reasoner
   queries all reference an `agent-id`. Until this ADR that was a CL
   symbol — claimed identity, not provable identity. `:on-tool-call`
   could not distinguish "agent-A asks me to delete a user" from "an
   attacker who guessed agent-A's name asks me to delete a user."

Both gaps point at the same fix: cryptographic identity.

## Why did:key specifically

Three viable W3C DID methods were considered:

| Method     | Resolution             | Trade                                                                |
| ---------- | ---------------------- | -------------------------------------------------------------------- |
| **did:key**| None — DID encodes pubkey | Self-contained, no network, ~30 LOC encoder                       |
| did:web    | HTTPS GET              | Requires hosting, mutable, adds HTTP dep on resolver                 |
| did:plc    | Resolver service       | Mutable + recoverable (Bluesky pattern), external dep                |

did:key wins on every axis the SPEC-011 stance cares about:

- **No central authority.** The identifier *is* the public key. No
  registry, no resolver, no DNS dependency.
- **No network.** Verification is `parse-did-key` + Ed25519
  `verify-signature`. Both CPU-bound, both done in microseconds.
- **No frozen abstractions.** A 32-byte public key wrapped in
  multicodec + multibase has been a stable W3C primitive since 2019.
  Unlikely to age out.
- **Cheap to implement.** ~30 LOC of base58btc, ~10 LOC of multicodec
  prefixing, the rest is ironclad calls.

did:web and did:plc can be added later as ~50 LOC method handlers behind
the same `verify-signature did string sig` surface if any deployment
needs them. None do today.

## What we ship

- **`generate-identity` → `agent-identity`** — fresh Ed25519 keypair,
  derived DID. Public key bytes are accessible via
  `identity-public-key-bytes`; the private key lives in a mutable slot
  so `:clean t` can zero it.
- **`encode-did-key` / `parse-did-key`** — bidirectional, lossless. The
  multicodec prefix is `0xed01` (varint-encoded `ed25519-pub`); the
  multibase prefix is `z` (base58btc).
- **`sign-string` / `verify-signature`** — UTF-8-aware wrappers around
  `ironclad:sign-message` / `ironclad:verify-signature`. 64-byte
  signatures, 32-byte public keys, deterministic.
- **`(make-did-auth-frame identity)`** — builds the
  `(auth-did <DID> <iso-ts> <hex-sig>)` wire frame. The signature
  payload is `"<DID> <timestamp>"`; the receiver verifies the
  signature is from the DID over that exact string with the
  timestamp in a replay window.
- **Polymorphic `%make-auth-frame`** in `src/gateway.lisp` —
  dispatches on the gateway's `:identity` slot. Bearer-string →
  `(auth …)` (legacy); `agent-identity` → `(auth-did …)`. No call-site
  change for either gateway flavour.
- **`register-identity-for-clean!`** — wires the credential-eraser
  registry from M9. `pre-save-clean!` zeros the private key before
  `save-image!` so deployments don't leak signing material.

## What this commits us to

- **`ironclad` as a Quicklisp dep.** Well-maintained, used everywhere
  in the CL ecosystem, ~30 KLOC of borrowed crypto code. Image grows
  by ~6 MB (57 → 63 MB) with it bundled.
- **Ed25519 as the keypair algorithm.** The W3C did:key registry
  supports several curves (P-256, secp256k1, BLS12-381 G1/G2, X25519
  for KEM). We picked Ed25519 because: (a) standard for signatures,
  (b) what cbcl-rs / cbcl-lfe-router will eventually verify against,
  (c) Bluesky-tested at scale via did:plc.
- **The DID auth handshake protocol.** `(auth-did <DID> <ts> <sig>)`
  is our specific wire shape — the spec didn't pin one. cbcl-rs and
  cbcl-lfe-router will need a parallel implementation. Until then this
  is one-sided: the imago client signs, no router verifies.
- **The receiver-gateway / producer-gateway dispatch.** Both pick up
  the new behaviour through their existing `:identity` slot, by
  construction: pass an `agent-identity` instead of a string and the
  frame shape changes.

## What this does NOT yet do

- **R4 frame-level signing** is not in this commit. Every `(produce …)`
  and `(reply …)` frame still goes out unsigned. Closing the rest of
  the R4 gap needs cbcl-rs to expose its canonical-envelope-with-sig
  format over the FFI; that's a parallel commit on the Rust crate.
- **No nonce challenge.** The auth handshake signs `<DID> <timestamp>`,
  not a router-issued nonce. Replay protection comes from a tight
  timestamp window (default ±60s in any router that enforces it).
  Adding a nonce is a one-message round-trip change later.
- **No identity rotation / revocation.** A compromised private key
  means a fresh `generate-identity` call and a new agent. did:web /
  did:plc would let us mutate the identity in place; did:key
  fundamentally cannot. This is fine for v0.1 — agents are short-lived
  per image — but worth flagging if longer-lived identities ever
  become a need.

## What this does NOT commit us to

- **Hosting a DID resolver.** did:key needs none.
- **A central CA or trust root.** Self-sovereign identity by
  construction.
- **An identity-issuance ceremony.** `(generate-identity)` is a single
  function call. Authors who want a stable identity across image
  rebuilds load the same seed material from env or a file at boot
  time and pass it to `make-instance` of `agent-identity` (left as
  user code; the harness doesn't ship a seed-loader).

## References

- [W3C did:key Method Specification](https://w3c-ccg.github.io/did-method-key/)
- [W3C DID Core 1.0](https://www.w3.org/TR/did-core/)
- [Multicodec table](https://github.com/multiformats/multicodec) —
  `0xed01` for `ed25519-pub`
- [Ed25519 (RFC 8032)](https://www.rfc-editor.org/rfc/rfc8032)
- [`src/identity.lisp`](../src/identity.lisp) — implementation
- [`src/gateway.lisp`](../src/gateway.lisp) `%make-auth-frame` —
  polymorphic dispatch
- [`architecture/CHECKING.md`](./CHECKING.md) — `:clean t` integration
  for private-key zeroing
- SPEC-011 R4 — the upstream invariant this implementation supports

# Observability signals (OBS-### entries)

Metrics, logs, and traces emitted by the [[SPEC-013-skill-definition-port|skill definition port]]. Each signal has a concrete specification (name, type, labels, emission point).

---

## OBS-001: Boot-time discovery duration

- **Type:** histogram (gauge per boot is also acceptable for v0.1).
- **Name:** `imago.skill.discover.duration_ms`.
- **Labels:** `root` (path), `skill_count` (integer).
- **Emission point:** `discover-skills!` end. One emission per root, one aggregate emission for the whole boot.
- **Verifies:** [[#NFR-001]].
- **Receipt-log dialect:** `imago.skill.boot` with body `(:duration-ms … :roots ((:root … :count … :duration-ms …) …))`.

---

## OBS-002: `harness-define-skill` invocation timing and outcome

- **Type:** histogram + counter.
- **Name:** `imago.skill.define.duration_ms` (histogram), `imago.skill.define.count` (counter).
- **Labels:** `outcome` (`ok` | `rejected:<rule>` | `error`), `agent_id`.
- **Emission point:** `harness-define-skill` handler exit, before returning to the turn loop.
- **Verifies:** [[#NFR-002]], [[#REQ-002]].
- **Receipt-log dialect:** `imago.skill.define` with body `(:name … :outcome … :duration-ms … :body-bytes …)`.

---

## OBS-003: Registered-skills gauge

- **Type:** gauge.
- **Name:** `imago.skill.registered_total`.
- **Labels:** `root`.
- **Emission point:** updated on every `register-skill!` and `unregister-skill!` call. Snapshot logged on boot complete and on shutdown.
- **Verifies:** [[#NFR-005]] (capacity bound), [[#OBS-005]] continuity (shadow ratio = shadowed / total).

---

## OBS-004: Body-size distribution

- **Type:** histogram.
- **Name:** `imago.skill.body_bytes`.
- **Labels:** none (single histogram across all skills).
- **Emission point:** on `register-skill!` after successful parse.
- **Verifies:** [[#NFR-003]] (max body size) by surfacing the distribution operators can use to tune `*skill-max-body-chars*`.

---

## OBS-005: Shadowed-skill log

- **Type:** event log.
- **Name:** `imago.skill.shadowed`.
- **Body:** `(:name … :winning-root … :shadowed-roots (… …))`.
- **Emission point:** `discover-skills!` when the same name is encountered in more than one root.
- **Verifies:** [[#REQ-011]].
- **Operator action:** inspect to detect unintended shadowing (e.g. a project-scoped skill that the operator forgot is overriding the user-global version).

---

## OBS-006: Skill-influence trace (advisory, v0.2 placeholder)

- **Type:** event log.
- **Name:** `imago.skill.influence`.
- **Body:** `(:turn-id … :active-skills (…) :tool-calls-issued (… …))`.
- **Emission point:** end of each agent turn that loaded one or more skills via `harness-describe-skill`.
- **Status:** PLACEHOLDER for v0.2. Records which skills were consulted in a turn alongside which tool calls the turn issued, so we can answer the [[#ADR-003]] empirical question (do skill bodies steer the agent toward floor-blocked calls?). The mechanism for tagging "consulted" without false positives is an open implementation question and not in scope for v0.1.
- **Verifies:** the empirical input for the v0.2 [[#ADR-003]] revisit.

---

## OBS-007: Skill validation-failure rate

- **Type:** counter.
- **Name:** `imago.skill.validation_failed.count`.
- **Labels:** `phase` (`parse` | `name-mismatch` | `body-too-large` | `name-invalid`).
- **Emission point:** on every rejection in `discover-skills!` or `harness-define-skill`.
- **Verifies:** anomaly detection — a sudden spike in `parse` failures may indicate a corrupted skills directory; a spike in `body-too-large` may indicate an agent attempting to inflate skill bodies as covert storage.

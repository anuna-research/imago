# Non-functional requirements (NFR-### entries)

Measurable thresholds for the [[SPEC-013-skill-definition-port|skill definition port]]. Each NFR has a verification mechanism. Defaults are conservative and tunable via the `*skill-…*` parameters.

---

## NFR-001: Boot-time skill discovery latency

Boot-time skill discovery SHALL complete in ≤ 200 ms at the 95th percentile WITH a directory containing 100 skills and an aggregate body size of 1 MB on the standard test rig (SBCL on M-series Mac, single-process, warm filesystem cache).

Verification: [[#TEST-023]] (instrumented latency check), [[#OBS-001]] (recorded metric per boot).

Rationale: Boot is on the critical path for `./echo-agent --serve`. A 200 ms ceiling at 100 skills means a typical user will not perceive skill discovery, and the budget rises predictably with skill count.

---

## NFR-002: `harness-define-skill` end-to-end latency

A successful `harness-define-skill` call (including frontmatter validation, file write, fsync, and live install) SHALL complete in ≤ 50 ms at the 95th percentile WITH a body ≤ 8 KB on the standard test rig.

Verification: [[#TEST-024]] (instrumented latency check on the tool path), [[#OBS-002]] (per-call timing distribution).

---

## NFR-003: Maximum skill body size

`*skill-max-body-chars*` SHALL default to 65 536 characters (≈ 64 KB UTF-8). Bodies above this threshold SHALL be rejected with a structured `:rejected` plist citing the limit.

Verification: [[#TEST-013]], [[#TEST-025]].

Rationale: 64 KB is generous for guidance prose (≈ 10 000 words) while preventing pathological skill bombs. The parameter is dynamic-bindable so operators can lower it for memory-constrained deployments or raise it (with corresponding NFR re-derivation) for unusual cases.

---

## NFR-004: Skill name length

Skill names SHALL be 1–64 characters in length, inclusive. The 64-character upper bound aligns with Common Lisp symbol and Unix filename conventions while leaving room for namespaced names (`vendor-feature-detail`).

Verification: [[#TEST-011]], [[#TEST-026]].

---

## NFR-005: Skills-per-root capacity

The skill registry SHALL support ≥ 1 000 skills per root without functional regression. Beyond 1 000, [[#NFR-001]] no longer applies and operators SHOULD shard skills across multiple roots.

Verification: [[#TEST-027]] (load 1 000 generated skills, exercise list/describe/install), [[#OBS-003]] (registered-skills gauge).

---

## NFR-006: File-system footprint per skill

A skill with the minimal frontmatter (`name` + `description`) and an empty body SHALL occupy ≤ 1 KB on disk. The directory itself contributes the dominant cost on most filesystems; minimal skills SHALL NOT include extraneous files (no `.DS_Store` artefacts, no editor swap files emitted by the harness).

Verification: [[#TEST-028]] (size check on a freshly defined minimal skill).

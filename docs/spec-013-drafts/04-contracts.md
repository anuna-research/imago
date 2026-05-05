# Contracts (CON-### entries)

API specifications for the new tools introduced by [[SPEC-013-skill-definition-port]]. Each contract structures pre- and post-conditions per implemented [[#REQ-###]] for traceability.

All five tools follow the existing [[anuna-imago tool contract|tool dispatch contract]]: handlers return a plist; they MUST NOT raise to the turn loop. Failure cases produce `(:status :rejected … )` or `(:status :error … )` plists with structured fields.

---

## CON-001: Skill artefact format

**Interface.** A skill is a directory `<root>/<name>/` containing exactly one mandatory file `SKILL.md`. The file is a valid UTF-8 text document of the form:

```
---
<yaml-frontmatter>
---
<markdown-body>
```

Where `<yaml-frontmatter>` is a YAML 1.2 mapping containing at minimum the keys `name` (string) and `description` (string), and `<markdown-body>` is opaque Markdown.

**Pre-conditions:**
1. Frontmatter parses as a YAML mapping (per [[#REQ-001]]).
2. `name` value MUST equal the directory name and match `^[a-z][a-z0-9-]*$` (per [[#REQ-006]]).
3. Body is valid UTF-8 and ≤ `*skill-max-body-chars*` characters (per [[#REQ-007]], [[#NFR-003]]).

**Post-conditions:**
1. The artefact loads without modification in any [[Anthropic Skills]]-compatible runtime.
2. Round-trip (load → write) preserves all frontmatter fields up to canonical YAML key ordering (per [[#REQ-008]]).

**Error model:**
- If pre-condition (1) fails: parse error logged to receipt log; skill skipped at boot.
- If pre-condition (2) fails: skill rejected with `(:status :rejected :rule :name-mismatch :name … :directory …)`.
- If pre-condition (3) fails: skill rejected with `(:status :rejected :rule :body-too-large :limit …)`.

Implements: [[#REQ-001]], [[#REQ-006]], [[#REQ-007]], [[#REQ-008]].
Verified by: [[#TEST-001]], [[#TEST-002]], [[#TEST-013]], [[#TEST-014]], [[#TEST-015]].

---

## CON-002: `harness-define-skill`

**Interface.** Tool registered with the standard `define-tool` macro. Schema:

```
(:name        :type :string :required-p t :description "Skill name; ^[a-z][a-z0-9-]*$, 1–64 chars")
(:description :type :string :required-p t :description "One-sentence trigger condition")
(:body        :type :string :required-p t :description "Markdown skill body, ≤ 64 KB")
(:overwrite   :type :boolean :required-p nil :description "If true, replace an existing skill; default false")
(:metadata    :type :object :required-p nil :description "Optional vendor-extension metadata; round-tripped verbatim")
```

**Pre-conditions:**
1. `name` matches `^[a-z][a-z0-9-]*$` and length ∈ [1, 64] (per [[#REQ-006]], [[#NFR-004]]).
2. `description` length ∈ [1, 1024] characters; first sentence used as the trigger string.
3. `body` is valid UTF-8 and length ≤ `*skill-max-body-chars*` (per [[#REQ-007]], [[#NFR-003]]).
4. If a skill with `name` already exists in the target root, `overwrite` MUST be `t`; otherwise the call is rejected.

**Post-conditions:**
1. A directory `<user-skill-root>/<name>/` exists and contains a `SKILL.md` file matching [[#CON-001]].
2. The skill is registered in `*skill-registry*` and immediately discoverable by [[#CON-004]] / [[#CON-005]] within the same turn (per [[#REQ-005]]).
3. An audit log entry is appended via the existing receipt log surface ([[#OBS-002]]).
4. The call returns `(:status :ok :name … :path …)` on success.

**Error model:**
- Pre (1)/(2): `(:status :rejected :phase :validation :rule … :reason …)`.
- Pre (3): `(:status :rejected :phase :body-validation :rule :too-large :limit …)`.
- Pre (4): `(:status :rejected :phase :overwrite-required :existing-name …)`.
- Filesystem write failure: `(:status :error :phase :persist :condition-type … :message …)`.

Implements: [[#REQ-002]], [[#REQ-005]], [[#REQ-006]], [[#REQ-007]].
Verified by: [[#TEST-003]], [[#TEST-004]], [[#TEST-008]], [[#TEST-010]], [[#TEST-011]], [[#TEST-024]].

---

## CON-003: Skill discovery (boot path)

**Interface.** Internal entry point `discover-skills!`, called by `agent-main` after `install-builtin-tools!`. Walks roots in declared order; returns the count of registered skills.

**Pre-conditions:**
1. `*skill-roots*` is a non-empty list of pathnames (per [[#REQ-003]]).
2. Each root either does not exist (skipped) or is readable.

**Post-conditions:**
1. For each readable root, every immediate subdirectory containing a parseable `SKILL.md` is registered in `*skill-registry*`.
2. Subdirectories with unparseable `SKILL.md` are logged to the receipt log and skipped (not aborted on).
3. When the same `name` appears in multiple roots, the first root in declared order wins; later occurrences are recorded in `*skill-shadow-log*` (per [[#REQ-011]]).
4. The function returns within the time bound stated in [[#NFR-001]] for representative skill counts.

**Error model:**
- A directory missing `SKILL.md` is silently skipped (no log entry — it is presumed not to be a skill directory).
- A `SKILL.md` with parse failure produces a `:warn`-level receipt-log entry with the offending path and parse error.
- Filesystem-permission errors on a root produce a `:warn`-level entry and the root is skipped; remaining roots continue.

Implements: [[#REQ-003]], [[#REQ-011]].
Verified by: [[#TEST-005]], [[#TEST-006]], [[#TEST-021]].

---

## CON-004: `harness-list-skills`

**Interface.** Schema:

```
(:prefix :type :string :required-p nil :description "Optional name prefix filter")
```

**Pre-conditions:** None beyond the harness running.

**Post-conditions:**
1. Returns `(:status :ok :skills ((:name … :description-first-sentence …) …))`.
2. The list is in registration order (deterministic across calls within a single boot).
3. If `:prefix` is provided, only skills whose `name` starts with the prefix are returned.
4. The call does not mutate the registry or the file system.

**Error model:** None — the call cannot fail under normal operation.

Permission: `:read`.
Implements: [[#REQ-004]].
Verified by: [[#TEST-007]].

---

## CON-005: `harness-describe-skill`

**Interface.** Schema:

```
(:name :type :string :required-p t :description "Skill name to describe")
```

**Pre-conditions:** `name` is a string.

**Post-conditions:**
1. If a skill with `name` is registered: returns `(:status :ok :name … :frontmatter <plist> :body <string>)`.
2. If not: returns `(:status :not-found :name …)`.
3. The call does not mutate the registry or the file system.

**Error model:** No error case. Missing skills are reported via `:not-found`, not error.

Permission: `:read`.
Implements: [[#REQ-004]].
Verified by: [[#TEST-007]].

---

## CON-006: `harness-install-skill` and `harness-uninstall-skill`

**Interface.** Schemas:

```
;; harness-install-skill
(:name :type :string :required-p t :description "Skill name to (re-)install from disk")

;; harness-uninstall-skill
(:name :type :string :required-p t :description "Skill name to remove from the registry")
```

**Pre-conditions (install):**
1. `<root>/<name>/SKILL.md` exists for some `<root>` in `*skill-roots*` (else `:not-found`).
2. The file parses per [[#CON-001]] (else `:rejected`).

**Pre-conditions (uninstall):** None.

**Post-conditions (install):**
1. On success, the skill is registered in `*skill-registry*`, replacing any prior in-memory entry of the same name. The on-disk artefact is unchanged.
2. Returns `(:status :ok :name …)` or a `:rejected`/`:not-found` plist.

**Post-conditions (uninstall):**
1. On success, the skill is removed from `*skill-registry*` if present. The on-disk artefact is NOT deleted.
2. Returns `(:status :ok :name … :was-registered <boolean>)`.

**Error model:**
- Install: `:not-found`, `:rejected` (parse failure), or `:error` (filesystem permission).
- Uninstall: only `:ok`.

Permission: `:execute` (install), `:execute` (uninstall).
Implements: [[#REQ-005]].
Verified by: [[#TEST-008]], [[#TEST-009]].

---
name: hence
description: This skill should be used when the user asks to "coordinate tasks",
  "create a plan", "manage agents", "use hence", "track task progress",
  mentions "SPL", "defeasible logic", "hence.run", "multi-agent coordination",
  or needs to write, query, or manage task plans for LLM agent workflows.
version: 0.6.0
---

# Hence — Defeasible Logic Task Coordination

Hence is a CLI for multi-agent task coordination using defeasible logic. Write plans as logical rules, query the engine to determine what's ready, who should work on it, and what to do next.

## Agent Workflow

```bash
export HENCE_AGENT=me                    # Set once, used by all commands
hence agent whoami                       # 0. Know your cryptographic identity
hence plan info plan.spl                 # 1. Read plan metadata
hence plan board plan.spl                # 2. See full task board
hence task next plan.spl                 # 3. Find tasks assigned to me
hence task claim mytask plan.spl         # 4. Claim a task
# ... do the work ...
hence task assert '(given discovered-something)' plan.spl  # 5. Record findings
hence task complete mytask plan.spl      # 6. Mark done
hence task next plan.spl                 # 7. Check what unlocked
```

**Tip:** `HENCE_AGENT` is used by all commands. Explicit `--agent` always overrides.

## Command Reference

### Setup

| Command | Description |
|---------|-------------|
| `hence plan init <file.spl>` | Create a new plan from template |

### Core Commands

| Command | Description |
|---------|-------------|
| `hence task next <file> [--agent NAME] [--json]` | Show next available actions |
| `hence plan status <file> [--trust] [--at TIME] [--json]` | Show all conclusions |
| `hence plan board <file> [--agent NAME] [-v] [--tree] [--dag] [--json]` | Task board view |
| `hence task assign <file> [--agent NAME] [--json]` | Show task assignments |

### Task Lifecycle

| Command | Description |
|---------|-------------|
| `hence task claim <task> [file] --agent <name>` | Claim/start a task |
| `hence task unclaim <task> [file] --agent <name>` | Release a claimed task |
| `hence task complete <task> [file] [--agent NAME]` | Mark task completed |
| `hence task block <task> <reason> [file] --agent <name>` | Block a task |
| `hence task unblock <task> [file] --agent <name>` | Unblock a task |
| `hence task assert <spl> [file] --agent <name> [--task TASK]` | Assert new facts/rules |

### Explanation Commands

| Command | Description |
|---------|-------------|
| `hence query explain <literal> [file] [--json]` | Show proof/derivation for a conclusion |
| `hence query why-not <literal> [file] [--json]` | Debug why something isn't provable |
| `hence query require <literal> [file] [-v] [--assume FACTS]` | Abduction: what facts are needed? |
| `hence query what-if <file> <facts...> [--json]` | Hypothetical: what changes if we add facts? |
| `hence query describe <file> <labels...> [--json]` | Show rule/fact definitions and metadata |

### Identity & Plan Info

| Command | Description |
|---------|-------------|
| `hence agent whoami [--json]` | Show this agent's Ed25519 public key |
| `hence plan info <file> [--json]` | Show plan metadata from `(meta plan ...)` |

### Other Commands

| Command | Description |
|---------|-------------|
| `hence plan validate <file> [--strict] [--json]` | Check plan for errors/warnings |
| `hence query trace <file>` | Full reasoning trace |
| `hence repl [file]` | Interactive REPL |
| `hence llm [spl\|dfl]` | Output format reference for LLMs |

## Writing Plans

1. Start with `(meta plan ...)` — id, title, status, description at minimum
2. Declare agents as `(given agent-NAME-available)` and tasks as `(given task-NAME)`
3. Add `(meta task-NAME (description "...") (acceptance "..."))` for every task
4. Write readiness rules (`ready-`), assignment rules (`assign-to-TASK-AGENT`), and superiority
5. Annotate rules with `(meta LABEL (description "...") (justification "..."))`

Run `hence llm spl` for the full SPL syntax reference with a complete annotated example.

## Debugging

- `hence query explain <file> <lit>` — proof tree showing which rules fired
- `hence query why-not <file> <lit>` — missing preconditions or defeated rules
- `hence query require <file> <lit>` — what facts would make it provable
- `hence query what-if <file> <facts...>` — what changes if facts are added

Proof notation: `+D` definitely provable, `+d` defeasibly provable, `-D` definitely not, `-d` defeasibly not.

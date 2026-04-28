# §2. The bitter lesson, applied to runtimes

Sutton's *bitter lesson* [Sutton 2019] holds that across game-playing,
speech, vision, and translation, "general methods that leverage computation
are ultimately the most effective, and by a large margin." The history of
each subfield has been one of researchers building elaborate domain
heuristics, only to be overtaken by simpler methods that scaled with compute.
Sutton's argument concerns *research methods* — what to spend a PhD or a lab
budget on. We argue the lesson transfers cleanly to *engineering frameworks*:
abstractions that compensate for current model limitations are themselves
hand-engineering, and they age out in the same way and for the same reason.

Three concrete examples make the transfer concrete. **Explicit planner
modules** were a major offering of 2022-era agent frameworks; they encoded
a theory that LLMs could not decompose tasks without help. Tool-using
chain-of-thought loops have since done the same work directly, and the
explicit-planner modules now exist mainly to be skipped. **Output parsers** —
regex, grammar, BNF — were necessary infrastructure when models would not
reliably produce valid JSON. Within roughly a year, structured-output and
tool-calling modes made the parsers near-vestigial; the libraries have
become legacy maintenance for code paths most users no longer enter.
**Prompt-templating engines** built around the assumption that
instruction-following was fragile have shrunk in value as instruction-following
improved; the abstractions remain in framework code but the user no longer
needs them.

A natural counterargument is that *every* framework needs *some* opinion —
the choice is not between opinionated and unopinionated but between which
opinions to hold. We accept the framing and refine the claim: framework
opinions about *operational concerns* (process supervision, audit,
distribution, identity, capability routing) are stable across model
generations because they are not predictions about model behaviour at all.
Framework opinions about *capability concerns* (what the model needs help
doing) are unstable because they are exactly such predictions. The advice
is not "have no opinions" but "hold the opinions that don't depend on
contingent facts about today's models."

The migration cost of capability-tracking opinions is underdiscussed.
Each time a model generation obsoletes a framework abstraction, engineering
teams choose between rewriting against the new framework idiom (paying
migration debt) or carrying dead code paths (paying maintenance debt).
Neither outcome rewards the original choice. A framework that confines
itself to operational concerns *cannot owe* this migration debt, because
the operations themselves did not change.

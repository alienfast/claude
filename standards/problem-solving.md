# Problem-Solving Standards

## When Encountering Technical Obstacles

### Decision Framework

**STOP and ASK when:**

- Root cause is unclear after thorough investigation
- Multiple valid solutions exist with significant trade-offs
- Solution requires choosing between competing design philosophies
- 2+ attempted solutions have failed
- Each attempt reveals new unexpected complexity
- Problem appears to have deeper architectural issues than initially visible
- Business logic decisions needed (e.g., how to handle edge cases with user impact)
- Performance vs. maintainability trade-offs with no clear winner
- Security vs. usability decisions
- Technical approach would deviate significantly from existing codebase patterns (when unclear if deviation is desired)

**RESEARCH DEEPER when:**

- Error messages are unclear or undocumented
- Technology/API is unfamiliar
- Best practices are not obvious from existing codebase
- Solution pattern doesn't exist in current codebase
- Documentation is sparse or contradictory

**PROCEED DIRECTLY when:**

- Solution is obvious from investigation
- Pattern exists in codebase to follow
- Change improves code quality (better abstractions, removes tech debt)
- Error messages provide clear guidance
- Standards explicitly cover the scenario
- Fix aligns with existing patterns and conventions (for the *shape*; see "A precedent is not a safety argument")

### A precedent is not a safety argument

"The sibling does it this way" establishes that a shape is *conventional*. It never establishes that it is *safe here*:
it satisfies the PROCEED DIRECTLY bullets for the shape, never for the consequences.

Before copying a guard, lock, retry, timeout, cache, or self-healing mechanism from a sibling function, read the **new
call site** and write one sentence: what happens when this mechanism misfires here, and how that differs from where you
copied it from. Identical code carries different blast radii: a stolen lock costing a redundant write is not a stolen
lock costing an irreversible side effect (a customer email, a payment, a published record). When the consequences
differ, the precedent transfers nothing; the mechanism needs its own justification, or a different mechanism.

The sentence is the point. You cannot write it without leaving the function you are editing, and the invariant that
forbids the copy is usually documented at the caller rather than at the thing being copied: a permanently-held claim
can *be* the anti-double-send guard, said so one file away, and a staleness TTL copied from its siblings re-sends.
"Match the siblings" terminates the inquiry before it reaches that file.

This is not `/quality-review`'s "following an established codebase pattern is not an open design choice," which governs
whether a *fix* needs a design decision before it can auto-apply. A transplanted mechanism can be localized, small, and
contract-free, clearing every one of those gates, and still be wrong at the new site.

## Anti-Patterns: Technical Workarounds

### Never suggest these without explicit approval

1. **Dependency Downgrading**: "Let's downgrade package X to avoid this issue"
   - Instead: investigate why the new version breaks, fix the root cause
   - Exception: security issues make the newer version unusable (ask first)

2. **Error Suppression**: "Let's ignore/suppress this error for now"
   - Instead: understand and fix the error properly
   - Exception: known false positive with documented reasoning

3. **Type Casting to Bypass**: "Let's cast to 'any' to get past type errors"
   - Instead: fix the type definitions properly
   - Exception: third-party types are broken (document and report)

4. **Incomplete Implementation**: "Let's skip tests/validation for now"
   - Instead: complete the implementation fully
   - Exception: user explicitly requests incremental delivery

5. **Configuration Hacks**: "Let's disable this linter rule/check"
   - Instead: fix the code to satisfy the rule
   - Exception: rule is genuinely incorrect for this use case (document why)

6. **Partial Migrations**: "Let's migrate just part of the code"
   - Instead: complete the migration or use feature flags
   - Exception: incremental migration is the documented strategy

7. **Silent Defaults for Required Config**: "Let's default to X if the env var isn't set"
   - Instead: keep the throw/error. Required means required; silent fallbacks mask misconfiguration.
   - Exception: the value is genuinely optional with a documented default (rare for required-by-name config)

### Asserting a capability does not exist

Never record that a tool, flag, or command is unavailable, and never skip a required step on that basis, without having
**run the check**: `--help`, `command -v`, the tool's own listing, or the documented call itself. A capability claim is a
factual claim about this machine, cheap to verify and expensive to get wrong: it converts a skipped step into a
documented impossibility that no reviewer re-examines, and it can send a follow-up issue after tooling that already
works. When a call genuinely fails, record the command and its exact error, never the generalization. This is worse
than ignoring a rule, because the agent concludes compliance is *impossible* and documents the reasoning persuasively
enough to pass its own review: a verdict that records "collision edges could not be created with available tooling"
while `linear-cli relations add` sits in the linear skill's command map, settled by `relations --help` in one call.
`scripts/quality-review-write-verdict.sh` guards that one choke point mechanically; the shape generalizes to any skipped
step justified by an unchecked capability claim.

### A workaround's premise can expire, and the change that expires it owns its removal

Scaffolding built around a missing value, an unavailable dependency, or an unfinished decision usually **states its own
precondition** in a comment, a docblock, or the issue that added it. That sentence is an expiry condition. When your
change supplies the missing thing, the scaffolding is dead as of your commit, and deleting it is part of the change: not
a follow-up, not ops work, not someone else's ticket. This is the recognition step in front of
[technical-debt-prevention.md](technical-debt-prevention.md)'s *Delete Aggressively*: the hard part is noticing that your
own change is what killed it. Distinct from a stale *issue* premise, which someone else's work invalidates and which is
answered by descoping, not deleting.

The failure is a mis-framed question. Facing existing scaffolding, "how do I feed this design the new value?" and "does
this design still have a reason to exist?" produce completely different work, and only the first looks like
configuration. Ask the second first, and re-read the scaffolding's own comment before answering. Two tells that you
asked the wrong one:

- **The remedy turns into infrastructure or process work** (a config key to set, an environment to update, a person to
  ask) when what you obtained was a value with an obvious home in code you already have open.
- **You find yourself hardening the scaffolding**: adding a test, a guard, or a comment to machinery whose premise your
  change just retired.

Removal is inside the change's blast radius: your commit is what made the code dead, so the issue's scope boundary,
written before the premise expired, does not exclude it. Its tests go with it; they only pinned the workaround's
behavior, and leaving them makes the next reader believe it is load-bearing. **Keep any invariant the scaffolding was
incidentally enforcing**, in generalized form: a fail-closed guard that happened to live inside it is worth relocating
and re-testing. Hardcoding the obtained value where the indirection stood also exposes what the indirection hid, such as
a collision with a sibling that uses the same value.

### A verification you never watched fail is not a verification

A sweep, checker, or audit whose passing result gates a decision (ship it, mark it fixed, declare convergence) must
prove it can still fail before its verdict is worth anything:

- **Negative control.** Include a case that MUST be reported: a deliberately-broken fixture, a reverted fix, a relaxed
  clause. A run that flags nothing means something only if you have watched that same run flag something.
- **Zero discovery is an error, never a pass.** Zero files scanned, zero items parsed, zero matches: fail loudly. Report
  the counts next to the verdict so an empty run is visible rather than clean-looking.

A harness that silently matches nothing (a wrong glob, an ignore rule that excludes the fixtures, a parser regex that
stopped matching the tool's output format) returns the same "no problems found" as a genuinely clean run. That is the
answer everyone wants, which makes it the one nobody questions.

### Measure the quantity that moves, not the call you are deleting

An invalidation (a cache clear, a memo reset, a connection flush) is cheap *at the call* and expensive *downstream*, in
the re-population it forces on everything after it. A stopwatch around the call times bookkeeping, can understate the
real cost by orders of magnitude, and reads like evidence. When the change is "stop doing X," measure the whole workload
with and without X, back to back on one machine, with X as the only variable. Reach for a stopwatch around X only when
nothing downstream re-derives what X discarded. The A/B also survives being wrong about *why*: attribution to the single
changed variable is what the measurement establishes; the mechanism behind it is a separate claim.

### Two measurements agree only if they measured the same kind of thing

A close numeric agreement between two observations is evidence of nothing until both are established as instances of
the same *kind* of event. Agreement is seductive in proportion to its tightness: the closer it is, the more it reads as
having found the mechanism, and the less likely anyone is to re-check what was compared. Internal consistency checks
test the arithmetic, not the identity of the things compared. Before drawing a conclusion from a match, name what each
observation *is* and confirm the names are the same; where the system reports the kind (an error class, a limit name, a
status code, a build variant), read it rather than inferring it from the observation's shape. Two rate-limit cutoffs
whose billable volumes agree to a fraction of a percent are two *different* limits coinciding when the harness messages
name a weekly allowance and a per-session one.

### A guard keyed on someone else's signal inherits their coverage decisions

When a condition your code cares about ("more than one file was dropped on a single-file target", "the request was
throttled", "the record was superseded") is detected by reading a signal a **dependency** emits (an error code, a status
enum, a flag) rather than by deriving it from inputs you already hold, the dependency decides which cases raise that
signal. Confirming it fires in the obvious case measures nothing about the cases it stays silent in, and a guard that
acts only when the signal arrives does nothing in exactly those, failing open for the common suppress-on-signal shape.
The measurement is true and the inference from it is false, so re-reading the measurement never surfaces the error.

Before keying on such a signal, enumerate the ways your condition can hold and check the signal fires for each. Where
the condition is derivable from what you already have, derive it: a dropzone callback that already receives both the
accepted and the rejected arrays can test `accepted.length + rejections.length > 1` itself instead of waiting for a
`too-many-files` code the library emits only when the *accepted* count exceeds the limit.

### A control keyed on a pattern in a shared channel is only as sound as that channel's other writers

The rule above covers a signal that may fail to fire; this covers one that may fire for the wrong reason. A detection or
authorization control that keys on a **pattern in a shared channel** (a substring of a log stream, a metric name, a
topic, a row shape in a table many things write) is sound only as a property of every writer to that channel, not of the
site the plan is editing. The line that site emits may be unforgeable, and the reasoning that establishes it correct,
while any other writer that echoes caller-controlled text into the same channel satisfies the pattern.

- **Enumerate the channel's writers before choosing the pattern, and state what each can place in it.**
- **Prefer a property no other writer can reproduce over a string no other writer happens to emit today**: a position
  echoed text cannot occupy, or a structured field only the emitter sets. Where the channel carries attacker-influenced
  content, and a log stream almost always does, a distinctive-looking phrase is not such a property.
- **Pin the cross-boundary contract against the real definition**: a test that parses the live filter and asserts both
  that a genuine emitted line matches and that the same phrase echoed mid-message does not.

### An enumeration inherits its pattern's blind spots

A count or site list produced by a search is a claim like any other, and the pattern doing the enumerating is the next
unmeasured one. A family that spells the same thing differently (a wrapper rather than a constant, a delegation, an
alias, an indirect call through another object) is absent from the result with **no trace**: no error, no zero-hit line,
nothing a re-read surfaces, so the output reads as a census when it is a sample of one naming convention, and every ratio
drawn from it inherits that. **Scope is part of the pattern**: a directory list narrower than the property drops real
members the same way. Before quoting a count, ask how else the thing is spelled here and check one of each; one hit from
an excluded convention falsifies the census. Record the regenerating command rather than the membership
(`rules/comments.md`'s roster rule). A census arriving from a *verification* pass carries that pass's authority, so say
so and ask for it to be re-derived.

### Don't build reliability against a stub

When the dependency a reliability layer protects is still a stub (a no-op transport, a seam that always succeeds, an
integration deferred to a later pass), its failure modes are **unobservable**: nothing it does can falsify a guess about
them. Retry policy, at-least-once delivery, idempotency claims and redelivery handling built against it rest on
assumptions no test and no reviewer can check, and each review cycle trades one guess for another instead of
converging. The tell is that every justification is written in the future tense, about what the dependency *will* do.

Ship honest best-effort now (attempt, log the outcome, let the caller see whether it succeeded) and file the reliability
layer as follow-up work to be built against the real dependency. A best-effort call against a stub and one against a
live service behave identically, while the speculative version has to be unbuilt before the real one can be written.
This is the opposite failure from the workaround anti-patterns above (shortcuts *around* a problem; this is building
past what the evidence can support), and distinct from [technical-debt-prevention.md](technical-debt-prevention.md) § 4,
which is about retaining a superseded implementation rather than writing a speculative one.

### A gate that one measurement has disproved is settled: act once

A skill's recovery tree is written for the ambiguous case. When a gate fires and a single measurement proves it a false
positive (an identity gate reporting a clobbered lineage where `git diff <dropped-sha> HEAD` is empty), re-walking the
tree's branches re-litigates a settled question. Send one message: the proof, the single remedy command, and either
proceed or ask exactly once; never a second question on the same decision. An instruction already given ("merge") is the
authorization, so reach the next hard blocker immediately (a permission denial is the user's real decision surface)
rather than deliberating in front of it, and take the direct path rather than routing through another session whose
liveness you do not control. For "can this merge?", `git merge-tree --write-tree <base> <branch>` is the one-second,
read-only fact that decides it; run it first.

### Complexity Response Pattern

When two or more attempts have failed, stop and hand the decision over with everything needed to make it: what you tried
and how each attempt failed, the specific ambiguity or decision point that remains, the proper fix scoped concretely
(which files, roughly how much work), the workaround alternative and what it costs, and your recommendation, which is
the non-workaround option unless there is a stated reason otherwise. Then ask.

The failure mode this replaces is proposing the workaround alone ("let's downgrade to v1.2 to avoid this"), which asks
the user to approve a decision they cannot see the alternatives to.

### Ask as a story

Wherever a question's answer turns on what someone experiences (a label a user reads, what an admin can or cannot do,
how an edge case lands on a customer, which of two policies to adopt), write the question as a story, not as a menu of
mechanisms. The decider answers from the scenario; the code facts that make the scenario true are evidence beside it,
never the question. In this shape:

1. **Position.** "Decision 2 of 3": the reader knows how much is coming and that each stands alone.
2. **The story.** Named people and organizations doing concrete things: who did what, what they see on screen, what goes
   wrong or what becomes reachable. The names are invented; identifiers stay out. The fact that makes the story true (a
   migration id, a column, a unique index) sits in parentheses or below the story as evidence, so the reader can check it
   without needing it to decide. When the harm has several parts, list them.
3. **The stake**, in a sentence: what is now false, harmful, or exposed that was not before.
4. **Lettered options, named by outcome.** Each says what the reader would see or be able to do under it and what it
   costs: more work, or a part of the problem left open. The recommended one comes first with its reason in the reader's
   vocabulary, never the code's (recommend, don't menu). When the user pinned the current behavior, keeping it is an
   option, labeled as theirs. A parameter an option needs (a cap, a rate, an add-on sentence) is named so the answer can
   carry it.
5. **The closing question**, listing the letters: "Which do you want: A, B, C, or D?"

**After the answer**, restate what is settled as its consequence ("A, so bridge rows show 'Team admin'") and name what
stays unchanged, then re-derive the next question from that answer rather than asking the one already queued; an answer
routinely collapses or reshapes what follows.

**When the reader questions a premise** ("why would it disappear from the other org?"), check the mechanism before
replying, say in plain terms why the current behavior is what it is and whether it was intended, state their model back
to them, lay out what adopting it changes, and ask the new fork it opens. Defending the original framing is the failure:
the premise challenge is usually where the real decision is, and it routinely exposes a data-model constraint larger than
the issue.

A question with no experiential consequence (which of two equivalent files, whether to run in a worktree) takes the
recommend-don't-menu rule and the Complexity Response Pattern without the story. `/spec`'s decision interview is this
pattern's product-owner form, staged over batches.

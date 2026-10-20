# Decision-grade issues

Read this when `/spec` Step 2 classifies an issue as decision-grade: its deliverable is a decision rather than a
buildable spec — the title or a "Decision needed" section asks a question ("Decide …"), two-plus candidate designs are
named, an authorization or policy surface is in play, or other issues block on the answer.

The deliverable is a **recorded decision plus filed follow-ups**, not a certified description. Running the standard
path instead certifies criteria that ask the implementer to decide, which the quality bar forbids. The standard steps
still run, with these deltas.

## Research — dispatch `architect`, and interrogate rather than survey

The generic Explore prompt returns a map too shallow to debate from. Build a structured interrogation from the issue's
own claims: quote the gate and predicate bodies verbatim, enumerate every write site of the state in question, the
schema shapes, the linkage (or its absence) between the tables involved, and who mints what. Add `git log --grep <ID>`
and `git log -S<symbol>` probes — commit messages are where deferred decisions get recorded, and prior-decision
provenance reframes the debate. Architect unavailable → Explore with the same prompt, and say so.

Step 2 item 5 (a moved gate) applies to this interrogation exactly as it does to the Explore prompt.

## Verify the option space before debating it

The issue's A-vs-B framing is a filing-time reading, not a constraint. Check whether an option structurally collapses
(per-tenant data hanging off the table a "pure global" option would replace) or whether a third shape dominates both.
Reframing the forks is the highest-value move on this path and happens before the first question.

## Interview — the problem as a story first, then forks, in the business's words

This is the product-owner form of `standards/problem-solving.md` § Ask as a story. The decider is the product owner, and
a decision issue an agent filed arrives in the code's vocabulary — class names, column names, the code's own verbs —
which the interview translates, never relays.

Before the first AskUserQuestion, present the brief in this order:

1. **The problem as a concrete scenario** — who does what, what a customer or operator sees, what goes wrong — with no
   identifiers.
2. **Whether it matters** — which filed concerns change what a user sees and which are hygiene with no consumer, and
   whether the originating issue's own Decisions already answer the question (an agent files a decision issue against a
   rule the product owner recorded the day before as readily as against an open one; the first question is then whether
   anything here changes that decision). Recommend dropping what is hygiene: a decision with nothing to build is a
   first-class outcome, closed `Done` with no follow-ups.
3. The reframing facts from research, your position, and the strongest counterargument against it.

Then interview only the genuine forks, staged — product intent first, the design consequences of those answers second,
residuals third, one or two forks per batch — and **draft the next stage only after the previous one is answered**,
re-deriving which forks that answer already settles. A product-intent answer routinely collapses every design
consequence, so a second batch is the exception; questions lined up in advance are the ones that no longer make sense
when it arrives.

Write each fork as the scenario it decides ("a customer asked to be removed from the directory and a superuser removed
them; later a listed duplicate is merged into them — do they go back in, or stay out?") with options named by their
outcome for the business. Step 3's recommend-don't-menu rule is mandatory here, with the reason in product terms.
Identifiers and the code fact a recommendation rests on go into the brief's evidence and the recorded decision, never
into a question or option — a question the product owner cannot answer without opening the code is written wrong (the
interview-side form of `standards/issue-spec.md`'s route-the-decision-not-the-doubt rule). A four-fork first batch with
a column name in the question text draws "what problem are we solving?"; the same decision posed as one scenario with
two outcomes closes in one exchange.

## Output — record, file, propagate, close

- Record the decision **on the issue**: who decided, when, each question's answer with its rationale — including any
  invariant the decision *refines*, stated in its refined form (otherwise the next reviewer reads the change as a
  regression against the old invariant).
- Check off the criteria the record satisfies; a criterion the follow-ups will discharge stays unchecked, with the
  comment naming which issue carries it.
- File follow-ups in canonical shape; certify only those meeting the bar. One whose requirements cannot yet prescribe
  behavior (criteria would read "decide X") files **uncertified + `needs decision`** (`standards/issue-spec.md`), never
  certified around the gap. Wire collision edges per Step 6 item 6 — including against open issues touching the units
  the follow-ups will extend.
- A code comment that defers to this issue (`whether that should count is <ID>`) goes stale when it closes. Rewriting
  it to state the decision is the one code edit `/spec` makes — comment-only, since `rules/comments.md` forbids filing
  an issue whose whole remedy is a comment edit — and it is **committed in the same step**, by path, under the repo lock
  (`~/.claude/scripts/with-repo-lock.py "$(git rev-parse --path-format=absolute --git-common-dir)" git commit -m
  "<ID>: …" -- <file>`). The option that offers it says it commits, and the user's pick is the grant. Never leave it
  uncommitted for review: the main checkout is usually the branch a fleet merges into, and an uncommitted edit there is
  the dirty tree `standards/git-worktrees.md` § Posture for high-concurrency runs warns about — it defers every fleet
  merge. On the default branch, ask where it goes instead.
- Close the decision issue `Done` — a decision with no code change rides no release, so `Ready for Release` is wrong
  for it. This is the one place `/spec` touches state beyond Triage → Planned, and invoking `/spec` IS the grant for the
  move (the same idiom as `/auto`'s run-scoped commit/push grant) — never stop to re-ask. A decided issue left open is
  not caution: unlabeled and uncertified in Backlog, it re-enters pick mode and bare `/next` rankings as a workable
  candidate while carrying nothing to work.

**Propagate to dependents before clearing their gates.** Write the decision into each dependent's *description*, never
only a comment (`standards/issue-spec.md`). Before removing `needs decision` from any dependent, re-read its spec for
judgment calls the recorded decision does not answer — clearing the label makes a certified issue fleet-pickable, so an
unstated scope ships as an unattended agent's invention. The human is present: interview the residual now.

## Session model

The judgment that pays on this path — catching a residual gate, noticing the option-space collapse — lives in the main
loop, which no dispatch upgrades. Suggest `/model claude-fable-5` before a decision-grade grooming when the session is
on a lower tier.

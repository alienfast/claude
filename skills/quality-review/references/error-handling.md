# Error handling

The core's Error Handling list names the triggers; this file carries each branch's procedure and verdict body.

**The termination verdict bodies below are shapes, not literals.** Populate all seven Output-schema fields from what
the run actually did, and write each `Open items:` diagnostic to describe the failure that actually occurred. Never
assert something the run did not do, and never report `none` for something it did — including anything Step 6 had
already applied, filed, or classified before this branch fired — and route anything Step 6 would otherwise have filed or
surfaced, but will now never reach, into `Open items`. `Cycles:` is grounded in the review-cycle dispatch history —
`quality-reviewer`, or the simple tier's `quality-verifier` scoped review — exactly as `soft-ceiling.md` § Ground the
count requires, and `Verdict:` is the literal shown.

## `pnpm check` repeatedly fails at the Step 2 gate

After multiple `developer` delegations: surface to the user with the failing output. Do not proceed to review.

## Sub-step 5's corrective pass leaves `pnpm check` failing or regressions unaddressed

The deferred-item fixes broke the application and the single corrective `developer` pass did not restore it. Set the
run verdict to `terminated-with-open-items`, route per sub-step 5's verdict-population rules, and surface the failing
output to the user along with the `Open items` list. Do not loop further or roll back automatically — let the user decide
whether to revert, re-run `/quality-review`, or escalate to architect.

## No changed files detected

Warn the user and exit. Nothing to review (after Step 1's outside-this-repo check).

## Issue ID provided but `linear-cli` not authenticated

Prompt `linear-cli auth oauth`, then continue without issue context if the user skips. Auto mode: do not prompt —
continue without issue context immediately. The review still runs and the verdict still persists: the provided ID
resolves locally without Linear auth, and persistence is local; only the requirements-conformance context is lost.

## A reviewer dispatch is terminated mid-response by a transient API error

Overload/529, rate limit/429, transient 5xx — the harness reports the response as incomplete. **Evaluate this before the
two branches below; it takes precedence over both.** If the partial output shows real tool activity, the agent did
substantial work a re-spawn would discard — this is infrastructure, not a format refusal and not an unavailable agent.
Do not let the malformed branch's corrective re-spawn consume the attempt, and do not route it to the agent-unavailable
branch on the strength of that branch's `infrastructure error` trigger. Instead: surface the partial output (so the
work is not lost), then resume the same agent ONCE via `SendMessage` — restating the Required findings format, passing
the `Already tracked` list per Step 1's carry-forward rule, and, when a sibling parallel reviewer has already reported,
the ground it covered, so the resumed turn concentrates on what is still unreviewed. A well-formed resumed report
continues the run normally and counts as a completed cycle for `Cycles:` (in wt mode, `worktree-hygiene.md`'s
post-delegation checks apply to the resumed turn like any other delegation). If the resume returns nothing usable or is
still malformed, the attempt is consumed — fall through to the branches below as written. This is the complement of
the zero-tool-activity case, not a duplicate of it: no tool activity means the agent never started, tool activity plus
a truncated response means it started and was cut off — same remedy, opposite evidence.

## A reviewer dispatch returns malformed findings

`quality-reviewer` and `quality-verifier` carry an identical findings-format contract. The criteria are scoped to
exactly six dispatches: Step 3's initial review, Step 3's simple-tier scoped review (a response carrying a line matching
`^ESCALATE:` anywhere — alone, as preamble, or as appendix — is the tier's escalation answer, taken by `simple-tier.md`'s
recipe before these criteria are applied and never malformed; the criteria apply only to a response with no such line),
Step 5 item 4's re-review, Step 6 sub-step 5's mandatory and confirmatory re-reviews, and this branch's own corrective
re-spawn. **This enumeration is the authority** — do not re-derive scope from whether a given prompt happens to spell
the Required findings format out, since some in-scope dispatches inherit it from the agent's system prompt rather than
restating it. Step 5 item 5's `Targeted fix confirmation` dispatch (wherever issued — the mechanical lane, the
convergence drain, or the ceiling's lane drain) is **exempt by name**: its Acceptance asks for per-fix confirmation or
a concrete failure scenario, not the categorized findings report these criteria police, so its response is judged
against that Acceptance instead. The exemption keys on the dispatch shape, not on what the response happens to contain
— an ordinary review that answers in confirmation shape is still malformed.

For a dispatch in scope, a response is malformed if ANY of the following hold:

- Missing the `## Review Findings` heading.
- Missing any of the five required subheadings, in order: `### Critical`, `### High`, `### Medium`, `### Nice-to-Have`,
  `### Approved`. Match by line-prefix with a narrow tail: the heading word(s) followed by either end-of-line OR ` (`
  (single space + opening paren, for the optional parenthetical like `(must fix before done)` or `(auto-fix lane)`).
  Matches: `### Critical`, `### Critical (must fix before done)`, `### Nice-to-Have (auto-fix lane)`. Does not match
  (malformed under the non-standard-heading criterion): `### Critical findings`, `### Critical:`, `### CRITICAL`,
  `### Nice-to-Have / Out-of-Scope` — an agent emitting a heading outside the contract is re-spawned onto it.
  Subheadings out of order also count as malformed (downstream consumers scan positionally).
- Contains a JSON array of findings (`[{...}, {...}]`) in ANY form — including as an appendix alongside the required
  headings, not only "instead of" them.
- Uses non-standard headings ("Verification summary", "Categorization", "Final findings", or any other heading not in
  the Required findings format).
- Contains free-form prose between or around the required sections (preamble before `## Review Findings`, appendix
  after `### Approved`, or commentary between subheadings).

  EXCEPTION — preamble-only: if the ONLY deviation is prose before `## Review Findings` (the five-section block
  complete and in order, no other criterion firing), do not re-spawn. (An `ESCALATE:` line is never preamble — the
  scoped-review exemption above takes it first.) Scan the preamble for findings-like assertions absent from the block:
  if none, accept the block (discard the preamble from downstream parsing) and emit a one-line chat note recording the
  deviation; if any, treat the response as malformed and follow the On-detection path. On accept, surface the discarded
  preamble verbatim alongside the note (mirroring step 1 below) so a scan false-negative remains recoverable by the user
  rather than silently lost.

On detection:

1. Surface the raw agent output to the user (so the work is not lost).
2. Re-spawn the agent ONCE — same agent type as the malformed dispatch — with a corrective prompt prepended:
   `Your previous response did not follow the Required findings format from your system prompt. Your entire response
   MUST consist of ONLY the Required structure: ## Review Findings heading, then exactly five ### subheadings in the
   prescribed order (Critical, High, Medium, Nice-to-Have, Approved), each followed by bullet items or the literal
   "- None". Do NOT emit JSON arrays, JSON objects, or any other non-markdown structure. Do NOT emit tables, alternative
   section headings, instructional NOTE bullets, preamble, appendix, or prose between sections — markdown bullets only.
   Already tracked (do NOT re-flag, unless a fix delta made one worse — that is a new fix regression to report at its
   real severity): [ALREADY-TRACKED].` The `[ALREADY-TRACKED]` token is a substitution site: fill it with the
   filed/routed issue context Step 1's carry-forward rule mandates, and drop that final sentence entirely when there is
   none.
3. Route the re-spawn's outcome:
   - **Well-formed** → continue normally with its findings.
   - **Still malformed** → terminate `/quality-review` with the malformed-fallthrough body below.
   - **Failed to return at all** (subagent crashed, infrastructure error, timeout) → the agent-unavailable branch below.
   - **Zero-tool-activity return (initial or corrective re-spawn)** — no tool activity and no findings block (harness
     boilerplate, a truncated fragment): the agent never actually ran. This is a startup glitch, not a format refusal,
     and the corrective format prompt does not address it. Before treating that attempt as consumed, resume the same
     agent ONCE via `SendMessage` (`Continue the review you were spawned for; produce only the Required findings format
     from your system prompt`). A well-formed report continues the run normally (in wt mode, `worktree-hygiene.md`'s
     post-delegation checks apply to the resumed turn). If the resume also returns without working, or malformed, the
     attempt is consumed — fall through to the routing above (corrective re-spawn if not yet used; otherwise the
     malformed-fallthrough body).

Verdict body for malformed-fallthrough — pipe it into `quality-review-write-verdict.sh` on stdin, populated per the
opening rule. An example of the shape:

```text
Verdict: terminated-with-open-items
Cycles: 2 (the cycle-2 re-review was malformed; one corrective re-spawn also malformed)
Findings resolved: 3 (CRIT/impl: null-pointer in handler; HIGH/impl: race in retry loop; MED/test: unchecked cast)
Deferred fixed in-session: none
Deferred filed as issues: none
Deferred dropped: none
Open items: agent output malformed across two attempts; manual review required (see chat above for raw outputs)
```

## Reviewer agent unavailable

The `quality-reviewer` or `quality-verifier` subagent type missing, an infrastructure error, or a re-spawn from the
malformed branch that failed to return: surface the failure to the user, then terminate with a body of the shape below,
populated per the opening rule. `Cycles:` counts completed review cycles only (Step 3's initial review plus each Step 5
item 4 re-review); a dispatch that produced no review at all — unavailable, or a zero-tool return whose resume and
corrective re-spawn also failed to produce one — is not a completed cycle, so an initial spawn that never returned
leaves `Cycles: 0`.

```text
Verdict: terminated-with-open-items
Cycles: 2 (initial + 1 re-review)
Findings resolved: 1 (HIGH/impl: unclosed file handle on the error path)
Deferred fixed in-session: none
Deferred filed as issues: none
Deferred dropped: none
Open items: review could not complete; quality-verifier agent unavailable on the cycle-3 re-review (see chat above for failure details)
```

## `quality-review-write-verdict.sh` itself fails

Disk full, perms, mktemp/mv error, a `tmp/` parent unreachable: the persistence layer cannot record the verdict, so
`/finish` Step 1.5 would see `VERDICT=none-found` and fall back to a generic no-artifact refusal — losing the open items
the fallthrough verdict was meant to put in front of the gate. **Exit 3 is not this case**: the verdict IS persisted,
just off-schema or naming a filed issue that is unrouted in Linear — correct the block per the stderr's named fields, or
route the issue with the commands the stderr names, and re-run the same call instead of entering the recovery below.
On a non-zero exit other than 3:

1. Surface the script's stderr to the user immediately.
2. Do NOT silently proceed. Print: `WARNING: /quality-review verdict could not be persisted (see above). /finish for
   this issue will not be gated by this verdict. Either resolve the persistence failure and re-run /quality-review, or
   run /finish with explicit awareness that Step 8's gate cannot read the verdict you just produced.`
3. Continue with the in-memory verdict (still surface the block to the user / caller) so `/start` Step 10 has something
   to render, understanding that `/finish` cannot enforce it. The user decides whether to re-run or proceed manually.

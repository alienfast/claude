# Pluggable issue tracker (Linear + GitHub Issues) — analysis & recommendation

## Context

`~/.claude` is shared across many projects via `alienfast/claude.git`. The high-value workflow
macros — `/start`, `/finish`, `/full`, `/quality-review` (plus `/checkpoint`, `/next`, `/triage`,
`/prd`) — assume **Linear** is the issue tracker. Some projects use Linear; some use **GitHub
Issues**. Today the non-Linear projects can't use these macros (they hard-error when no Linear
issue resolves).

Goal: let GitHub-Issues projects use the same macros **without compromising the full Linear
experience** on Linear projects. The decisions already made: GitHub Issues is the second backend;
a project declares its tracker with an **explicit committed marker that defaults to Linear**; this
document is analysis + recommendation only (no code changes yet).

## How embedded is Linear today?

The mechanics are already factored behind helper scripts, but the *Linear specifics* leak into both
the scripts and the skill **prose** (literal `linear-cli` calls, the `^[A-Z]+-[0-9]+$` ID shape,
state names like "In Progress" / "Ready For Release").

| Macro | Coupling | Already degrades w/o issue? |
|---|---|---|
| `/full` | **None of its own** — pure passthrough to `/start` + `/finish` | inherits |
| `/quality-review` | Optional — review runs without an issue; only requirements-conformance + deferred-filing need it | **Yes** ([SKILL.md:49](../skills/quality-review/SKILL.md#L49)) |
| `/start` | Hard-required — fetch digest, assign, "In Progress", checkpoints, branch name | No (hard error) |
| `/finish` | Hard-required (except `pr` mode) — read verdict, check off items, "Ready For Release" | Partial (`pr` mode skips state) |
| `/checkpoint` | Hard-required — get issue, update checkboxes, post comment | No |

The integration point is one shared script: [detect-issue-id.sh](../scripts/detect-issue-id.sh)
(validates `^[A-Z]+-[0-9]+$`, exit 0 = ID on stdout, exit 1 = none). All Linear I/O flows through a
small set of scripts: `linear-context.sh`, `linear-post.sh`, `mark-ready-for-release.sh`,
`linear-create-child.sh`, `linear-deps-graph.sh`. Team key is derived from the ID prefix
(`PL-13` → `PL`); the repo just **removed** `.linear.yaml` in `609f21e` (team now comes from
`--team`/`$LINEAR_TEAM`).

## Recommended design: capability-tiered adapter, default Linear

Do **not** build a full GitHub mirror of every Linear feature. GitHub Issues structurally lacks
several concepts the Linear workflow leans on, so forced parity would be fragile and would pull the
Linear path through a lossy generic layer. Instead:

1. **Marker file, default Linear.** Add `<project>/.claude/tracker.json` (committed, per-project):

   ```json
   { "tracker": "linear", "team": "PL" }
   ```

   ```json
   { "tracker": "github", "repo": "owner/name",
     "statusLabels": { "inProgress": "status:in-progress", "readyForRelease": "status:ready" } }
   ```

   **Absence ⇒ `linear`.** Every existing project keeps working byte-for-byte with zero migration.
   This also lets us optionally re-localize the team key that `609f21e` pushed to env — a new
   concern (*which tracker*), consolidated into one file rather than the scattered `.linear.yaml`.

2. **Capability interface, not feature parity.** Define a small set of logical operations every
   adapter implements, plus a `capabilities` list. Skills call the *logical* operation and **skip**
   (with a one-line note) any capability the active backend declares unsupported. Linear = superset;
   GitHub = the subset it can support. This is what makes "doing both" non-compromising: Linear
   keeps every feature; GitHub gets an honest subset; the skill prose stops naming `linear-cli`.

3. **Thin dispatch seam.** A new `scripts/detect-tracker.sh` resolves the marker (default `linear`).
   The existing seam scripts become dispatchers that branch on tracker type to `linear-*.sh` or new
   `github-*.sh` implementations. Skill prose changes from "run `linear-cli issues update … --state
   'In Progress'`" to "move the issue to the in-progress state (adapter script)".

## Linear → GitHub Issues mapping (the heart of it)

| Logical op | Linear | GitHub Issues | Notes / gap |
|---|---|---|---|
| Resolve ID | `PL-13` (`^[A-Z]+-[0-9]+$`) | `#123` / `123` | broaden detection + branch-name convention; `#123` auto-links in GH commits |
| Fetch context | `linear-context.sh` digest | `gh issue view --json` | **no anchored comments**; parent via sub-issues API |
| Assign + In Progress | `--assignee me --state "In Progress"` | `gh issue edit --add-assignee @me` + status **label** | GH has no native workflow states |
| Comment | `issues comment` | `gh issue comment` | parity |
| Update body / checkboxes | `linear-post.sh description` | `gh issue edit --body-file` | task-list `- [ ]` is native → parity |
| Ready For Release / Done | state transition | `status:ready` label; **close** on PR merge (`Fixes #123`) | no "Ready For Release" state — semantic map |
| Sub-issue + parent link | `linear-create-child.sh` (+verify) | sub-issues API / body reference | GraphQL-only, newer, verify differs |
| Blocker graph | `linear-deps-graph.sh` (relations) | **none native** | **biggest gap** → declare unsupported or convention |
| Cycle / `/next` ranking | cycle + dep graph | milestones ≈ cycles; no triage state | ranking tiers partly unavailable |

**Recommended status mapping:** plain **labels** (`gh issue edit --add-label`) as the baseline — no
Projects v2 dependency, visible on the issue, works in any repo. Projects v2 board columns are the
"real" GitHub model but are GraphQL-only and require a board to exist; make them an opt-in upgrade
via the marker, not the default.

## Risks

1. **Impedance mismatch (inherent, not fixable).** GitHub lacks workflow states, blocking relations,
   cycles, triage, anchored comments. The GitHub path is lower-fidelity by nature and leans on
   per-repo conventions (labels/milestones) that can drift. → Mitigate with the capability interface:
   skip-and-note rather than fake it.
2. **Silent degradation of a Linear project** — the failure mode you most want to avoid. → Mitigated
   structurally: default = Linear, and **Linear mode errors (never silently skips)** when no ID
   resolves. A Linear repo can't quietly fall into another mode because the marker is explicit.
3. **Doubled surface area / bit-rot.** Two backends through every macro; the less-used path rots. →
   Stable script contracts + capability flags keep skill prose backend-agnostic and contain the blast
   radius.
4. **Prose ↔ script coupling.** Linear literals live in skill prose, not only scripts; generalizing
   to logical ops is the bulk of the edit and a place the model could mis-follow if conditionals
   bloat the prose. → Push backend literals down into adapter scripts; keep prose mode-free.
5. **Tooling divergence.** `linear-cli` (OAuth/API key) vs `gh` (already a dependency for PRs) —
   different auth, errors, rate limits. GitHub sub-issues/Projects v2 are GraphQL-only and newer, so
   more brittle (`gh api graphql`).
6. **Hook + convention touchpoints.** [full-continue.sh](../hooks/full-continue.sh) parses lifecycle
   tags expecting `^[A-Z]+-[0-9]+`; `/finish` enforces the ID in commit messages for auto-linking.
   Both must broaden the accepted ID shape.
7. **Verification burden.** Validating the GitHub adapter needs a real GitHub-Issues repo; can't be
   fully exercised from baseFund.

## Does doing both compromise Linear?

**No loss of Linear capability** — if and only if it's built as *default-Linear + capability-superset
adapter + explicit opt-out*. The Linear path stays exactly as today; GitHub is additive and gated
behind the marker. The genuine cost is **not** fewer Linear features — it's (a) the maintenance of a
second, structurally weaker backend and (b) the one-time prose generalization. The only real risk
*to* Linear is the silent-degradation footgun in risk #2, which the explicit-marker + error-don't-
degrade design specifically neutralizes. So: you take on upkeep and a lower-fidelity GitHub path, but
you do not give up any Linear feature.

## Suggested phasing (for when you decide to build)

1. **Seam + marker:** add `detect-tracker.sh`, generalize `detect-issue-id.sh` to be tracker-aware,
   define the capability interface, wire the default-Linear marker. No behavior change for Linear.
2. **GitHub adapter:** `github-context.sh`, `github-post.sh`, `github-transition.sh` (labels),
   `github-create-child.sh`; declare blocker-graph / cycles / anchored-comments unsupported.
3. **Prose generalization:** convert `start`/`finish`/`checkpoint`/`quality-review`/`next`/`triage`/
   `prd` prose to logical ops; broaden `full-continue.sh` and the commit-ID enforcement.
4. **Validate** end-to-end on a real GitHub-Issues repo.

## Verification (when implemented)

- **Linear regression:** run `/full PL-XX wt` on baseFund and confirm byte-identical behavior
  (no marker present → `linear` path).
- **GitHub happy path:** on a marked GitHub repo, `/start 123` assigns + labels in-progress; a
  checkpoint posts a comment + checks a task-list item; `/finish` opens a PR with `Fixes #123` and
  applies the ready/close mapping.
- **Footgun guard:** in a Linear repo, invoke a macro with no resolvable ID → confirm it **errors**
  (does not skip Linear). In a GitHub repo, confirm unsupported steps (blocker check) are **skipped
  with a note**, not failed.
</content>

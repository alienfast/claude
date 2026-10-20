# Deferrals — recall, re-measure, file, lift

Read this at Phase 0.5 (recall) and again at Phase 5 (filing and closing). Every hold, pin, and cooldown bypass an
earlier run took to get by is a `dependencies`-labelled Linear issue carrying a **lift condition**. Recall is what makes
those temporary: the run re-measures each one and lifts what has cleared, instead of re-researching the same package or
taking a bump a previous run measured as broken. A hold nobody re-tests is a permanent pin with extra steps.

## Phase 0.5 — recall prior deferrals (read-only; runs on `--dry-run` too)

1. **List the open set.** `linear-cli issues list -t <TEAM> -l dependencies -o json` (`-l` is a single filter value
   here, unlike the repeatable `-l` on `create`/`update`; raise `--limit` if the set has grown). Drop terminal states by
   **name** — the list rows carry `state` as `{name}` only, so a `.state.type` filter passes every row silently. Read
   the names from `linear-cli statuses list -t <TEAM> -o json`, whose rows do carry `type`: drop every state whose
   `type` is `completed`, `canceled`, or `duplicate` (a duplicate is its own type). Drop the issue Phase 0 just filed.
   The list rows omit `description`, so read each survivor with `linear-cli issues get <ID> -o json` (`.description`
   is bare — no `.issue.` envelope).
2. **A previous sweep's own tracking issue still open is an abandoned run.** Its worktree (`.claude/worktrees/<id-lower>`)
   or branch may hold the only copy of uncommitted work. Say so and stop for a decision rather than starting a second
   sweep on top of it.
3. **Re-measure every lift condition now, on this machine.** The condition is written as a command or a date precisely
   so it can be executed rather than reasoned about — `npm view <pkg>@<ver> peerDependencies`, `npm view
   <upstream>@<ver> dependencies.<pinned>`, a cooldown expiry against today's date. Do not re-read the blocker's
   changelog; the recorded evidence is what to re-test. Then classify:
   - **Cleared** → the package joins this run's apply set at ncu's target with no hold in Phase 3; the pin or bypass
     comes out of `pnpm-workspace.yaml` / `.ncurc.*` in the same change; and the issue is closed in Phase 5 once the
     gate has passed — never before.
   - **Still blocked** → keep the hold in Phase 3 exactly as recorded, skip Phase 2 research for it, and post one dated
     comment on the issue: what you measured, verbatim, plus the sweep issue's id.
   - **Needs work** — the issue's remedy is a change a sweep should not absorb (a gate script, a CI pin, a rollout that
     lands work on every teammate) → leave it for its own pickup. Do not absorb it, and do not re-hold anything for it
     unless its lift condition says so. Name it in the summary as still open.
4. **A `--filter` narrows what may lift, not what is recalled.** Recall everything, act only on what the filter admits,
   and say which deferrals were skipped for that reason.

A package covered by a still-open `dependencies` issue is not researched again in Phase 2 — the issue *is* the research.
The one exception is the advisory sweep, which always covers the whole set: an advisory can land on a held package after
the hold was recorded, and that changes whether the hold is still the right call.

## Phase 5 — file this run's deferrals

File deferrals before composing the summary, so the summary can cite them by id. A deferral is anything this run decided
*not* to take, and its reason has to be measured, not felt:

- a **hold** — a package kept below ncu's target because a peer range, a runtime version gate, or a red lane says the
  target breaks something. Quote the range, the error, or the lane.
- a **pin or bypass** added to get by — an `overrides` entry, a version-scoped `minimumReleaseAgeExclude`, an `.ncurc.*`
  `reject`.
- an advisory whose fix exists only in a **cooldown-held** version (Phase 2's advisory sweep names these).
- a cleanup the research surfaced that a sweep should not do alone — an override upstream has since made redundant or
  inverted, a deprecated import path with a removal date.
- the package still red after Phase 4's two fix rounds, with the gate's own error as the evidence in its lift condition.

File each with `~/.claude/scripts/linear-create-child.sh - <TEAM> - "<title>" <body-file> dependencies` — the sixth
positional is the label; exit 2 means filed-but-unlabelled, so attach it with `~/.claude/scripts/linear-add-label.sh
<ID> dependencies`. One issue per package or mechanism, not one per run; a set that moves together (`vitest` +
`@vitest/browser` + `@vitest/browser-playwright`) is one issue. The body takes the spec shape (Problem / Desired Outcome
/ Success Criteria) plus the section recall depends on:

```md
## Lift condition

Type: hold | pin | needs-work
Check: <one command, or a date, the next run executes verbatim>
Lifts when: <the exact output or date that means "take it now">
```

`Check` is what makes the deferral self-healing rather than self-repeating: `npm view @storybook/addon-vitest
peerDependencies.vitest` admitting `^5`; `npm view @descope/web-js-sdk@<ver> dependencies.js-cookie` at or above the
override it justifies; the cooldown date. Something the next run can run without re-reading anything. `needs-work` is
the one type with no mechanical check — say what the work is, so the next run leaves it for its own pickup.

## Phase 5 — close what this run lifted

Only after the gate passed and the change shipped. For each issue recall marked *cleared*: transition it to the state
`/finish` left the sweep issue in — read the name from `linear-cli issues get <SWEEP-ID> -o json | jq -r .state.name`
rather than hardcoding one, so a `pr` finish (issue still In Progress, PR open) and a `merge` finish move it the same way
the sweep moved — add a comment naming the sweep and the measurement that cleared it, and wire `linear-cli relations add
<DEFERRED> <SWEEP-ID> -r related`. A lift that reddened the gate in Phase 4 goes back to *still blocked* with the new
evidence instead.

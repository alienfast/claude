---
name: linear-setup
description: Bring a Linear team's issue statuses, issue labels, and saved views to the house model — the exact set the basefund `BF` team runs on, exported into this skill. Checks a team for gaps, applies the missing or drifted pieces idempotently through the Linear API (never deletes), renames Linear's default `Todo` to `Planned`, wires the project's `LINEAR_TEAM`/`LINEAR_CLI_PROFILE`, and re-exports the model when BF changes. Use when the user says 'linear setup', 'set up Linear for this project/workspace/team', 'replicate BF's statuses/labels/views', 'check the Linear config', 'new Linear workspace', 'bootstrap a Linear team', or invokes /linear-setup.
---

# Linear Setup

The Linear board is the control plane the skills read from, and they match on **exact names**: `/spec`, `/start`, and
`/auto` write the states `Planned` and `Ready for Release`; `next-candidates.sh` gates on `specified`, hides
`needs decision` / `human` / `solo` / `keeper`, and boosts `security` / `bug`; the saved views are how a stakeholder sees
the board without the fleet's own technical issues. A team missing any of it fails quietly. This skill makes a team match
the model in one converging pass instead of a hand-edited checklist.

**The model** is [assets/model.json](assets/model.json), exported from `basefund/BF` (team name `Product`). It is
portable: the source team's id is stored as `${TEAM_ID}` and its name as `${TEAM_NAME}`, both substituted for the
target at check/apply time — so BF's `Product: Simple` becomes `Ops: Simple` on a team named `Ops`. The model covers:

| Kind | What is synced | Not synced (report only, or out of scope) |
| --- | --- | --- |
| Statuses | every workflow state (name, type, color, position, description), the team's triage toggle, its default issue state | extra states the target has (never deleted — `rename` or archive by hand); a state whose **type** differs (immutable — archive and re-run) |
| Labels | every workspace-level issue label (name, color, description, groups + parents); `required: true` marks the load-bearing ones | team-scoped labels (BF has none; a same-named one on the target is reported as a conflict) |
| Views | the team's **shared** Issue views whose filters reference only the team and label names | views filtering on assignees, projects, or other teams (workspace-specific ids — skipped at export); personal/unshared views; workspace-level views; Project views |
| Team | `triageEnabled`, `defaultIssueState` | cycles, estimates, templates, members, auto-archive |

All logic lives in [scripts/linear-setup.sh](scripts/linear-setup.sh) (the diff itself in [scripts/plan.jq](scripts/plan.jq)); this
skill dispatches to it and narrates. Every mutation is raw GraphQL through `linear-cli api mutate` — the dedicated
`views create` / `labels create` commands cannot carry `filterData`, icons, or descriptions, and there is no
`statuses create` at all.

## Arguments

`/linear-setup [check | apply | rename FROM TO | export] [TEAM] [--profile P]`

- **(none)** or `check` — read-only diff of the team against the model. Default.
- `apply` — create/update the gaps, then re-check. Converges: a second run plans zero mutations.
- `rename FROM TO` — rename one workflow state. Made for Linear's default `Todo` → `Planned`.
- `export` — refresh the model from a live team. Only meaningful against the model team (see *Refreshing the model*).

`TEAM` defaults to `LINEAR_TEAM`; `--profile` selects a `linear-cli` workspace profile and defaults to linear-cli's own
selection (`LINEAR_CLI_PROFILE`, then the config's `current`).

## Workflow

1. **Resolve the target.** Team key from the argument or `LINEAR_TEAM`; profile from the project's
   `.claude/settings.local.json` (`env.LINEAR_CLI_PROFILE`) when the project is not in the default workspace. Confirm
   the key reaches the right workspace before anything else:

   ```bash
   linear-cli --profile <P> whoami -o json | jq -c '{name, email, admin, url}'
   ```

   `Account disabled` (HTTP 400, `FORBIDDEN`) means the stored key belongs to a suspended account, not a CLI fault —
   the user mints a new personal API key while logged into **that** workspace, then
   `linear-cli --profile <P> auth login --key <key>`. Stop here until it answers; nothing below can run.

2. **Check.** Run it and show the table verbatim — every row is `KIND op [*] name — detail`, `*` marking a load-bearing
   item:

   ```bash
   ~/.claude/skills/linear-setup/scripts/linear-setup.sh check --team <KEY> --profile <P>
   ```

   Exit 0 is converged; 1 means gaps; 2 is an error. Read the **header line** — it prints the workspace the API actually
   answered for. On a triage-off team expect both `TEAM update triageEnabled` and `STATE create Triage`: apply flips
   the toggle first and Linear mints the state, so the create resolves to an update on the re-plan.

3. **Resolve what apply will not do for you**, before applying:
   - `STATE extra Todo` on a fresh team → `rename --team <KEY> Todo Planned` first. Applying first creates `Planned`
     beside `Todo`, and then `Todo` has to be archived by hand in Linear with any issues moved.
   - `conflict` rows — a state whose type differs, a team-scoped label with a model name — are fixed in the Linear UI;
     the detail column says how. Apply proceeds around them and exits 1 until they are gone.
   - `extra` rows are informational: nothing is ever deleted. Duplicate-named views are flagged as extras with their owner.

4. **Confirm the header's workspace/team with the user, then apply** (`--dry-run` shows the plan and runs nothing).
   Applying BF's model to the wrong workspace is reversible but noisy — labels and views appear for everyone there.

   ```bash
   ~/.claude/skills/linear-setup/scripts/linear-setup.sh apply --team <KEY> --profile <P>
   ```

   It re-snapshots between phases (triage → states → default state → label groups → labels + views), prints each
   mutation, clears linear-cli's statuses cache (linear skill gotcha #23: a state minted seconds ago is otherwise
   invisible to `mark-ready-for-release.sh` and friends), and ends with the post-apply table. Exit 0 = converged.

5. **Wire the project.** In the project repo, `.claude/settings.json` sets `env.LINEAR_TEAM` to the key (committed —
   every team-resolving skill reads it). If the workspace is not the machine's default profile, `.claude/settings.local.json`
   sets `env.LINEAR_CLI_PROFILE` to the profile name (gitignored, machine-local; an unknown profile fails closed rather
   than falling back to the default workspace). Add a one-line note to the project's `CLAUDE.md` naming the workspace
   and the profile variable, as `bfp-control-panel` does.

6. **Report**: the final table, what was created, what remains manual (extras, conflicts), and the wiring written.

## Refreshing the model

BF is the model. When its statuses, labels, or views change deliberately, re-export **from BF** and review the diff —
the check against BF itself doubles as a drift detector (the header says `this team IS the model's source`):

```bash
~/.claude/skills/linear-setup/scripts/linear-setup.sh export --team BF --profile basefund
git -C ~/.claude diff -- skills/linear-setup/assets/model.json
```

Export rules: shared Issue views on the team only; a view whose filter still contains any UUID after the team-id
substitution is skipped and listed under `skipped.views` with its reason; two views sharing a name keep the oldest;
labels are the workspace-level set with `required` stamped from the roster in the script (`REQUIRED_LABELS` — the
names `linear-for-stakeholders.md` says never to rename, plus `epic`). Team-name substitution is a literal replace of
the source team's name in view names and descriptions (skipped for names under three characters), so a team whose name
is an ordinary word will see that word templated wherever it appears in a view description. Commit the refreshed model
through the keeper flow like any other `~/.claude` change; other machines pick it up on `/update`.

## Gotchas

- **Order matters once: rename before apply.** Everything else converges in any order.
- **Triage may need a paid plan.** If `teamUpdate {triageEnabled}` is refused, the `Triage` state cannot exist either;
  apply reports the error and stops — tell the user, do not retry.
- **View match is by exact substituted name.** Renaming a view in Linear makes the model re-create it under the model
  name and flag the renamed one as `extra`; rename it back or delete the extra.
- **`filterData` is stored verbatim** (measured: byte-identical round-trip on basefund), so a `filterData` drift row is a
  real difference, not API normalization.
- **This is provisioning, not migration.** It never moves issues, deletes anything, or touches members, cycles, or
  templates. A team that already has issues in `Todo` needs the `rename`, not a new `Planned`.
- **Tests**: `scripts/linear-setup.test.sh` runs the script against a stateful `linear-cli` shim and is wired into
  `~/.claude`'s `pnpm test`; run it after editing the script or `plan.jq`.

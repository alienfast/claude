#!/usr/bin/env bash
# linear-setup.sh — bring a Linear team's issue statuses, issue labels, and saved views to the house model.
#
# Usage:
#   linear-setup.sh export --team KEY [--profile P] [--out FILE]          snapshot a live team into a portable model
#   linear-setup.sh check  --team KEY [--profile P] [--model FILE]        diff a team against the model (read-only)
#   linear-setup.sh apply  --team KEY [--profile P] [--model FILE] [--dry-run]
#   linear-setup.sh rename --team KEY [--profile P] <FROM> <TO>           rename one workflow state (e.g. Todo → Planned)
#
# The model (default: ../assets/model.json, exported from basefund/BF) is portable: the source team's id is stored as
# ${TEAM_ID} and its name as ${TEAM_NAME}; both are substituted for the target team at check/apply time. Views whose
# filters reference any OTHER workspace-specific id (assignees, projects, other teams) are skipped at export because
# nothing could translate them. `apply` only creates and updates — it never deletes, archives, or renames on its own —
# and converges: a second run plans zero mutations. plan.jq beside this script owns the diff.
#
# --profile is passed through to linear-cli; without it linear-cli's own selection applies (LINEAR_CLI_PROFILE, then the
# config's `current`). The header line prints the organization the API actually answered for — read it before `apply`.
#
# Exit codes: 0 converged / done · 1 gaps remain (check) or apply left conflicts · 2 usage, dependency, or API error.
set -euo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN_JQ="$HERE/plan.jq"
DEFAULT_MODEL="$HERE/../assets/model.json"

# Labels the automation matches on by exact name (linear-for-stakeholders.md § Do not rename or delete; linear-workflow.md
# for `epic`). Flagged `required` in the model so a check report separates load-bearing gaps from cosmetic ones.
REQUIRED_LABELS=("specified" "needs decision" "human" "solo" "simple" "epic" "reflection" "stalled" "security" "bug" "keeper")
# States the skills write by literal name (Planned, Ready for Release) or key ranking on (the rest).
REQUIRED_STATES=("Triage" "Backlog" "Planned" "In Progress" "Ready for Release" "Done" "Canceled" "Duplicate")

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "ERROR: $*" >&2; exit 2; }

SUB="${1:-}"
[ -n "$SUB" ] || { usage >&2; exit 2; }
shift
case "$SUB" in export|check|apply|rename) ;; -h|--help) usage; exit 0 ;; *) die "unknown subcommand '$SUB'" ;; esac

PROFILE="" TEAM="${LINEAR_TEAM:-}" MODEL="$DEFAULT_MODEL" OUT="" DRY=0
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) [ $# -ge 2 ] || die "--profile needs a value"; PROFILE="$2"; shift 2 ;;
    --team)    [ $# -ge 2 ] || die "--team needs a value";    TEAM="$2";    shift 2 ;;
    --model)   [ $# -ge 2 ] || die "--model needs a value";   MODEL="$2";   shift 2 ;;
    --out)     [ $# -ge 2 ] || die "--out needs a value";     OUT="$2";     shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) die "unknown option '$1'" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

for cmd in linear-cli jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' not found on PATH"
done
[ -n "$TEAM" ] || die "--team KEY is required (LINEAR_TEAM is not set)"
[[ "$TEAM" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || die "team key '$TEAM' does not look like a Linear team key"
TEAM="$(printf '%s' "$TEAM" | tr '[:lower:]' '[:upper:]')"
[ -f "$PLAN_JQ" ] || die "plan.jq missing beside this script ($PLAN_JQ)"
if [ "$SUB" != "export" ]; then
  [ -f "$MODEL" ] || die "model not found: $MODEL (run 'export' against the model team first)"
  jq -e '.states and .labels and .views' "$MODEL" >/dev/null 2>&1 || die "model $MODEL lacks states/labels/views"
fi

lc() { linear-cli ${PROFILE:+--profile "$PROFILE"} "$@"; }

# gql <query|mutate> <document> [-v k=v ...] — dies on transport errors, HTTP errors, and GraphQL `errors`; prints the envelope.
gql() {
  local mode="$1" doc="$2"; shift 2
  local out rc=0
  out=$(lc api "$mode" "$doc" "$@" 2>&1) || rc=$?
  if [ $rc -ne 0 ] || ! jq -e 'type == "object" and has("data") and (has("errors") | not) and ((.error // false) != true)' <<<"$out" >/dev/null 2>&1; then
    echo "ERROR: linear-cli api $mode failed (exit $rc)${PROFILE:+ [profile $PROFILE]}:" >&2
    printf '%s\n' "$out" | head -c 2000 >&2; echo >&2
    if grep -q 'Account disabled' <<<"$out"; then
      echo "HINT: the API key for this profile belongs to a disabled account — mint a new personal API key while logged into the target workspace, then: linear-cli --profile <name> auth login --key <key>" >&2
    fi
    exit 2
  fi
  printf '%s' "$out"
}

# Live snapshot of one team: org, team (+states), every issue label in the workspace, the team's Issue views.
fetch_snapshot() {
  local team_json labels_json views_json
  team_json=$(gql query 'query($key: String!) { organization { name urlKey } teams(filter: { key: { eq: $key } }) { nodes { id key name triageEnabled defaultIssueState { id name } states { nodes { id name type color position description } } } } }' -v "key=\"$TEAM\"")
  jq -e '.data.teams.nodes | length == 1' <<<"$team_json" >/dev/null \
    || die "team '$TEAM' not found in workspace '$(jq -r '.data.organization.urlKey' <<<"$team_json")'"
  labels_json=$(gql query 'query { issueLabels(first: 250) { nodes { id name color description isGroup team { key } parent { name } } } }')
  views_json=$(gql query 'query { customViews(first: 250) { nodes { id name description icon color shared modelName filterData createdAt team { id } owner { name } } } }')
  jq -n --argjson t "$team_json" --argjson l "$labels_json" --argjson v "$views_json" '
    ($t.data.teams.nodes[0]) as $team
    | { org: $t.data.organization,
        team: ($team | {id, key, name, triageEnabled, defaultIssueState, states: .states.nodes}),
        labels: $l.data.issueLabels.nodes,
        views: [ $v.data.customViews.nodes[] | select(.modelName == "Issue" and .team.id == $team.id) ] }'
}

header() { # $1 snapshot
  jq -r --arg model "$MODEL" '"linear-setup: workspace \(.org.name) (\(.org.urlKey)) · team \(.team.key) \"\(.team.name)\" · \(.team.states|length) states, \(.labels|length) labels, \(.views|length) team views"' <<<"$1"
  if [ "$SUB" != "export" ]; then
    jq -r --arg model "$MODEL" '"model: \($model) — exported from \(.source.organization)/\(.source.team) at \(.source.exportedAt)"' "$MODEL"
    if jq -e --argjson s "$1" '.source.organization == $s.org.urlKey and .source.team == $s.team.key' "$MODEL" >/dev/null; then
      echo "note: this team IS the model's source — a clean check here means the model is current; drift means re-export"
    fi
  fi
}

plan() { # $1 snapshot → action array
  jq -f "$PLAN_JQ" --slurpfile model "$MODEL" \
    --arg team_id "$(jq -r '.team.id' <<<"$1")" --arg team_name "$(jq -r '.team.name' <<<"$1")" <<<"$1"
}

print_plan() { # $1 actions
  jq -r '.[] | "  \(((.kind | ascii_upcase) + "      ")[0:6]) \((.op + "         ")[0:9]) \(if .required == true then "*" else " " end) \(.name)\(if (.detail // "") != "" then "  — " + .detail else "" end)"' <<<"$1"
}

summary() { # $1 actions → prints counts; returns 0 when nothing is missing/drifted/conflicting
  jq -r '"  ok \(map(select(.op=="ok"))|length) · create \(map(select(.op=="create"))|length) · update \(map(select(.op=="update"))|length) · conflict \(map(select(.op=="conflict"))|length) · extra \(map(select(.op=="extra"))|length)"' <<<"$1"
  jq -e 'map(select(.op == "create" or .op == "update" or .op == "conflict")) | length == 0' <<<"$1" >/dev/null
}

mutate_ok() { # $1 envelope $2 payload field — dies unless success:true
  jq -e --arg f "$2" '.data[$f].success == true' <<<"$1" >/dev/null || { echo "ERROR: $2 reported success:false — $1" >&2; exit 2; }
}

# resolve_id <snapshot> <states|labels> <name> — id of the (case-insensitive) named object, or empty
resolve_id() {
  jq -r --arg n "$3" --arg k "$2" '(if $k == "states" then .team.states else .labels | map(select(.team == null)) end) | map(select((.name|ascii_downcase) == ($n|ascii_downcase))) | first | .id // empty' <<<"$1"
}

# run_actions <snapshot> <actions> <jq select filter> — executes the selected create/update actions in order
run_actions() {
  local snap="$1" actions="$2" filter="$3" a kind op name input id res
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    kind=$(jq -r .kind <<<"$a"); op=$(jq -r .op <<<"$a"); name=$(jq -r .name <<<"$a")
    input=$(jq -c .input <<<"$a"); id=$(jq -r '.id // empty' <<<"$a")
    case "$kind/$op" in
      team/update)
        if [ "$name" = "defaultIssueState" ]; then
          local want sid; want=$(jq -r .input.defaultIssueStateName <<<"$a"); sid=$(resolve_id "$snap" states "$want")
          [ -n "$sid" ] || { echo "  SKIP  team defaultIssueState — state '$want' not present yet" >&2; continue; }
          input=$(jq -cn --arg id "$sid" '{defaultIssueStateId: $id}')
        fi
        res=$(gql mutate 'mutation($id: String!, $input: TeamUpdateInput!) { teamUpdate(id: $id, input: $input) { success } }' -v "id=\"$(jq -r .team.id <<<"$snap")\"" -v "input=$input")
        mutate_ok "$res" teamUpdate; echo "  team    updated  $name" ;;
      state/create)
        input=$(jq -c --arg tid "$(jq -r .team.id <<<"$snap")" '. + {teamId: $tid}' <<<"$input")
        res=$(gql mutate 'mutation($input: WorkflowStateCreateInput!) { workflowStateCreate(input: $input) { success workflowState { id name } } }' -v "input=$input")
        mutate_ok "$res" workflowStateCreate; echo "  state   created  $name" ;;
      state/update)
        res=$(gql mutate 'mutation($id: String!, $input: WorkflowStateUpdateInput!) { workflowStateUpdate(id: $id, input: $input) { success } }' -v "id=\"$id\"" -v "input=$input")
        mutate_ok "$res" workflowStateUpdate; echo "  state   updated  $name" ;;
      label/create|label/update)
        local parent pid; parent=$(jq -r '.parent // empty' <<<"$a")
        if [ -n "$parent" ]; then
          pid=$(resolve_id "$snap" labels "$parent")
          [ -n "$pid" ] || { echo "  SKIP  label $name — parent group '$parent' not present yet" >&2; continue; }
          input=$(jq -c --arg pid "$pid" '. + {parentId: $pid}' <<<"$input")
        fi
        if [ "$op" = create ]; then
          res=$(gql mutate 'mutation($input: IssueLabelCreateInput!) { issueLabelCreate(input: $input) { success issueLabel { id name } } }' -v "input=$input")
          mutate_ok "$res" issueLabelCreate; echo "  label   created  $name"
        else
          res=$(gql mutate 'mutation($id: String!, $input: IssueLabelUpdateInput!) { issueLabelUpdate(id: $id, input: $input) { success } }' -v "id=\"$id\"" -v "input=$input")
          mutate_ok "$res" issueLabelUpdate; echo "  label   updated  $name"
        fi ;;
      view/create)
        res=$(gql mutate 'mutation($input: CustomViewCreateInput!) { customViewCreate(input: $input) { success customView { id name } } }' -v "input=$input")
        mutate_ok "$res" customViewCreate; echo "  view    created  $name" ;;
      view/update)
        res=$(gql mutate 'mutation($id: String!, $input: CustomViewUpdateInput!) { customViewUpdate(id: $id, input: $input) { success } }' -v "id=\"$id\"" -v "input=$input")
        mutate_ok "$res" customViewUpdate; echo "  view    updated  $name" ;;
      *) die "internal: unexpected action $kind/$op" ;;
    esac
  done < <(jq -c ".[] | $filter" <<<"$actions")
}

cmd_export() {
  local snap out; snap=$(fetch_snapshot); header "$snap"
  out="${OUT:-$MODEL}"; mkdir -p "$(dirname "$out")"
  local req_l req_s; req_l=$(printf '%s\n' "${REQUIRED_LABELS[@]}" | jq -R . | jq -sc .); req_s=$(printf '%s\n' "${REQUIRED_STATES[@]}" | jq -R . | jq -sc .)
  jq --arg exported_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson req_labels "$req_l" --argjson req_states "$req_s" '
    def lc: ascii_downcase;
    def uuid_re: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
    .team.id as $tid | .team.name as $tname
    # Literal (not regex) substitution of the team name in view names/descriptions; skipped for very short names,
    # where a substring hit would be noise rather than a reference to the team.
    | def ph_name: if ($tname | length) >= 3 then split($tname) | join("${TEAM_NAME}") else . end;
    def ph_id: gsub($tid; "${TEAM_ID}");
    def is_req($set): ((.name | lc) as $n | any($set[]; (. | lc) == $n));
    ([ .views[] | select(.shared == true) ] | sort_by(.createdAt)) as $shared
    | ($shared | map(. + {name: (.name | ph_name), description: ((.description // null) | if . == null then null else ph_name end),
                          filterText: (.filterData | tojson | ph_id)})) as $vs
    | ($vs | map(select(.filterText | test(uuid_re)) | {name, reason: "filter references workspace-specific ids (assignee/project/other team) — not portable"})) as $skipped_ids
    | ($vs | map(select(.filterText | test(uuid_re) | not)) | group_by(.name)) as $groups
    | ($groups | map(select(length > 1) | .[1:][] | {name, reason: "duplicate name — kept the oldest"})) as $skipped_dups
    | {
        source: {organization: .org.urlKey, team: .team.key, teamName: $tname, exportedAt: $exported_at},
        team: {triageEnabled: .team.triageEnabled, defaultIssueState: .team.defaultIssueState.name},
        states: ([ .team.states[] | {name, type, color, position, description: (.description // null), required: is_req($req_states)} ] | sort_by(.position, .name)),
        labels: ([ .labels[] | select(.team == null) | {name, color, description: (.description // null), isGroup: (.isGroup // false), parent: (.parent.name // null), required: is_req($req_labels)} ] | sort_by(.name | lc)),
        views:  ([ $groups[] | .[0] | {name, description, icon: (.icon // null), color: (.color // null), filterData: (.filterText | fromjson)} ] | sort_by(.name)),
        skipped: {views: ($skipped_ids + $skipped_dups)}
      }' <<<"$snap" > "$out"
  jq -r --arg out "$out" '"wrote \($out): \(.states|length) states, \(.labels|length) labels (\([.labels[]|select(.required)]|length) required), \(.views|length) views" + (if (.skipped.views|length) > 0 then "\n  skipped views:\n" + ([.skipped.views[] | "    - \(.name): \(.reason)"] | join("\n")) else "" end)' "$out"
}

cmd_check() {
  local snap actions; snap=$(fetch_snapshot); header "$snap"; actions=$(plan "$snap")
  print_plan "$actions"
  if summary "$actions"; then echo "converged: nothing to create or update"; exit 0; fi
  echo "gaps remain — run: linear-setup.sh apply --team $TEAM${PROFILE:+ --profile $PROFILE}"; exit 1
}

cmd_apply() {
  local snap actions; snap=$(fetch_snapshot); header "$snap"; actions=$(plan "$snap")
  echo "plan:"; print_plan "$actions"
  local n; n=$(jq 'map(select(.op == "create" or .op == "update")) | length' <<<"$actions")
  if [ "$DRY" = 1 ]; then summary "$actions" || true; echo "dry-run: $n mutation(s) would run; nothing changed"; exit 0; fi
  if [ "$n" = 0 ]; then summary "$actions" && { echo "converged: nothing to do"; exit 0; } || { echo "nothing to apply, but conflicts remain (fix in Linear, then re-run check)"; exit 1; }; fi
  echo "applying:"
  # Phase 1 — triage on (Linear mints the Triage state itself). Phase 2 — states. Phase 3 — everything that depends on
  # states existing (default state) or on other labels existing (groups before children), then views. Re-snapshot between
  # phases so each phase resolves ids the previous one just created.
  run_actions "$snap" "$actions" 'select(.kind == "team" and .name == "triageEnabled")'
  snap=$(fetch_snapshot); actions=$(plan "$snap")
  run_actions "$snap" "$actions" 'select(.kind == "state" and (.op == "create" or .op == "update"))'
  snap=$(fetch_snapshot); actions=$(plan "$snap")
  run_actions "$snap" "$actions" 'select(.kind == "team" and .name == "defaultIssueState")'
  run_actions "$snap" "$actions" 'select(.kind == "label" and .op == "create" and .input.isGroup == true)'
  snap=$(fetch_snapshot); actions=$(plan "$snap")
  run_actions "$snap" "$actions" 'select(.kind == "label" and (.op == "create" or .op == "update"))'
  run_actions "$snap" "$actions" 'select(.kind == "view" and (.op == "create" or .op == "update"))'
  # Other scripts resolve states through linear-cli's Statuses cache (linear skill gotcha #23) — a state minted seconds
  # ago is invisible to them until it expires or is cleared.
  lc cache clear >/dev/null 2>&1 || true
  echo "result:"; snap=$(fetch_snapshot); actions=$(plan "$snap"); print_plan "$actions"
  if summary "$actions"; then echo "converged"; exit 0; fi
  echo "not converged — see conflicts above"; exit 1
}

cmd_rename() {
  [ ${#POSITIONAL[@]} -eq 2 ] || die "rename needs exactly two arguments: <FROM> <TO>"
  local from="${POSITIONAL[0]}" to="${POSITIONAL[1]}" snap fid tid res
  local snap; snap=$(fetch_snapshot); header "$snap"
  fid=$(resolve_id "$snap" states "$from"); [ -n "$fid" ] || die "no state named '$from' on $TEAM"
  tid=$(resolve_id "$snap" states "$to");   [ -z "$tid" ] || die "a state named '$to' already exists on $TEAM"
  if [ "$DRY" = 1 ]; then echo "dry-run: would rename state '$from' → '$to'"; exit 0; fi
  res=$(gql mutate 'mutation($id: String!, $input: WorkflowStateUpdateInput!) { workflowStateUpdate(id: $id, input: $input) { success workflowState { name } } }' -v "id=\"$fid\"" -v "input=$(jq -cn --arg n "$to" '{name: $n}')")
  mutate_ok "$res" workflowStateUpdate; lc cache clear >/dev/null 2>&1 || true
  echo "  state   renamed  $from → $to"
}

"cmd_$SUB"

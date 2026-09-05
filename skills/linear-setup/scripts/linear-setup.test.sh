#!/usr/bin/env bash
# Regression suite for linear-setup.sh. linear-cli is a PATH shim backed by per-profile fixture files that the shim
# MUTATES (creates append, updates patch by id, teamUpdate{triageEnabled} mints a Triage state the way Linear does,
# viewPreferencesUpdate REPLACES the preference object the way Linear does), so `apply` is proven to CONVERGE against a
# stale target — not merely to emit mutations. Covers: export placeholders and skip rules (including the workspace-level
# base view and the non-team workspace view it must ignore), display preferences and favorite flags, the check plan and
# its exit code, dry-run emitting nothing, apply's phase order (triage → states → default state → labels → views →
# favorites) with ${TEAM_ID}/${TEAM_NAME} substituted, a team-scoped view moved to the workspace level, conflicts
# surviving apply until fixed in the fixture, rename, the disabled-account hint, and the unknown-team abort. HOME is an
# empty dir so the script's cargo-bin PATH prepend cannot resurrect the real CLI.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/linear-setup.sh"
WORK="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] && echo "kept: $WORK" || rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck()     { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi; }
ck_has() { if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — missing [$2] in $3"; fi; }
ck_re()  { if grep -qE -- "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — no line matching /$2/ in $3"; fi; }
ck_not() { if grep -qF -- "$2" "$3"; then FAIL=$((FAIL+1)); echo "FAIL: $1 — unexpected [$2] in $3"; else PASS=$((PASS+1)); fi; }

export LINEAR_SHIM_FIX="$WORK/fix" LINEAR_SHIM_LOG="$WORK/mutations.log"
mkdir -p "$LINEAR_SHIM_FIX/src" "$LINEAR_SHIM_FIX/tgt" "$LINEAR_SHIM_FIX/disabled" "$WORK/bin" "$WORK/home"
: > "$LINEAR_SHIM_LOG"

SRC_TID="11111111-1111-1111-1111-111111111111"
TGT_TID="33333333-3333-3333-3333-333333333333"

# ---- source fixture (the model team) ----
cat > "$LINEAR_SHIM_FIX/src/team.json" <<JSON
{"data":{"organization":{"name":"Basefund","urlKey":"basefund"},"viewer":{"name":"k","email":"k@basefund.com"},"teams":{"nodes":[{"id":"$SRC_TID","key":"BF","name":"Product","triageEnabled":true,
 "defaultIssueState":{"id":"s-backlog","name":"Backlog"},"states":{"nodes":[
 {"id":"s-triage","name":"Triage","type":"triage","color":"#FC7840","position":0,"description":"Issue needs to be triaged"},
 {"id":"s-backlog","name":"Backlog","type":"backlog","color":"#bec2c8","position":0,"description":null},
 {"id":"s-planned","name":"Planned","type":"unstarted","color":"#e2e2e2","position":1,"description":null},
 {"id":"s-rfr","name":"Ready for Release","type":"completed","color":"#4cb782","position":2.5,"description":"Merged"},
 {"id":"s-done","name":"Done","type":"completed","color":"#5e6ad2","position":3,"description":null}]}}]}}}
JSON
cat > "$LINEAR_SHIM_FIX/src/labels.json" <<'JSON'
{"data":{"issueLabels":{"nodes":[
 {"id":"l-ux","name":"ux","color":"#00B8D9","description":"UX polish","isGroup":false,"team":null,"parent":null},
 {"id":"l-spec","name":"specified","color":"#10B981","description":null,"isGroup":false,"team":null,"parent":null},
 {"id":"l-teamonly","name":"zz-team-only","color":"#000000","description":null,"isGroup":false,"team":{"key":"BF"},"parent":null}]}}}
JSON
# Views: a team-scoped label view with board prefs (and a null pref that must drop out), the workspace-level base view
# "Product" whose filter names the team, a workspace-level view that does NOT name the team (never exported), an
# assignee view (skipped: foreign id), an unshared view, a duplicate-named pair, and a Project view.
cat > "$LINEAR_SHIM_FIX/src/views.json" <<JSON
{"data":{"customViews":{"nodes":[
 {"id":"v-simple","name":"Product: Simple","description":"Issues from the Product team tagged simple","icon":"Label","color":"#bec2c8","shared":true,"modelName":"Issue","createdAt":"2026-01-02T00:00:00Z","team":{"id":"$SRC_TID"},"owner":{"name":"k"},
  "filterData":{"and":[{"team":{"id":{"in":["$SRC_TID"]}}},{"labels":{"name":{"eq":"simple"}}}]},
  "organizationViewPreferences":{"id":"vp-simple","preferences":{"layout":"board","showTriageIssues":true,"issueGrouping":null}}},
 {"id":"v-product","name":"Product","description":null,"icon":null,"color":null,"shared":true,"modelName":"Issue","createdAt":"2026-01-01T00:00:00Z","team":null,"owner":{"name":"r"},
  "filterData":{"and":[{"team":{"id":{"in":["$SRC_TID"]}}}]},
  "organizationViewPreferences":{"id":"vp-product","preferences":{"layout":"board","showTriageIssues":true}}},
 {"id":"v-allproj","name":"All Issues By Project","description":null,"icon":null,"color":null,"shared":true,"modelName":"Issue","createdAt":"2026-01-01T00:00:00Z","team":null,"owner":{"name":"d"},
  "filterData":{},"organizationViewPreferences":{"id":"vp-ap","preferences":{}}},
 {"id":"v-blake","name":"Assigned to X","description":null,"icon":"FaceId","color":null,"shared":true,"modelName":"Issue","createdAt":"2026-01-02T00:00:00Z","team":{"id":"$SRC_TID"},"owner":{"name":"b"},
  "filterData":{"and":[{"assignee":{"id":{"in":["22222222-2222-2222-2222-222222222222"]}}}]},"organizationViewPreferences":null},
 {"id":"v-mine","name":"Mine","description":null,"icon":null,"color":null,"shared":false,"modelName":"Issue","createdAt":"2026-01-02T00:00:00Z","team":{"id":"$SRC_TID"},"owner":{"name":"k"},
  "filterData":{"and":[{"team":{"id":{"in":["$SRC_TID"]}}}]},"organizationViewPreferences":null},
 {"id":"v-nd2","name":"Product: Needs Decision","description":null,"icon":null,"color":"#bec2c8","shared":true,"modelName":"Issue","createdAt":"2026-01-03T00:00:00Z","team":{"id":"$SRC_TID"},"owner":{"name":"k"},
  "filterData":{"and":[{"team":{"id":{"in":["$SRC_TID"]}}},{"labels":{"name":{"eq":"needs decision"}}}]},"organizationViewPreferences":null},
 {"id":"v-nd1","name":"Product: Needs Decision","description":"Issues in the Product team that need a decision","icon":null,"color":"#bec2c8","shared":true,"modelName":"Issue","createdAt":"2026-01-01T00:00:00Z","team":{"id":"$SRC_TID"},"owner":{"name":"k"},
  "filterData":{"and":[{"team":{"id":{"in":["$SRC_TID"]}}},{"labels":{"name":{"eq":"needs decision"}}}]},"organizationViewPreferences":null},
 {"id":"v-proj","name":"All projects","description":null,"icon":null,"color":null,"shared":true,"modelName":"Project","createdAt":"2026-01-01T00:00:00Z","team":{"id":"$SRC_TID"},"owner":{"name":"d"},"filterData":{},"organizationViewPreferences":null}
]}}}
JSON
cat > "$LINEAR_SHIM_FIX/src/favorites.json" <<'JSON'
{"data":{"favorites":{"nodes":[
 {"id":"f1","customView":{"id":"v-product"}},
 {"id":"f2","customView":{"id":"v-simple"}},
 {"id":"f3","customView":{"id":"v-allproj"}},
 {"id":"f4","customView":null}]}}}
JSON

# ---- target fixture (a fresh team: Linear defaults, triage off, one label with the wrong color, one team-scoped clash,
# one label view already present but TEAM-scoped and without display preferences, no favorites) ----
cat > "$LINEAR_SHIM_FIX/tgt/team.json" <<JSON
{"data":{"organization":{"name":"Acme","urlKey":"acme"},"viewer":{"name":"k","email":"k@acme.com"},"teams":{"nodes":[{"id":"$TGT_TID","key":"TT","name":"Ops","triageEnabled":false,
 "defaultIssueState":{"id":"t-todo","name":"Todo"},"states":{"nodes":[
 {"id":"t-backlog","name":"Backlog","type":"backlog","color":"#bec2c8","position":0,"description":null},
 {"id":"t-todo","name":"Todo","type":"unstarted","color":"#e2e2e2","position":1,"description":null},
 {"id":"t-inprog","name":"In Progress","type":"started","color":"#f2c94c","position":2,"description":null},
 {"id":"t-done","name":"Done","type":"completed","color":"#5e6ad2","position":3,"description":null}]}}]}}}
JSON
cat > "$LINEAR_SHIM_FIX/tgt/labels.json" <<'JSON'
{"data":{"issueLabels":{"nodes":[
 {"id":"t-bug","name":"bug","color":"#000000","description":null,"isGroup":false,"team":null,"parent":null},
 {"id":"t-spec","name":"specified","color":"#10B981","description":null,"isGroup":false,"team":{"key":"TT"},"parent":null}]}}}
JSON
cat > "$LINEAR_SHIM_FIX/tgt/views.json" <<JSON
{"data":{"customViews":{"nodes":[
 {"id":"t-v-simple","name":"Ops: Simple","description":"Issues from the Ops team tagged simple","icon":"Label","color":"#bec2c8","shared":true,"modelName":"Issue","createdAt":"2026-01-05T00:00:00Z","team":{"id":"$TGT_TID"},"owner":{"name":"k"},
  "filterData":{"and":[{"team":{"id":{"in":["$TGT_TID"]}}},{"labels":{"name":{"eq":"simple"}}}]},"organizationViewPreferences":null}
]}}}
JSON
echo '{"data":{"favorites":{"nodes":[]}}}' > "$LINEAR_SHIM_FIX/tgt/favorites.json"
cp -R "$LINEAR_SHIM_FIX/tgt" "$LINEAR_SHIM_FIX/tgt2"

# ---- hand-written test model (independent of the live assets/model.json) ----
MODEL="$WORK/model.json"
cat > "$MODEL" <<'JSON'
{"source":{"organization":"basefund","team":"BF","teamName":"Product","exportedAt":"2026-01-01T00:00:00Z"},
 "team":{"triageEnabled":true,"defaultIssueState":"Backlog"},
 "states":[
  {"name":"Triage","type":"triage","color":"#FC7840","position":0,"description":"Issue needs to be triaged","required":true},
  {"name":"Backlog","type":"backlog","color":"#bec2c8","position":0,"description":null,"required":true},
  {"name":"Planned","type":"unstarted","color":"#e2e2e2","position":1,"description":null,"required":true},
  {"name":"In Progress","type":"started","color":"#f2c94c","position":2,"description":null,"required":true},
  {"name":"Ready for Release","type":"completed","color":"#4cb782","position":2.5,"description":"Merged","required":true},
  {"name":"Done","type":"completed","color":"#5e6ad2","position":3,"description":null,"required":true}],
 "labels":[
  {"name":"bug","color":"#EB5757","description":null,"isGroup":false,"parent":null,"required":true},
  {"name":"specified","color":"#10B981","description":null,"isGroup":false,"parent":null,"required":true},
  {"name":"ux","color":"#00B8D9","description":"UX polish","isGroup":false,"parent":null,"required":false}],
 "views":[
  {"name":"${TEAM_NAME}","description":null,"icon":null,"color":null,
   "filterData":{"and":[{"team":{"id":{"in":["${TEAM_ID}"]}}}]},"preferences":{"layout":"board"},"favorite":true},
  {"name":"${TEAM_NAME}: Simple","description":"Issues from the ${TEAM_NAME} team tagged simple","icon":"Label","color":"#bec2c8",
   "filterData":{"and":[{"team":{"id":{"in":["${TEAM_ID}"]}}},{"labels":{"name":{"eq":"simple"}}}]},"preferences":{"layout":"board","showTriageIssues":true},"favorite":true}],
 "skipped":{"views":[]}}
JSON

# ---- the stateful linear-cli shim ----
cat > "$WORK/bin/linear-cli" <<'SHIM'
#!/bin/bash
set -uo pipefail
profile="" mode="" doc="" input="null" id="" key=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  a="${args[$i]}"
  case "$a" in
    --profile) i=$((i+1)); profile="${args[$i]}" ;;
    api) i=$((i+1)); mode="${args[$i]}"; i=$((i+1)); doc="${args[$i]}" ;;
    -v) i=$((i+1)); kv="${args[$i]}"; k="${kv%%=*}"; v="${kv#*=}"
        case "$k" in input) input="$v" ;; id) id="$(printf '%s' "$v" | tr -d '"')" ;; key) key="$(printf '%s' "$v" | tr -d '"')" ;; esac ;;
    cache) exit 0 ;;
  esac
  i=$((i+1))
done
[ -n "$profile" ] || { echo "shim: no --profile" >&2; exit 9; }
if [ "$profile" = disabled ]; then
  echo '{"code":3,"details":{"errors":[{"message":"Account disabled"}]},"error":true,"message":"HTTP 400 Bad Request"}'; exit 3
fi
D="$LINEAR_SHIM_FIX/$profile"
[ -d "$D" ] || { echo "shim: unknown profile $profile" >&2; exit 9; }
if [ "$mode" = query ]; then
  case "$doc" in
    *'teams(filter'*) jq --arg k "$key" '.data.teams.nodes |= map(select(.key == $k))' "$D/team.json" ;;
    *issueLabels*)    cat "$D/labels.json" ;;
    *customViews*)    cat "$D/views.json" ;;
    *favorites*)      cat "$D/favorites.json" ;;
    *) echo "shim: unknown query: $doc" >&2; exit 9 ;;
  esac
  exit 0
fi
field=$(grep -oE 'workflowStateCreate|workflowStateUpdate|issueLabelCreate|issueLabelUpdate|customViewCreate|customViewUpdate|viewPreferencesCreate|viewPreferencesUpdate|favoriteCreate|teamUpdate' <<<"$doc" | head -1)
printf '%s\t%s\t%s\n' "$field" "$id" "$input" >> "$LINEAR_SHIM_LOG"
edit() { local f="$1"; shift; jq "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
case "$field" in
  teamUpdate) edit "$D/team.json" --argjson i "$input" '
      .data.teams.nodes[0] |= (
        (if $i.triageEnabled == true then .triageEnabled = true
           | (if any(.states.nodes[]; .type == "triage") then . else
                .states.nodes += [{id: "t-triage-minted", name: "Triage", type: "triage", color: "#ff0000", position: 0, description: null}] end)
         else . end)
        | (if $i.defaultIssueStateId then .defaultIssueState = ([.states.nodes[] | select(.id == $i.defaultIssueStateId) | {id, name}] | first) else . end))' ;;
  workflowStateCreate) edit "$D/team.json" --argjson i "$input" '.data.teams.nodes[0].states.nodes += [($i | del(.teamId)) + {id: ("t-" + ($i.name | ascii_downcase | gsub(" "; "-")))}]' ;;
  workflowStateUpdate) edit "$D/team.json" --argjson i "$input" --arg id "$id" '.data.teams.nodes[0].states.nodes |= map(if .id == $id then . + $i else . end)' ;;
  issueLabelCreate)    edit "$D/labels.json" --argjson i "$input" '.data.issueLabels.nodes += [($i | del(.parentId)) + {id: ("t-" + $i.name), team: null, parent: null}]' ;;
  issueLabelUpdate)    edit "$D/labels.json" --argjson i "$input" --arg id "$id" '.data.issueLabels.nodes |= map(if .id == $id then . + ($i | del(.parentId)) else . end)' ;;
  customViewCreate)    edit "$D/views.json" --argjson i "$input" '.data.customViews.nodes += [($i | del(.teamId)) + {id: ("t-" + $i.name), modelName: "Issue", team: (if $i.teamId then {id: $i.teamId} else null end), createdAt: "2026-02-01T00:00:00Z", owner: {name: "shim"}, organizationViewPreferences: null}]' ;;
  customViewUpdate)    edit "$D/views.json" --argjson i "$input" --arg id "$id" '.data.customViews.nodes |= map(if .id == $id then (. + ($i | del(.teamId)) | if ($i | has("teamId")) then .team = (if $i.teamId then {id: $i.teamId} else null end) else . end) else . end)' ;;
  viewPreferencesCreate) edit "$D/views.json" --argjson i "$input" '.data.customViews.nodes |= map(if .id == $i.customViewId then .organizationViewPreferences = {id: ("vp-" + .id), preferences: $i.preferences} else . end)' ;;
  viewPreferencesUpdate) edit "$D/views.json" --argjson i "$input" --arg id "$id" '.data.customViews.nodes |= map(if .organizationViewPreferences.id == $id then .organizationViewPreferences.preferences = $i.preferences else . end)' ;;
  favoriteCreate)      edit "$D/favorites.json" --argjson i "$input" '.data.favorites.nodes += [{id: ("f-" + $i.customViewId), customView: {id: $i.customViewId}}]' ;;
  *) echo "shim: unknown mutation: $doc" >&2; exit 9 ;;
esac
if [ "$field" = customViewCreate ]; then
  printf '{"data":{"customViewCreate":{"success":true,"customView":{"id":"t-%s"}}}}\n' "$(jq -r .name <<<"$input")"
else
  printf '{"data":{"%s":{"success":true}}}\n' "$field"
fi
SHIM
chmod +x "$WORK/bin/linear-cli"

run() { # run <outfile> <args...> — runs the script under the shim; echoes exit code
  local out="$1"; shift
  PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK/home" LINEAR_TEAM= LINEAR_CLI_PROFILE= "$SCRIPT" "$@" > "$out" 2>&1
  echo $?
}

# T1 usage
rc=$(run "$WORK/t1.out"); ck "T1 no args exits 2" 2 "$rc"
rc=$(run "$WORK/t1b.out" bogus --team TT); ck "T1 unknown subcommand exits 2" 2 "$rc"

# T2 export: placeholders, skip rules, dedup, required flags, ordering, preferences, favorites
EXP="$WORK/exported.json"
rc=$(run "$WORK/t2.out" export --team BF --profile src --out "$EXP"); ck "T2 export exits 0" 0 "$rc"
ck_has "T2 header names the favorites user" "favorites for k@basefund.com" "$WORK/t2.out"
ck "T2 view names (base view included, portable, deduped, sorted)" '["${TEAM_NAME}","${TEAM_NAME}: Needs Decision","${TEAM_NAME}: Simple"]' "$(jq -c '[.views[].name]' "$EXP")"
ck "T2 non-team workspace view excluded" null "$(jq '[.views[].name] | index("All Issues By Project")' "$EXP")"
ck "T2 dedup keeps the oldest (the one with a description)" "Issues in the \${TEAM_NAME} team that need a decision" "$(jq -r '.views[] | select(.name=="${TEAM_NAME}: Needs Decision") | .description' "$EXP")"
ck "T2 filterData carries the team-id placeholder" true "$(jq '.views[] | select(.name=="${TEAM_NAME}: Simple") | .filterData | tojson | contains("${TEAM_ID}")' "$EXP")"
ck "T2 base view filter carries the team-id placeholder" true "$(jq '.views[] | select(.name=="${TEAM_NAME}") | .filterData | tojson | contains("${TEAM_ID}")' "$EXP")"
ck "T2 no raw uuid survives in views" false "$(jq '[.views[].filterData | tojson] | join(" ") | test("[0-9a-f]{8}-[0-9a-f]{4}")' "$EXP")"
ck "T2 preferences exported with null keys dropped" '{"layout":"board","showTriageIssues":true}' "$(jq -c '.views[] | select(.name=="${TEAM_NAME}: Simple") | .preferences' "$EXP")"
ck "T2 view without org prefs exports empty preferences" '{}' "$(jq -c '.views[] | select(.name=="${TEAM_NAME}: Needs Decision") | .preferences' "$EXP")"
ck "T2 favorite flags follow the exporting user" '[true,false,true]' "$(jq -c '[.views[].favorite]' "$EXP")"
ck "T2 skipped: assignee view + duplicate" '["${TEAM_NAME}: Needs Decision","Assigned to X"]' "$(jq -c '[.skipped.views[].name] | sort' "$EXP")"
ck "T2 team-scoped label excluded" '["specified","ux"]' "$(jq -c '[.labels[].name]' "$EXP")"
ck "T2 required flag on specified" true "$(jq '.labels[] | select(.name=="specified") | .required' "$EXP")"
ck "T2 required flag off for ux" false "$(jq '.labels[] | select(.name=="ux") | .required' "$EXP")"
ck "T2 states sorted by position then name" '["Backlog","Triage","Planned","Ready for Release","Done"]' "$(jq -c '[.states[].name]' "$EXP")"
ck "T2 team settings captured" '{"triageEnabled":true,"defaultIssueState":"Backlog"}' "$(jq -c '.team' "$EXP")"
ck "T2 source recorded" "basefund/BF" "$(jq -r '"\(.source.organization)/\(.source.team)"' "$EXP")"

# T3 check on the stale target: the plan and exit 1
rc=$(run "$WORK/t3.out" check --team TT --profile tgt --model "$MODEL"); ck "T3 check exits 1 with gaps" 1 "$rc"
ck_has "T3 header names the answering workspace" "workspace Acme (acme) · team TT \"Ops\"" "$WORK/t3.out"
ck_re  "T3 triage toggle planned" 'TEAM +update +triageEnabled' "$WORK/t3.out"
ck_re  "T3 Planned create (required)" 'STATE +create +\* Planned' "$WORK/t3.out"
ck_re  "T3 Ready for Release create" 'STATE +create +\* Ready for Release' "$WORK/t3.out"
ck_re  "T3 Todo reported extra, not deleted" 'STATE +extra +Todo' "$WORK/t3.out"
ck_re  "T3 default state Todo → Backlog" 'TEAM +update +defaultIssueState +— Todo → Backlog' "$WORK/t3.out"
ck_re  "T3 bug color drift" 'LABEL +update +\* bug +— color' "$WORK/t3.out"
ck_re  "T3 team-scoped specified is a conflict" 'LABEL +conflict +\* specified' "$WORK/t3.out"
ck_re  "T3 ux create (not required)" 'LABEL +create +  ux' "$WORK/t3.out"
ck_re  "T3 base view create with team name substituted" 'VIEW +create +  Ops$' "$WORK/t3.out"
ck_re  "T3 existing team-scoped view drifts on scope and preferences only" 'VIEW +update +  Ops: Simple +— scope,preferences$' "$WORK/t3.out"
ck_re  "T3 favorite planned for the base view" 'FAVORITE +create +  Ops$' "$WORK/t3.out"
ck_re  "T3 favorite planned for the label view" 'FAVORITE +create +  Ops: Simple$' "$WORK/t3.out"
ck_has "T3 summary counts" "create 7 · update 4 · conflict 1 · extra 1" "$WORK/t3.out"

# T4 dry-run: nothing mutated
rc=$(run "$WORK/t4.out" apply --team TT --profile tgt --model "$MODEL" --dry-run); ck "T4 dry-run exits 0" 0 "$rc"
ck_has "T4 dry-run says so" "dry-run: 11 mutation(s) would run; nothing changed" "$WORK/t4.out"
ck "T4 no mutations logged" 0 "$(wc -l < "$LINEAR_SHIM_LOG" | tr -d ' ')"

# T5 apply: phases, substitution, scope move, preferences, favorites; convergence blocked only by the conflict
rc=$(run "$WORK/t5.out" apply --team TT --profile tgt --model "$MODEL"); ck "T5 apply exits 1 while a conflict remains" 1 "$rc"
ck_has "T5 triage toggled first" "team    updated  triageEnabled" "$WORK/t5.out"
ck_has "T5 minted Triage then brought to model color" "state   updated  Triage" "$WORK/t5.out"
ck_has "T5 Planned created" "state   created  Planned" "$WORK/t5.out"
ck_has "T5 Ready for Release created" "state   created  Ready for Release" "$WORK/t5.out"
ck_has "T5 default state set after states exist" "team    updated  defaultIssueState" "$WORK/t5.out"
ck_has "T5 bug recolored" "label   updated  bug" "$WORK/t5.out"
ck_has "T5 ux created" "label   created  ux" "$WORK/t5.out"
ck_re  "T5 base view created" 'view +created +Ops$' "$WORK/t5.out"
ck_has "T5 team-scoped view moved" "view    updated  Ops: Simple" "$WORK/t5.out"
ck "T5 preferences written on both views" 2 "$(grep -c 'view    prefs' "$WORK/t5.out")"
ck "T5 both views favorited" 2 "$(grep -c 'fav     created' "$WORK/t5.out")"
ck "T5 exactly two states created by mutation (Triage came from the triage toggle)" 2 "$(grep -c '^workflowStateCreate' "$LINEAR_SHIM_LOG")"
ck "T5 view create carries the TARGET team id in its filter" 1 "$(grep '^customViewCreate' "$LINEAR_SHIM_LOG" | grep -c "$TGT_TID")"
ck "T5 view create is workspace-level (no teamId)" 0 "$(grep '^customViewCreate' "$LINEAR_SHIM_LOG" | grep -c teamId)"
ck "T5 view create name substituted" 1 "$(grep '^customViewCreate' "$LINEAR_SHIM_LOG" | grep -c '"name":"Ops"')"
ck "T5 view update clears the team (scope → workspace)" 1 "$(grep '^customViewUpdate' "$LINEAR_SHIM_LOG" | grep 't-v-simple' | grep -c '"teamId":null')"
ck "T5 preferences created, board layout" 2 "$(grep '^viewPreferencesCreate' "$LINEAR_SHIM_LOG" | grep -c '"layout":"board"')"
ck "T5 preferences create targets the organization scope" 2 "$(grep '^viewPreferencesCreate' "$LINEAR_SHIM_LOG" | grep -c '"type":"organization"')"
ck "T5 favorites created by view id" 2 "$(grep -c '^favoriteCreate' "$LINEAR_SHIM_LOG")"
ck "T5 no placeholder leaked into any mutation" 0 "$(grep -c 'TEAM_ID\|TEAM_NAME' "$LINEAR_SHIM_LOG")"
ck "T5 default state resolved to the Backlog id" 1 "$(grep '^teamUpdate' "$LINEAR_SHIM_LOG" | grep -c '"defaultIssueStateId":"t-backlog"')"
ck_has "T5 result shows the surviving conflict" "not converged" "$WORK/t5.out"
n_before=$(wc -l < "$LINEAR_SHIM_LOG" | tr -d ' ')

# T6 fix the conflict in Linear (fixture) → check converges; apply is a no-op
jq '.data.issueLabels.nodes |= map(if .name == "specified" then .team = null else . end)' "$LINEAR_SHIM_FIX/tgt/labels.json" > "$WORK/l.tmp" && mv "$WORK/l.tmp" "$LINEAR_SHIM_FIX/tgt/labels.json"
rc=$(run "$WORK/t6.out" check --team TT --profile tgt --model "$MODEL"); ck "T6 check converges after the conflict is fixed" 0 "$rc"
ck_has "T6 says converged" "converged: nothing to create or update" "$WORK/t6.out"
ck_re  "T6 Todo still reported extra (never deleted)" 'STATE +extra +Todo' "$WORK/t6.out"
ck_re  "T6 favorites read back as ok" 'FAVORITE +ok +  Ops: Simple$' "$WORK/t6.out"
rc=$(run "$WORK/t6b.out" apply --team TT --profile tgt --model "$MODEL"); ck "T6 apply on a converged team exits 0" 0 "$rc"
ck_has "T6 apply is a no-op" "converged: nothing to do" "$WORK/t6b.out"
ck "T6 no further mutations" "$n_before" "$(wc -l < "$LINEAR_SHIM_LOG" | tr -d ' ')"

# T6c a preferences-only drift re-sends the FULL object (an update replaces, never merges) and touches nothing else
jq '.data.customViews.nodes |= map(if .name == "Ops: Simple" then .organizationViewPreferences.preferences = {layout: "list", showTriageIssues: true} else . end)' "$LINEAR_SHIM_FIX/tgt/views.json" > "$WORK/v.tmp" && mv "$WORK/v.tmp" "$LINEAR_SHIM_FIX/tgt/views.json"
rc=$(run "$WORK/t6c.out" apply --team TT --profile tgt --model "$MODEL"); ck "T6c apply exits 0" 0 "$rc"
ck_has "T6c preferences rewritten" "view    prefs    Ops: Simple" "$WORK/t6c.out"
ck_not "T6c the view itself is not updated" "view    updated  Ops: Simple" "$WORK/t6c.out"
ck "T6c update carries the whole model object" 1 "$(grep '^viewPreferencesUpdate' "$LINEAR_SHIM_LOG" | grep -c '{"preferences":{"layout":"board","showTriageIssues":true}}')"
ck_has "T6c converged afterwards" "converged" "$WORK/t6c.out"

# T6d a duplicate-named team-scoped view appears, and the user's favorite sits on IT rather than the paired view: the
# duplicate is flagged extra, the favorite still counts, nothing is planned
jq --arg tid "$TGT_TID" '.data.customViews.nodes += [{id: "t-v-simple-dup", name: "Ops: Simple", description: "Issues from the Ops team tagged simple", icon: "Label", color: "#bec2c8", shared: true, modelName: "Issue", createdAt: "2026-03-01T00:00:00Z", team: {id: $tid}, owner: {name: "b"}, filterData: {and: [{team: {id: {in: [$tid]}}}, {labels: {name: {eq: "simple"}}}]}, organizationViewPreferences: null}]' "$LINEAR_SHIM_FIX/tgt/views.json" > "$WORK/v.tmp" && mv "$WORK/v.tmp" "$LINEAR_SHIM_FIX/tgt/views.json"
jq '.data.favorites.nodes |= map(if .customView.id == "t-v-simple" then .customView.id = "t-v-simple-dup" else . end)' "$LINEAR_SHIM_FIX/tgt/favorites.json" > "$WORK/f.tmp" && mv "$WORK/f.tmp" "$LINEAR_SHIM_FIX/tgt/favorites.json"
rc=$(run "$WORK/t6d.out" check --team TT --profile tgt --model "$MODEL"); ck "T6d check still converges" 0 "$rc"
ck_re  "T6d duplicate flagged as extra with its owner" 'VIEW +extra +  Ops: Simple +— duplicate of the model view above \(owner b\)' "$WORK/t6d.out"
ck_re  "T6d favorite on the duplicate still counts" 'FAVORITE +ok +  Ops: Simple$' "$WORK/t6d.out"
ck_not "T6d no favorite planned" "FAVORITE create" "$WORK/t6d.out"

# T7 rename (on the untouched tgt2 copy)
rc=$(run "$WORK/t7.out" rename --team TT --profile tgt2 Todo Planned); ck "T7 rename exits 0" 0 "$rc"
ck_has "T7 rename reported" "state   renamed  Todo → Planned" "$WORK/t7.out"
ck "T7 rename mutation carries the new name" 1 "$(grep '^workflowStateUpdate' "$LINEAR_SHIM_LOG" | grep -c 't-todo	{"name":"Planned"}')"
rc=$(run "$WORK/t7b.out" rename --team TT --profile tgt2 Todo Backlog); ck "T7 rename of a missing state exits 2" 2 "$rc"
ck_has "T7 names the missing state" "no state named 'Todo'" "$WORK/t7b.out"
rc=$(run "$WORK/t7c.out" rename --team TT --profile tgt2 Backlog Planned); ck "T7 rename onto an existing name exits 2" 2 "$rc"
ck_has "T7 names the clash" "a state named 'Planned' already exists" "$WORK/t7c.out"
rc=$(run "$WORK/t7d.out" rename --team TT --profile tgt2 Planned); ck "T7 rename with one arg exits 2" 2 "$rc"

# T8 disabled account → exit 2 with the re-key hint
rc=$(run "$WORK/t8.out" check --team TT --profile disabled --model "$MODEL"); ck "T8 disabled account exits 2" 2 "$rc"
ck_has "T8 hint names the fix" "HINT: the API key for this profile belongs to a disabled account" "$WORK/t8.out"

# T9 unknown team
rc=$(run "$WORK/t9.out" check --team ZZ --profile tgt --model "$MODEL"); ck "T9 unknown team exits 2" 2 "$rc"
ck_has "T9 names workspace" "team 'ZZ' not found in workspace 'acme'" "$WORK/t9.out"

# T10 missing model
rc=$(run "$WORK/t10.out" check --team TT --profile tgt --model "$WORK/nope.json"); ck "T10 missing model exits 2" 2 "$rc"

echo "linear-setup.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

# Diff a live team snapshot (stdin) against the portable model ($model[0]) and emit the action list
# linear-setup.sh executes. Pure: no side effects, deterministic order (team → states → labels → views).
#
# Inputs:  --slurpfile model <model.json>   --arg team_id <uuid>   --arg team_name <name>
# Output:  array of {kind, op, name, ...}
#   op: ok | create | update | conflict | extra
#   create/update carry `input` (the GraphQL input object, placeholders already substituted);
#   update also carries `id`; conflict/extra carry `detail` and are never executed.

def lc: ascii_downcase;
def norm: (. // "");
def normcolor: (. // "" | lc);
def sub_ph: gsub("\\$\\{TEAM_ID\\}"; $team_id) | gsub("\\$\\{TEAM_NAME\\}"; $team_name);
def sub_json: tojson | sub_ph | fromjson;
def sorted: walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end);
def same_json(a; b): (a | sorted | tojson) == (b | sorted | tojson);

$model[0] as $m | . as $t |

# ---- team: triage must be on before a `triage`-type state can exist ----
( if ($m.team.triageEnabled == true) and ($t.team.triageEnabled != true)
  then [{kind: "team", op: "update", name: "triageEnabled", detail: "false → true", input: {triageEnabled: true}}]
  else [] end ) as $team_triage |

# ---- states: match by case-insensitive name ----
( [ $m.states[] | . as $s
    | ([$t.team.states[] | select((.name | lc) == ($s.name | lc))] | first) as $cur
    | if $cur == null then
        {kind: "state", op: "create", name: $s.name, required: ($s.required // false),
         input: {name: $s.name, type: $s.type, color: $s.color, position: $s.position, description: ($s.description // null)}}
      elif $cur.type != $s.type then
        {kind: "state", op: "conflict", name: $s.name,
         detail: "type is \($cur.type), model wants \($s.type) — type is immutable; archive the state in Linear and re-run"}
      else
        ( [ (if ($cur.color | normcolor) != ($s.color | normcolor) then "color" else empty end),
            (if ($cur.description | norm) != ($s.description | norm) then "description" else empty end),
            (if $cur.position != $s.position then "position" else empty end) ] ) as $drift
        | if ($drift | length) > 0 then
            {kind: "state", op: "update", id: $cur.id, name: $s.name, required: ($s.required // false), detail: ($drift | join(",")),
             input: {color: $s.color, description: ($s.description // ""), position: $s.position}}
          else {kind: "state", op: "ok", name: $s.name, required: ($s.required // false)} end
      end ] ) as $states |
( [ $t.team.states[] | . as $cur
    | select(any($m.states[]; (.name | lc) == ($cur.name | lc)) | not)
    | {kind: "state", op: "extra", name: $cur.name, detail: "type \($cur.type) — not in the model (left as is; `rename` it if it is a misnamed model state)"} ] ) as $extra_states |

# ---- team default state: by name, resolved to an id at execution time (states may have just been created) ----
( if ($m.team.defaultIssueState != null) and ((($t.team.defaultIssueState.name // "") | lc) != ($m.team.defaultIssueState | lc))
  then [{kind: "team", op: "update", name: "defaultIssueState", detail: "\($t.team.defaultIssueState.name // "none") → \($m.team.defaultIssueState)",
         input: {defaultIssueStateName: $m.team.defaultIssueState}}]
  else [] end ) as $team_default |

# ---- labels: the model carries WORKSPACE labels; a same-named team-scoped label in the target is a conflict ----
( [ $m.labels[] | . as $l
    | ([$t.labels[] | select(.team == null and ((.name | lc) == ($l.name | lc)))] | first) as $cur
    | ([$t.labels[] | select(.team != null and ((.name | lc) == ($l.name | lc)))] | first) as $scoped
    | if $cur == null and $scoped != null then
        {kind: "label", op: "conflict", name: $l.name, required: ($l.required // false),
         detail: "exists as a TEAM-scoped label on \($scoped.team.key); the model wants a workspace label — convert it in Linear (label settings → move to workspace)"}
      elif $cur == null then
        {kind: "label", op: "create", name: $l.name, required: ($l.required // false), parent: ($l.parent // null),
         input: {name: $l.name, color: $l.color, description: ($l.description // null), isGroup: ($l.isGroup // false)}}
      elif ($cur.isGroup // false) != ($l.isGroup // false) then
        {kind: "label", op: "conflict", name: $l.name, required: ($l.required // false), detail: "isGroup differs (\($cur.isGroup // false) vs model \($l.isGroup // false)) — fix in Linear"}
      else
        ( [ (if ($cur.color | normcolor) != ($l.color | normcolor) then "color" else empty end),
            (if ($cur.description | norm) != ($l.description | norm) then "description" else empty end),
            (if (($cur.parent.name // "") | lc) != (($l.parent // "") | lc) then "parent" else empty end) ] ) as $drift
        | if ($drift | length) > 0 then
            {kind: "label", op: "update", id: $cur.id, name: $l.name, required: ($l.required // false), detail: ($drift | join(",")), parent: ($l.parent // null),
             input: {color: $l.color, description: ($l.description // "")}}
          else {kind: "label", op: "ok", name: $l.name, required: ($l.required // false)} end
      end ] ) as $labels |

# ---- views: model names/descriptions/filters carry ${TEAM_NAME}/${TEAM_ID}; substitute, then match by exact name.
# Several target views can share a name (Linear allows it); pair the model view with the least-drifted one and flag the rest.
def view_drift($cur; $v):
  [ (if ($cur.description | norm) != ($v.description | norm) then "description" else empty end),
    (if ($cur.icon | norm) != ($v.icon | norm) then "icon" else empty end),
    (if ($cur.color | normcolor) != ($v.color | normcolor) then "color" else empty end),
    (if ($cur.shared // false) != true then "shared" else empty end),
    (if same_json($cur.filterData // {}; $v.filterData // {}) | not then "filterData" else empty end) ];
( [ $m.views[] | sub_json | . as $v
    | ([$t.views[] | select(.name == $v.name)] | sort_by(view_drift(.; $v) | length)) as $cands
    | ($cands | first) as $cur
    | if $cur == null then
        {kind: "view", op: "create", name: $v.name,
         input: {name: $v.name, description: ($v.description // null), icon: ($v.icon // null), color: ($v.color // null),
                 teamId: $team_id, filterData: $v.filterData, shared: true}}
      else
        view_drift($cur; $v) as $drift
        | if ($drift | length) > 0 then
            {kind: "view", op: "update", id: $cur.id, name: $v.name, detail: ($drift | join(",")),
             input: {description: ($v.description // ""), icon: ($v.icon // null), color: ($v.color // null), filterData: $v.filterData, shared: true}}
          else {kind: "view", op: "ok", name: $v.name} end
      end,
      ( $cands[1:][] | {kind: "view", op: "extra", name: .name, detail: "duplicate of the model view above (owner \(.owner.name // "?")) — delete it in Linear"} )
  ] ) as $views |
( [ $t.views[] | . as $cur
    | select(any($m.views[] | sub_json; .name == $cur.name) | not)
    | {kind: "view", op: "extra", name: $cur.name, detail: "not in the model (left as is)"} ] ) as $extra_views |

$team_triage + $states + $extra_states + $team_default + $labels + $views + $extra_views

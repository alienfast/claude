#!/bin/bash
# linear-claim.sh — claim an issue for the viewer with a VERIFIED write, not a reported one.
#
# Why this exists: `issues update` reports success off the mutation call and names only the issue, so
# `+ Updated issue: <ID> <title>` at exit 0 is not evidence the assignee or state was written
# (skills/linear/SKILL.md gotcha #8 — measured on both fields, intermittently, which is what makes it
# dangerous). Every claim site used to gate on that exit status alone. This is the single tested
# implementation of the read-back, and it keeps the three outcomes apart because they route differently:
# a confirmed failure is retryable, an unconfirmable one is not a failure at all.
#
# Usage:
#   linear-claim.sh <ISSUE-ID> [--state <state-name>]
#
# The assignee is written with `issues assign <ID> me`, whose mutation selects `assignee { name }` and
# which echoes the server's resulting value — so a write that did not land shows in its own output. The
# optional state is delegated to linear-set-state.sh, already a verified transition (wrapped update →
# `--no-cache` read-back → raw-mutation fallback); this script never re-implements that.
#
# stdout contract — the FIRST line of stdout is the verdict; callers branch on it:
#   CLAIMED <ID> assignee=<name>[ state=<name>]   exit 0   both halves confirmed by read-back
#   NOT-CLAIMED <ID>: <reason>                    exit 2   confirmed NOT written — retryable, idempotent
#   UNCONFIRMED <ID>: <reason>                    exit 3   the READ failed (network/auth); the write may
#                                                          well have landed. NOT a failed claim; a caller
#                                                          must not report it as one.
#   FAILED-USAGE: <reason>                        exit 1
# Everything else — linear-cli's own output, stage markers — goes to stderr.
#
# Note on the comparison: `issues get` exposes an assignee as `{name}` alone — no id, no email — so the
# viewer's name AND email are both accepted against that one field. On a workspace where a display name
# is not the account email, comparing against the email alone never matches.
set -uo pipefail

# linear-cli installs to ~/.cargo/bin, which is not on a non-interactive PATH.
export PATH="$HOME/.cargo/bin:$PATH"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

verdict() { # verdict <line> <exit>
  echo "$1"
  echo "$1" >&2
  exit "$2"
}

[ $# -ge 1 ] || verdict "FAILED-USAGE: usage: linear-claim.sh <ISSUE-ID> [--state <state-name>]" 1

issue_arg=$1
shift
state_name=""
while [ $# -gt 0 ]; do
  case "$1" in
    --state)
      [ $# -ge 2 ] || verdict "FAILED-USAGE: --state requires a value" 1
      [ -z "$state_name" ] || verdict "FAILED-USAGE: --state given more than once" 1
      state_name=$2
      shift 2
      ;;
    *)
      verdict "FAILED-USAGE: unknown argument '$1'" 1
      ;;
  esac
done

# Normalize exactly like start-wt-setup.sh / start-wt-verify.sh.
issue_id=$(printf '%s' "$issue_arg" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
[[ "$issue_id" =~ ^[A-Z]+-[0-9]+$ ]] || verdict "FAILED-USAGE: issue ID '$issue_id' does not match ^[A-Z]+-[0-9]+\$" 1

# Resolve the viewer up front: without it there is nothing to compare a read-back against, and a claim we
# cannot verify is exactly the state this script exists to stop callers from inferring their way past.
viewer_json=$(linear-cli api query -q -o json 'query{viewer{name email}}' 2>/dev/null || true)
viewer_name=$(printf '%s' "$viewer_json" | jq -r '.data.viewer.name // .viewer.name // empty' 2>/dev/null || true)
viewer_email=$(printf '%s' "$viewer_json" | jq -r '.data.viewer.email // .viewer.email // empty' 2>/dev/null || true)
if [ -z "$viewer_name" ] && [ -z "$viewer_email" ]; then
  verdict "UNCONFIRMED $issue_id: could not resolve the viewer identity — claim not attempted" 3
fi

transient() { grep -qiE 'HTTP 5[0-9][0-9]|Service Unavailable|timed? ?out' "$1"; }

assign_err=$(mktemp)
trap 'rm -f "$assign_err"' EXIT

assign_once() {
  linear-cli issues assign "$issue_id" me >&2 2>"$assign_err"
}

# Reads .assignee.name and echoes it; returns 1 when the READ ITSELF failed, which is the
# UNCONFIRMED case and must stay distinguishable from a read that succeeded and showed nobody.
read_assignee() {
  local json
  json=$(linear-cli issues get "$issue_id" --no-cache -o json 2>/dev/null) || return 1
  [ -n "$json" ] || return 1
  printf '%s' "$json" | jq -r '.assignee.name // empty' 2>/dev/null || return 1
}

matches_me() { # matches_me <assignee-name>
  [ -n "$1" ] || return 1
  [ "$1" = "$viewer_name" ] || [ "$1" = "$viewer_email" ]
}

echo "== assign ==" >&2
if ! assign_once; then
  cat "$assign_err" >&2
  if transient "$assign_err"; then
    echo "== assign retry (transient 5xx/timeout) ==" >&2
    sleep 2
    assign_once || { cat "$assign_err" >&2; verdict "NOT-CLAIMED $issue_id: assign failed twice" 2; }
  else
    verdict "NOT-CLAIMED $issue_id: assign failed" 2
  fi
else
  cat "$assign_err" >&2
fi

echo "== assignee read-back ==" >&2
if ! got=$(read_assignee); then
  verdict "UNCONFIRMED $issue_id: assignee read-back failed — the write may have landed" 3
fi
if ! matches_me "$got"; then
  # Confirmed not written. The write is idempotent, so one re-issue is free; gotcha #8's failure is
  # intermittent and a second attempt is what it typically takes.
  echo "== assign retry (read-back showed '${got:-none}') ==" >&2
  assign_once || cat "$assign_err" >&2
  if ! got=$(read_assignee); then
    verdict "UNCONFIRMED $issue_id: assignee read-back failed after retry — the write may have landed" 3
  fi
  matches_me "$got" || verdict "NOT-CLAIMED $issue_id: assignee reads '${got:-none}', wanted '${viewer_name:-$viewer_email}'" 2
fi

if [ -n "$state_name" ]; then
  echo "== state ==" >&2
  # Delegated: linear-set-state.sh already verifies the transition. Its own `<ID> -> <state>` line goes to
  # stderr so it cannot land on this script's verdict line.
  set_out=$("$SCRIPT_DIR/linear-set-state.sh" "$state_name" "$issue_id" 2>&1)
  set_rc=$?
  printf '%s\n' "$set_out" >&2
  if [ "$set_rc" -ne 0 ]; then
    verdict "NOT-CLAIMED $issue_id: assignee landed but state did not — $(printf '%s' "$set_out" | tr '\n' ' ')" 2
  fi
  # Report the state it actually resolved and confirmed (it matches case-insensitively and echoes the
  # team's own spelling), never the argument handed in — those differ, and the verdict is what is logged.
  landed=$(printf '%s\n' "$set_out" | sed -n "s/^${issue_id} -> //p" | tail -1)
  verdict "CLAIMED $issue_id assignee=$got state=${landed:-$state_name}" 0
fi

verdict "CLAIMED $issue_id assignee=$got" 0

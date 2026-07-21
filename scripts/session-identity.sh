#!/bin/bash
# session-identity.sh — resolve THIS session's stable identity for run-scoped state keying.
#
# Exists because a tool shell's raw $PPID is not the session: in a `claude agents` fleet the shell's parent is a transient pool process
# (`claude bg-spare`) whose pid changes between commands, so state keyed on $PPID fragments across iterations and its GC misfires. The durable
# identity is the per-session id ($CLAUDE_JOB_DIR basename); the harness PID from the claude-ancestor walk (the fleet root in fleets, the session
# binary elsewhere) is the LIVENESS anchor and the naming fallback only.
#
# Stdout KEY=value contract:
#   SESSION_ID=<per-session id, or empty>
#   HARNESS_PID=<stable claude ancestor pid, or empty>
#   HARNESS_PID_START=<its start time, or empty>
#   RUN_KEY=<SESSION_ID when set, else HARNESS_PID>   (empty only when neither resolves)
#
# Exit 0 when RUN_KEY is non-empty; 1 otherwise.

set -o pipefail

# shellcheck source=/dev/null
. "$(dirname "$0")/wt-identity.sh"

session_id=$(wt_identity_owner)
harness_pid=$(wtid_harness_pid || true)
harness_pid_start=""
[ -n "$harness_pid" ] && harness_pid_start=$(wtid_pid_start "$harness_pid")

run_key="$session_id"
[ -z "$run_key" ] && run_key="$harness_pid"

printf 'SESSION_ID=%s\n' "$session_id"
printf 'HARNESS_PID=%s\n' "$harness_pid"
printf 'HARNESS_PID_START=%s\n' "$harness_pid_start"
printf 'RUN_KEY=%s\n' "$run_key"

[ -n "$run_key" ]

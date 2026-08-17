#!/bin/bash
# auto-stall-watch-cron.sh — launchd entrypoint for the /auto stall detector.
#
# Wraps auto-stall-watch.sh with a launchd-safe PATH, a rolling log, and notification de-duplication.
# launchd strips most of the interactive shell environment, so PATH is set explicitly; `claude` installs
# to ~/.local/bin or /opt/homebrew/bin depending on the install route, jq to Homebrew.
#
# DE-DUPLICATION: the detector is stateless and re-reports a stall on every tick. A stall lasts hours, so
# at a 10-minute cadence that is ~15 identical desktop notifications for one event — which trains the
# operator to dismiss them, defeating the point. The episode key is "<id>:<transcript-mtime>": it stays
# constant while the session is frozen and changes the moment it produces anything, so one episode gets
# one notification and a genuine re-stall gets a fresh one. The log records every tick regardless.
#
# Install: run ~/.claude/update.sh (renders the plist template for $HOME and bootstraps it).
# Unload:  launchctl bootout gui/$(id -u)/com.alienfast.auto-stall-watch

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

LOG_DIR="$HOME/.claude/logs"
LOG="$LOG_DIR/auto-stall-watch.log"
SEEN="$LOG_DIR/.auto-stall-watch-seen"
mkdir -p "$LOG_DIR"
touch "$SEEN"

# Both are hard dependencies: without jq the detector cannot parse the agent list, and without claude it
# cannot obtain one. Either missing makes every run a silent no-op, so fail loudly instead.
missing=""
for bin in jq claude; do command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"; done
if [ -n "$missing" ]; then
  {
    echo "=== stall-watch $(date -u +%Y-%m-%dT%H:%M:%SZ) ABORTED ==="
    echo "ERROR: missing dependencies:$missing (PATH=$PATH)"
    echo
  } >> "$LOG" 2>&1
  command -v osascript >/dev/null 2>&1 && \
    osascript -e "display notification \"stall watcher missing:$missing\" with title \"/auto stall watcher broken\"" >/dev/null 2>&1 || true
  exit 1
fi

result=$("$HOME/.claude/scripts/auto-stall-watch.sh" --json 2>&1)
count=$(printf '%s' "$result" | jq -r '.stalled | length' 2>/dev/null)
in_scope=$(printf '%s' "$result" | jq -r '.in_scope // 0' 2>/dev/null)

# A detector whose output does not parse has NOT reported zero stalls — logging "0 flagged" on a parse
# failure is exactly how the 2026-08-17 schema-drift blindness stayed invisible (BF-1226).
if ! [[ "$count" =~ ^[0-9]+$ ]]; then
  {
    echo "=== stall-watch $(date -u +%Y-%m-%dT%H:%M:%SZ) ERROR — detector output did not parse ==="
    printf '%s\n' "$result" | head -5
    echo
  } >> "$LOG" 2>&1
  command -v osascript >/dev/null 2>&1 && \
    osascript -e "display notification \"stall watcher output unparseable — read $LOG\" with title \"/auto stall watcher broken\"" >/dev/null 2>&1 || true
  exit 1
fi

{
  echo "=== stall-watch $(date -u +%Y-%m-%dT%H:%M:%SZ) — $count flagged, $in_scope in scope ==="
  [ "$count" != "0" ] && printf '%s\n' "$result"
  echo
} >> "$LOG" 2>&1

# BLINDNESS CANARY: an ACTIVE fleet (a fleet-deadline.json whose deadline is still ahead) with ZERO
# in-scope sessions for 3 consecutive ticks is the watcher-is-blind signature — the exact state the
# 2026-08-17 schema drift produced overnight (deadline in the future, three live /auto sessions, 371
# ticks of "0 flagged"). The future-deadline test is the PRIMARY condition: auto-state files persist
# indefinitely after a fleet, so any state-file-based trigger alone would fire forever.
BLIND="$LOG_DIR/.auto-stall-watch-blind"
now_epoch=$(date +%s)
active_deadline=""
while IFS= read -r df; do
  [ -n "$df" ] || continue
  dl=$(jq -r '.deadline_epoch // empty' "$df" 2>/dev/null)
  [[ "$dl" =~ ^[0-9]+$ ]] && [ "$dl" -gt "$now_epoch" ] && { active_deadline="$dl"; break; }
done < <(find "$HOME/projects" -maxdepth 3 -name fleet-deadline.json -type f 2>/dev/null)

if [ -n "$active_deadline" ] && [ "$in_scope" = "0" ]; then
  prev=$(cat "$BLIND" 2>/dev/null || echo "0 0")
  ticks=$(( ${prev%% *} + 1 ))
  notified_for="${prev##* }"
  echo "$ticks $notified_for" > "$BLIND"
  if [ "$ticks" -ge 3 ] && [ "$notified_for" != "$active_deadline" ]; then
    echo "$ticks $active_deadline" > "$BLIND"
    {
      echo "=== stall-watch $(date -u +%Y-%m-%dT%H:%M:%SZ) WATCHER MAY BE BLIND — active fleet (deadline epoch $active_deadline) but 0 in-scope sessions for $ticks consecutive ticks ==="
      echo
    } >> "$LOG" 2>&1
    command -v osascript >/dev/null 2>&1 && \
      osascript -e "display notification \"active fleet but watcher sees 0 /auto sessions — schema drift? read $LOG\" with title \"/auto stall watcher may be blind\" sound name \"Basso\"" >/dev/null 2>&1 || true
  fi
else
  # Healthy tick or no active fleet: reset the streak, keep the last-notified deadline.
  prev=$(cat "$BLIND" 2>/dev/null || echo "0 0")
  echo "0 ${prev##* }" > "$BLIND"
fi

[ "$count" = "0" ] && exit 0

# One notification per stall episode. Silence is measured against the transcript, so its mtime is the
# episode identity — see the header.
fresh=""
while IFS= read -r id; do
  [ -n "$id" ] || continue
  transcript=$(find "$HOME/.claude/projects" -maxdepth 2 -name "$id*.jsonl" -type f 2>/dev/null | head -1)
  mt=$(stat -f %m "$transcript" 2>/dev/null || echo 0)
  key="$id:$mt"
  grep -qxF "$key" "$SEEN" 2>/dev/null && continue
  echo "$key" >> "$SEEN"
  fresh="$fresh $id"
done < <(printf '%s' "$result" | jq -r '.stalled[].id' 2>/dev/null)

# Keep the ledger from growing without bound; 200 episodes is far more than any fleet produces.
tail -200 "$SEEN" > "$SEEN.tmp" 2>/dev/null && mv "$SEEN.tmp" "$SEEN"

[ -n "$fresh" ] || exit 0

command -v osascript >/dev/null 2>&1 && \
  osascript -e "display notification \"Silent mid-iteration:$fresh — run: claude attach <id>\" with title \"/auto session stalled\" sound name \"Basso\"" >/dev/null 2>&1 || true
exit 0

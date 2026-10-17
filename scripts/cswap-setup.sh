#!/usr/bin/env bash
# cswap-setup.sh — opt this machine into multi-account rotation with claude-swap (cswap): install a pinned version,
# enroll this machine's Claude logins, apply the rotation policy, and keep `cswap auto` running under launchd.
#
# WHY A SCRIPT, NOT THE README: cswap's defaults are wrong for us. Its `best` strategy parks on the account with the
# most headroom — the quota with the longest to live — so weekly quota on the soon-to-reset accounts expires unused.
# The policy here is `consume-first`: drain the account whose weekly window resets soonest, move at the threshold, and
# return to it when its 5h window rolls over (cswap re-polls an idle account every 5-10 min, so the return lands within
# about ten minutes of the reset). The threshold is 95 on the binding window (the higher of 5h/7d), not 98: the 5h
# window climbs about a point a minute at p90 and 17 points in the worst minute, against a blind spot of ~90s (60s poll
# plus the macOS Keychain pickup), and a session that has taken a 429 is not rescued by a swap underneath it
# (realiti4/claude-swap#327, measured over 14,070 readings). Per-window thresholds — 5h 95 / 7d 98-99 — are upstream
# #303/#327; raise the weekly line here when they land. Below the threshold consume-first also moves back onto a
# sooner-resetting account that is merely under the line (no landing cap, #327) — the 95 bounds how spent such a
# landing can be.
#
# OPT-IN PER MACHINE. Nothing in the shared config installs or requires cswap; a single-account user never runs this,
# and the fleet scripts read their single-account meter exactly as before. The version is PINNED (CSWAP_PIN): cswap
# holds every account's refresh token and its 0.2x line changes the credential path often; bump the pin deliberately,
# and update.sh says when the installed version has drifted from it.
#
# Usage: cswap-setup.sh [--threshold N] [--strategy best|consume-first] [--version V] [--no-service] [--no-enroll]
#   Enrollment is interactive: the current login is enrolled, then each further account is a `claude auth login`
#   followed by `cswap add` (never /logout first — cswap backs the live login up before the next replaces it). Without
#   a TTY only the current login is enrolled and the remaining commands are printed. Re-run freely: every step is
#   idempotent, and the flags re-apply the policy (the running engine is restarted to pick it up).
# Remove: launchctl bootout gui/$(id -u)/com.alienfast.cswap-auto; uv tool uninstall claude-swap
#   (cswap's account backups stay in the Keychain until `cswap remove`; see its README).
# Run ./cswap-setup.test.sh after ANY change.
set -uo pipefail

CSWAP_PIN="0.27.2"
LABEL="com.alienfast.cswap-auto"
THRESHOLD=95
STRATEGY="consume-first"
VERSION="$CSWAP_PIN"
SERVICE=1
ENROLL=1
here=$(cd "$(dirname "$0")" && pwd)

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --threshold)  THRESHOLD="$2"; shift 2 ;;
    --strategy)   STRATEGY="$2"; shift 2 ;;
    --version)    VERSION="$2"; shift 2 ;;
    --no-service) SERVICE=0; shift ;;
    --no-enroll)  ENROLL=0; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! [[ "$THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk -v t="$THRESHOLD" 'BEGIN { exit !(t >= 50 && t <= 99.9) }'; then
  echo "ERROR: --threshold must be 50..99.9 (cswap's accepted range); got '$THRESHOLD'" >&2; exit 2
fi
case "$STRATEGY" in
  best|consume-first) ;;
  *) echo "ERROR: --strategy must be 'best' or 'consume-first'; got '$STRATEGY'" >&2; exit 2 ;;
esac

os=$(uname -s)
orig_path="$PATH"

step "Checking prerequisites"
for bin in claude jq; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin is not on PATH — run ~/.claude/update.sh first"
done
if ! command -v uv >/dev/null 2>&1; then
  [ "$os" = Darwin ] && die "uv is not on PATH — install it with: brew install uv"
  die "uv is not on PATH — install it: https://docs.astral.sh/uv/getting-started/installation/"
fi
echo "  claude, jq, uv present"

step "Installing claude-swap $VERSION"
bindir=$(uv tool dir --bin 2>/dev/null) || bindir="$HOME/.local/bin"
case ":$PATH:" in *":$bindir:"*) ;; *) export PATH="$bindir:$PATH" ;; esac
have=$(cswap --version 2>/dev/null | awk '{print $2}')
if [ "$have" = "$VERSION" ]; then
  echo "  cswap $have already installed"
else
  [ -n "$have" ] && echo "  cswap $have installed; converging on $VERSION"
  uv tool install --reinstall "claude-swap==$VERSION" || die "uv tool install failed"
  have=$(cswap --version 2>/dev/null | awk '{print $2}')
  [ "$have" = "$VERSION" ] || die "installed claude-swap $VERSION but 'cswap --version' answers '${have:-nothing}' — is $bindir on PATH?"
  echo "  installed cswap $have"
fi

if [ "$ENROLL" = 1 ]; then
  step "Enrolling accounts"
  auth=$(claude auth status --json 2>/dev/null) || auth=""
  logged_in=$(printf '%s' "$auth" | jq -r '.loggedIn // false' 2>/dev/null)
  method=$(printf '%s' "$auth" | jq -r '.authMethod // ""' 2>/dev/null)
  email=$(printf '%s' "$auth" | jq -r '.email // ""' 2>/dev/null)
  [ "$logged_in" = true ] || die "Claude Code is not logged in — run 'claude auth login' (a claude.ai subscription), then re-run"
  [ "$method" = "claude.ai" ] || die "the live login is '$method', not a claude.ai subscription — cswap rotates subscription accounts; run 'claude auth login --claudeai', then re-run"
  echo "  current login ${email:-?}: cswap add"
  cswap add || die "cswap add failed for the current login"
  if [ -t 0 ] && [ -t 1 ]; then
    while true; do
      printf '\n  Add another account? Each is a browser login that REPLACES the live login; cswap holds the previous one. [y/N] '
      read -r ans
      case "$ans" in y|Y|yes) ;; *) break ;; esac
      claude auth login || { echo "  login did not complete; nothing was added" >&2; continue; }
      cswap add || echo "  cswap add failed after that login — re-run this script once it is fixed" >&2
    done
  else
    echo "  no TTY: only the current login was enrolled. For each further account run:"
    echo "      claude auth login && cswap add"
  fi
  echo
  cswap list || true
fi

step "Applying the rotation policy"
cswap config set autoswitch.strategy "$STRATEGY" >/dev/null || die "could not set autoswitch.strategy"
cswap config set autoswitch.threshold "$THRESHOLD" >/dev/null || die "could not set autoswitch.threshold"
echo "  autoswitch.strategy=$STRATEGY autoswitch.threshold=$THRESHOLD (cooldown 300s, hysteresis 10 pts, poll 60s: cswap defaults)"

step "One dry-run tick (decides, never switches)"
rc=0; out=$(cswap auto --once --dry-run --json 2>&1) || rc=$?
printf '%s\n' "$out" | tail -n 3 | sed 's/^/  /'
case $rc in
  0) echo "  → would switch now" ;;
  2) echo "  → nothing to do: the active account is the one to drain" ;;
  3) echo "  → blocked: no viable target (only one account enrolled, or every account at its limit)" ;;
  *) echo "  → the tick errored (exit $rc); see the lines above" ;;
esac

if [ "$SERVICE" = 1 ]; then
  step "Keeping 'cswap auto' running"
  if [ "$os" = Darwin ]; then
    template="$here/../launchd/$LABEL.plist"
    dest="$HOME/Library/LaunchAgents/$LABEL.plist"
    [ -f "$template" ] || die "launchd template missing: $template"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.claude/logs"
    domain="gui/$(id -u)"
    rendered=$(sed "s|__HOME__|$HOME|g" "$template")
    if [ "$rendered" != "$(cat "$dest" 2>/dev/null)" ]; then
      printf '%s\n' "$rendered" > "$dest"
      launchctl bootout "$domain/$LABEL" 2>/dev/null || true
      launchctl bootstrap "$domain" "$dest" && echo "  launchd agent $LABEL loaded" \
        || die "launchctl bootstrap failed; load it by hand: launchctl bootstrap $domain $dest"
    elif launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
      launchctl kickstart -k "$domain/$LABEL" 2>/dev/null && echo "  launchd agent $LABEL restarted on the new policy" \
        || echo "  launchd agent $LABEL already loaded"
    else
      launchctl bootstrap "$domain" "$dest" && echo "  launchd agent $LABEL loaded" \
        || die "launchctl bootstrap failed; load it by hand: launchctl bootstrap $domain $dest"
    fi
    echo "  log: ~/.claude/logs/cswap-auto.log (one JSON event per line)"
  else
    echo "  launchd is macOS-only; run $here/cswap-auto-run.sh under your service manager (systemd --user, tmux)"
  fi
fi

step "Done"
echo "  cswap list                            every account's 5h/7d usage and reset times"
echo "  cswap switch [N|email]                move the login by hand; the engine never undoes a manual move"
echo "  cswap auto --once --dry-run --json    what the engine would do right now"
echo "  tail -f ~/.claude/logs/cswap-auto.log"
echo "  cswap config set autoswitch.model Fable   also leave an account whose Fable weekly limit is spent"
case ":$orig_path:" in
  *":$bindir:"*) ;;
  *) echo "  ⚠️  $bindir is not on your PATH — add it in your shell rc so 'cswap' resolves in new terminals" ;;
esac

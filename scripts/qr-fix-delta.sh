#!/bin/bash
# qr-fix-delta.sh — the /quality-review fix-delta recipe as one command: snapshot the dirty set before a
# cycle's fixes land, then diff the tree against that snapshot once they have.
#
# Usage:
#   qr-fix-delta.sh snapshot <issue|no-issue> <cycle>
#   qr-fix-delta.sh delta    <issue|no-issue> <cycle> [--out <file>]
#   qr-fix-delta.sh dirty    [-0]
#
#   <issue>  a Linear id in any case (BF-3071 → bf-3071), or the literal no-issue
#   <cycle>  an integer, or deferred / corrective (Step 6 sub-step 5's batches)
#
# snapshot  Clears tmp/qr-fix-base-<issue>-<cycle>/ under the repo root (the worktree's root in a worktree) and
#           copies every dirty path outside tmp/ into it, recording deleted paths in a manifest. Prints one summary
#           line. Issue-scoping the directory and clearing it every time is what keeps a previous run's copy from
#           standing in for a missing one (a stale base diffs clean and disarms the fallback).
# delta     Unified diff of the dirty set since the snapshot, `a/<path>` → `b/<path>`, concatenated, to stdout or
#           --out <file>. A path the snapshot holds diffs against its copy, whether it is still dirty or not; a path
#           clean when the snapshot was taken (so absent from it) diffs against HEAD — these are named on stderr as
#           the fallback set. The summary on stderr carries the file and line counts the 200-line inline rule reads.
# dirty     The derived dirty set, one path per line (-0: NUL-terminated, for xargs -0), as `git status` reports it
#           minus tmp/; the same derivation the other two use, for the expected-dirty hash step.
#
# WHY A SCRIPT. The recipe's `rm -rf tmp/qr-fix-base-… && for file in ${(f)"$(git status …)"}; do cp …; done`
# is a shape the Bash tool refuses twice over: the built-in rm safety check cannot parse the zsh `${(f)…}`
# flag and refuses the call, rm or not (standards/shell.md § Reserved names and expansion), and a
# worktree-isolated session refuses any loop or `$(…)`. Every review then improvised its own helper script.
# The target here is always <repo root>/tmp/qr-fix-base-<validated issue>-<validated cycle>, never tmp/
# itself, which is what makes the rm inside safe.
#
# Exit codes: 0 done (an empty delta is 0); 2 bad arguments, not in a git repo, or delta with no snapshot.
#
# Tested by scripts/qr-fix-delta.test.sh (in `pnpm test`), against a real repo and a real linked worktree.

set -uo pipefail

usage() {
  sed -n '2,20p' "$0" >&2
  exit 2
}

die() { echo "qr-fix-delta: $*" >&2; exit 2; }

cmd="${1:-}"
[ -n "$cmd" ] || usage

root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
[ -n "$root" ] || die "could not resolve the repository root"

# Prints the dirty set as `<tag>\0<path>\0` records: F for a path with content on disk, D for a deleted one.
# -z keeps paths with spaces intact and puts a rename's new path first, its old path in the following record.
dirty_records() {
  git -C "$root" status --porcelain=v1 -z --untracked-files=all -- ':!tmp' | {
    while IFS= read -r -d '' entry; do
      x=${entry:0:1}; y=${entry:1:1}; path=${entry:3}
      case "$x" in R|C) IFS= read -r -d '' _old || true ;; esac
      if [ "$x" = D ] || [ "$y" = D ]; then printf 'D\0%s\0' "$path"; else printf 'F\0%s\0' "$path"; fi
    done
  }
}

validate_scope() {
  issue=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  cycle="${2:-}"
  case "$issue" in
    no-issue) ;;
    *) printf '%s' "$issue" | grep -Eq '^[a-z][a-z0-9]*-[0-9]+$' || die "issue must be a Linear id (BF-3071) or no-issue, got '${1:-}'" ;;
  esac
  printf '%s' "$cycle" | grep -Eq '^([0-9]+|deferred|corrective)$' || die "cycle must be an integer, deferred or corrective, got '$cycle'"
  dir="$root/tmp/qr-fix-base-$issue-$cycle"
  manifest="$dir/.qr-manifest"
}

case "$cmd" in
  dirty)
    if [ "${2:-}" = -0 ]; then
      dirty_records | { while IFS= read -r -d '' _tag && IFS= read -r -d '' path; do printf '%s\0' "$path"; done; }
    else
      dirty_records | { while IFS= read -r -d '' _tag && IFS= read -r -d '' path; do printf '%s\n' "$path"; done; }
    fi
    ;;

  snapshot)
    validate_scope "${2:-}" "${3:-}"
    rm -rf "$dir"
    mkdir -p "$dir"
    : > "$manifest"
    copied=0; deleted=0
    while IFS= read -r -d '' tag && IFS= read -r -d '' path; do
      if [ "$tag" = D ]; then
        deleted=$((deleted+1))
      else
        mkdir -p "$dir/$(dirname "$path")"
        cp -L -p "$root/$path" "$dir/$path" || die "could not copy $path"
        copied=$((copied+1))
      fi
      printf '%s\0%s\0' "$tag" "$path" >> "$manifest"
    done < <(dirty_records)
    echo "snapshot: $copied file(s) copied, $deleted deleted path(s) recorded -> $dir"
    ;;

  delta)
    validate_scope "${2:-}" "${3:-}"
    out=""
    if [ "${4:-}" = --out ]; then
      out="${5:-}"; [ -n "$out" ] || die "--out needs a path"
    elif [ -n "${4:-}" ]; then
      die "unknown argument '${4:-}'"
    fi
    [ -f "$manifest" ] || die "no snapshot at $dir — take it with 'snapshot' before the cycle's fixes land; never replay an earlier delta to recover one"

    work=$(mktemp -d "${TMPDIR:-/tmp}/qr-fix-delta.XXXXXX") || die "mktemp failed"
    trap 'rm -rf "$work"' EXIT
    diff_out="$work/delta.diff"; : > "$diff_out"
    snap_paths="$work/snapshot-paths"; : > "$snap_paths"
    fallback=""; files=0

    append_file_diff() { # append_file_diff <left-label> <left> <right-label> <right>
      local rc
      diff -u -L "$1" -L "$3" "$2" "$4" >> "$diff_out"; rc=$?
      [ "$rc" -le 1 ] || die "diff failed on $1 / $3"
      [ "$rc" -eq 1 ] && files=$((files+1))
      return 0
    }

    # Snapshot side: every path the manifest names, dirty now or not.
    while IFS= read -r -d '' tag && IFS= read -r -d '' path; do
      printf '%s\n' "$path" >> "$snap_paths"
      if [ "$tag" = F ]; then
        if [ -e "$root/$path" ]; then append_file_diff "a/$path" "$dir/$path" "b/$path" "$root/$path"
        else append_file_diff "a/$path" "$dir/$path" /dev/null /dev/null; fi
      elif [ -e "$root/$path" ]; then
        append_file_diff /dev/null /dev/null "b/$path" "$root/$path"
      fi
    done < "$manifest"

    # Tree side: paths dirty now that the snapshot never saw were clean when it was taken, so HEAD is their base.
    while IFS= read -r -d '' _tag && IFS= read -r -d '' path; do
      grep -Fxq -- "$path" "$snap_paths" && continue
      fallback="$fallback $path"
      if git -C "$root" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
        before=$(wc -c < "$diff_out")
        git -C "$root" --no-pager diff --no-color --no-ext-diff HEAD -- "$path" >> "$diff_out" || die "git diff failed on $path"
        [ "$(wc -c < "$diff_out")" -gt "$before" ] && files=$((files+1))
      else
        append_file_diff /dev/null /dev/null "b/$path" "$root/$path"
      fi
    done < <(dirty_records)

    lines=$(wc -l < "$diff_out" | tr -d ' ')
    if [ -n "$out" ]; then cp "$diff_out" "$out"; else cat "$diff_out"; fi
    if [ "$files" -eq 0 ]; then
      echo "delta: empty — nothing changed since the snapshot at $dir" >&2
    else
      echo "delta: $files file(s), $lines line(s)${out:+ -> $out}; fallback (clean at snapshot, diffed against HEAD):${fallback:- none}" >&2
    fi
    ;;

  *) usage ;;
esac

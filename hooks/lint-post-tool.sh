#!/usr/bin/env bash
# Claude PostToolUse hook: lint a just-modified file. Silent on clean runs and
# on auto-fixed-only runs (biome --write applies safe fixes silently — the
# agent's mental model can be re-aligned by Read on the next edit if needed).
# Surfaces only what the agent must act on:
#
#   - Unfixable diagnostics from biome or markdownlint (compact format)
#   - Biome plugin load errors (surfaced once per session via ./tmp stamp)
#
# Output channel: JSON to stdout with `hookSpecificOutput.additionalContext`,
# the documented PostToolUse path for adding to the model's context on exit 0.
# Exit code is always 0 — this hook informs, it does not block.
#
# Debug: a one-line summary per invocation is appended to the debug log.
# Verbose logging (full input JSON) when CLAUDE_LINT_HOOK_DEBUG=1.

set -uo pipefail  # NOT errexit: per-command exit codes are managed explicitly

DEBUG_LOG="/tmp/claude-lint-posttool-hook.log"
input=$(cat)

if [[ "${CLAUDE_LINT_HOOK_DEBUG:-}" == "1" ]]; then
  printf '=== %s ===\n%s\n\n' "$(date)" "$input" >> "$DEBUG_LOG"
fi

tool_name=$(jq -r '.tool_name // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
session_id=$(jq -r '.session_id // "unknown"' <<<"$input")

# Per Claude Code's hook input schema, file paths live under `.tool_input.*`
# (NOT `.params.*` — that path returns null and silently disables the hook).
case "$tool_name" in
  Edit|Write)    file_path=$(jq -r '.tool_input.file_path // empty' <<<"$input") ;;
  NotebookEdit)  file_path=$(jq -r '.tool_input.notebook_path // empty' <<<"$input") ;;
  *) exit 0 ;;
esac

[[ -z "$file_path" ]] && exit 0
[[ -n "$cwd" && -d "$cwd" ]] && cd "$cwd"

# Skip if the target file lives outside the project root. Lint configs
# rooted at $cwd shouldn't apply to outside-cwd files, and markdownlint-cli
# (via the `ignore` package) crashes with RangeError on `..`-prefixed
# relative paths. Realpath both sides so symlinked roots compare correctly.
if [[ -n "$cwd" && "$file_path" = /* ]]; then
  abs_file=$(realpath "$file_path" 2>/dev/null || echo "$file_path")
  abs_cwd=$(realpath "$cwd" 2>/dev/null || echo "$cwd")
  if [[ "$abs_file" != "$abs_cwd"/* && "$abs_file" != "$abs_cwd" ]]; then
    exit 0
  fi
fi

# Repo-relative path when possible (GNU realpath; macOS realpath without
# coreutils silently falls through and we keep the absolute path).
if [[ "$file_path" = /* && -n "$cwd" ]]; then
  file_path=$(realpath --relative-to="$cwd" "$file_path" 2>/dev/null || echo "$file_path")
fi

[[ "$file_path" == tmp/* ]] && exit 0
[[ ! -f "$file_path" ]] && exit 0

file_ext="${file_path##*.}"
file_name=$(basename "$file_path")

context_parts=()
append_context() { context_parts+=("$1"); }

emit() {
  if [[ ${#context_parts[@]} -gt 0 ]]; then
    local joined
    joined=$(printf '%s\n\n' "${context_parts[@]}")
    jq -n --arg body "$joined" '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $body
      }
    }'
  fi
  printf '[%s] %s ext=%s context_parts=%d\n' \
    "$(date +%H:%M:%S)" "$file_path" "$file_ext" "${#context_parts[@]}" \
    >> "$DEBUG_LOG"
}
trap emit EXIT

mkdir -p tmp 2>/dev/null
stamp="tmp/.lint-hook-plugin-error-${session_id}"

# Detect premature comment wrapping. See standards/commenting.md: the standard
# is ~160 chars, but training-data muscle memory wraps at ~80. Biome can't
# enforce this (formatter doesn't rewrap comments, by design). So we scan for
# the signature: 3+ consecutive `//` lines where at least one adjacent pair
# could merge under 160 chars. Skips pragmas, lists, license headers, ASCII
# art, commented-out code, triple-slash directives, and bare-`//` paragraph
# separators (which break blocks instead of joining them).
check_comment_widths() {
  local target="$1"
  awk '
    function flush(    i, total, avail, needed, maxw) {
      if (n < 3 || skip) { n = 0; skip = 0; return }
      total = 0
      for (i = 1; i <= n; i++) total += length(content[i])
      total += n - 1                                          # joining spaces
      avail = 160 - indent_len - 3                            # width left after indent + "// "
      if (avail > 0) {
        needed = int((total + avail - 1) / avail)             # ceil(total / avail)
        if (needed < n) {
          maxw = 0
          for (i = 1; i <= n; i++) if (length(lines[i]) > maxw) maxw = length(lines[i])
          printf "  Lines %d-%d: %d-line // block (max width ~%d) — could reflow to %d line%s at 160.\n", start, start + n - 1, n, maxw, needed, (needed == 1 ? "" : "s")
        }
      }
      n = 0; skip = 0
    }
    /^[[:space:]]*\/\// {
      match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH); rest = substr($0, RLENGTH + 1)
      # Triple-slash directives (/// <reference …>) are not prose — never part of a block.
      if (substr(rest, 1, 3) == "///") { flush(); next }
      if (substr(rest, 1, 3) == "// ") body = substr(rest, 4); else body = substr(rest, 3)
      # Bare `//` separator: ends the current block, itself belongs to no block.
      if (body == "") { flush(); next }
      sline = 0
      if (body ~ /^(biome-ignore|eslint-|@ts-|prettier-|TODO|FIXME|HACK|NOTE|XXX|@no-wrap)/) sline = 1
      if (body ~ /^[-*][[:space:]]/ || body ~ /^[0-9]+\.[[:space:]]/) sline = 1
      if (body ~ /['\''")}\]][[:space:]]*,[[:space:]]*$/) sline = 1   # commented-out code (literal closer + comma)
      if (body ~ /[-=+|*_~#]{4,}/) sline = 1                       # ASCII art / banner separators
      if (NR <= 20 && tolower(body) ~ /copyright|license|spdx/) sline = 1
      if (n == 0) { start = NR; indent_len = length(ind) }
      else if (length(ind) != indent_len) { flush(); start = NR; indent_len = length(ind) }
      n++; lines[n] = $0; content[n] = body
      if (sline) skip = 1
      next
    }
    { flush() }
    END { flush() }
  ' "$target"
}

# ----- markdown -----
if [[ "$file_ext" == "md" || "$file_ext" == "markdown" ]]; then
  if [[ -f ".markdownlint.jsonc" || -f ".markdownlint.json" || -f ".markdownlintrc" ]]; then
    npx markdownlint --fix "$file_path" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      issues=$(npx markdownlint "$file_path" 2>&1)
      [[ -n "$issues" ]] && append_context "Markdownlint issues in ${file_name}:"$'\n'"${issues}"
    fi
  fi
fi

# ----- biome -----
case "$file_ext" in
  js|jsx|ts|tsx|json|jsonc|mjs|cjs)
    if [[ -f "biome.jsonc" || -f "biome.json" ]]; then
      write_out=$(npx biome check --write "$file_path" 2>&1)
      write_exit=$?

      # Plugin load errors: surface once per session via stamp file at ./tmp.
      # Subsequent edits in the same session stay quiet so the channel doesn't
      # spam — fix the plugin and the next clean run clears the stamp.
      plugin_err=$(grep -iE 'plugin.*\.grit|failed to load plugin|plugin.*(failed to parse|parse error|invalid)' <<<"$write_out")
      if [[ -n "$plugin_err" ]]; then
        if [[ ! -f "$stamp" ]]; then
          touch "$stamp"
          append_context "Biome plugin load error (surfaced once per session — fix the plugin to clear):"$'\n'"${plugin_err}"
        fi
      else
        [[ -f "$stamp" ]] && rm -f "$stamp"
      fi

      # Unfixable diagnostics: re-run with the github reporter for a compact
      # path:line:col rule  message form. Strip plugin lines (already reported).
      if [[ $write_exit -ne 0 ]]; then
        issues=$(npx biome check --reporter=github "$file_path" 2>&1)
        if [[ -n "$plugin_err" ]]; then
          issues=$(grep -ivE 'plugin.*\.grit|failed to load plugin|plugin.*(failed to parse|parse error|invalid)' <<<"$issues")
        fi
        [[ -n "$issues" ]] && append_context "Biome issues in ${file_name}:"$'\n'"${issues}"
      fi
    fi
    ;;
esac

# ----- comment-width -----
# Runs AFTER biome --write so line numbers reflect the post-format file the
# agent will read next. Skips .d.ts (declaration overloads use intentionally
# vertical comments).
case "$file_ext" in
  js|jsx|ts|tsx|mjs|cjs)
    if [[ "$file_path" != *.d.ts ]]; then
      width_issues=$(check_comment_widths "$file_path")
      if [[ -n "$width_issues" ]]; then
        append_context "Comment-width issues in ${file_name} (See standards/commenting.md — wrap at ~160, not ~80):"$'\n'"${width_issues}"
      fi
    fi
    ;;
esac

exit 0

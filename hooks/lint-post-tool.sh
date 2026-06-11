#!/usr/bin/env bash
# Claude PostToolUse hook: lint a just-modified file. Silent on clean runs and
# on auto-fixed-only runs (biome --write applies safe fixes silently — the
# agent's mental model can be re-aligned by Read on the next edit if needed).
# Surfaces only what the agent must act on:
#
#   - Unfixable diagnostics from biome, markdownlint, or rubocop (compact format)
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

# Skip scratch files in any tmp/ directory — root-level (tmp/foo.md) or nested, e.g. a worktree's .claude/worktrees/pl-XX/tmp/foo.md. Match a tmp/ path
# segment whether file_path is repo-relative or still absolute: on macOS the BSD realpath above can't make it relative, so a bare `tmp/*` prefix never matches.
# This is the single chokepoint that keeps throwaway files out of every linter — the project's root-anchored `.markdownlintignore` `tmp/**` misses the nested case.
case "$file_path" in
  tmp/*|*/tmp/*) exit 0 ;;
esac
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
# is ~160 chars, but training-data muscle memory wraps at ~80. Formatters can't
# enforce this (they don't rewrap comments, by design). So we scan for the
# signature: 3+ consecutive comment lines where at least one adjacent pair could
# merge under 160 chars. The comment lead is passed in ("//" for JS/TS, "#" for
# Ruby). Skips pragmas, lists, license headers, ASCII art, commented-out code,
# triple-slash directives, and bare-lead paragraph separators (which break
# blocks instead of joining them). Known limitation: line-based, no language
# parser — string/heredoc/template-literal lines that start with the marker can
# be misread as comments. Advisory-only (never blocks), so the rare false
# positive is acceptable rather than worth a parser.
check_comment_widths() {
  local target="$1"
  local marker="$2"   # comment lead: "//" for JS/TS, "#" for Ruby
  awk -v marker="$marker" '
    BEGIN { ml = length(marker); linere = "^[[:space:]]*" marker }
    function flush(    i, total, avail, needed, maxw) {
      if (n < 3 || skip) { n = 0; skip = 0; return }
      total = 0
      for (i = 1; i <= n; i++) total += length(content[i])
      total += n - 1                                          # joining spaces
      avail = 160 - indent_len - (ml + 1)                     # width left after indent + "marker "
      if (avail > 0) {
        needed = int((total + avail - 1) / avail)             # ceil(total / avail)
        if (needed < n) {
          maxw = 0
          for (i = 1; i <= n; i++) if (length(lines[i]) > maxw) maxw = length(lines[i])
          printf "  Lines %d-%d: %d-line %s block (max width ~%d) — could reflow to %d line%s at 160.\n", start, start + n - 1, n, marker, maxw, needed, (needed == 1 ? "" : "s")
        }
      }
      n = 0; skip = 0
    }
    $0 ~ linere {
      match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH); rest = substr($0, RLENGTH + 1)
      # Triple-slash directives (/// <reference …>) are not prose — never part of a block. JS/TS only.
      if (ml == 2 && substr(rest, 1, 3) == "///") { flush(); next }
      if (substr(rest, 1, ml + 1) == marker " ") body = substr(rest, ml + 2); else body = substr(rest, ml + 1)
      # Bare lead (e.g. a lone `//` or `#`): ends the current block, belongs to none.
      if (body == "") { flush(); next }
      # Decoration / RDoc delimiter lines whose body is ALL punctuation, never prose: ### -> "##", #++/#-- (RDoc visibility), # === banners, # => result
      # markers. They bracket a prose block, they are not part of it, so they end the current block and belong to none (same role as the bare lead above). The
      # 4+-run ASCII-art rule further down only catches long banners and sets skip (suppressing the WHOLE block) — it cannot see these 2-char markers, and even if
      # it could, suppressing is wrong here: we want the bracketed prose evaluated on its own, just without the delimiter lines polluting the line count and width
      # math. This is what made the Rails new_framework_defaults_*.rb files report nonsense ("7-line block could reflow to 3") — ###, #++, and the commented-out
      # config line below #++ were all being counted as prose. Breaking on the punctuation-only lines isolates each to its own short block, which then falls
      # under the 3-line threshold or reflows correctly. Bodies with any alphanumeric char (incl. backtick-led `code` prose) stay prose and are unaffected.
      if (body !~ /[[:alnum:]]/) { flush(); next }
      sline = 0
      if (body ~ /^(biome-ignore|eslint-|@ts-|prettier-|TODO|FIXME|HACK|NOTE|XXX|@no-wrap|rubocop:|:nodoc:|noinspection)/) sline = 1
      # Ruby magic comments (ml==1, the "#" marker only) are meaningful solely in
      # the file head — gate on NR so the same words mid-file (as prose) remain
      # flaggable, and on ml==1 so a JS/TS "// encoding:" prose comment is not
      # wrongly suppressed (mirrors the ml==2 triple-slash gate above). Shebang too.
      if (ml == 1 && NR <= 5 && body ~ /^(frozen_string_literal|encoding:|coding:)/) sline = 1
      if (NR == 1 && substr(body, 1, 1) == "!") sline = 1            # shebang (#!/usr/bin/env ruby)
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

# ----- ruby -----
# Mirrors the biome flow: apply safe autocorrections silently (rubocop -a, the
# analog of biome --write — safe fixes only, NOT --autocorrect-all), then
# surface just the offenses rubocop couldn't fix in compact emacs format
# (path:line:col: severity: message). Gated on a .rubocop.yml so we don't impose
# rubocop's opinionated defaults on a project that never opted in. Prefer the
# bundle-pinned rubocop when Gemfile.lock locks the core gem, else the global one.
# Match by basename: covers *.rb/*.rake/*.gemspec plus the extensionless
# Gemfile/Rakefile (keying on $file_ext would mis-split a dotted path like
# ~/.claude/Gemfile). rubocop lints all of these by default.
case "$file_name" in
  *.rb|*.rake|*.gemspec|Gemfile|Rakefile)
    if [[ -f ".rubocop.yml" || -f ".rubocop.yaml" ]]; then
      rubocop_cmd=(rubocop)
      # Match only the resolved top-level spec — 4-space indent under `specs:`,
      # name followed by `(version)`. A looser pattern also matches 6-space nested
      # constraints (`      rubocop (>= 2.0)`) or stops at `rubocop-rails`, which
      # could pick `bundle exec rubocop` when the core gem isn't actually runnable.
      if [[ -f "Gemfile.lock" ]] && grep -qE '^    rubocop \(' Gemfile.lock; then
        rubocop_cmd=(bundle exec rubocop)
      fi
      "${rubocop_cmd[@]}" --autocorrect --format quiet "$file_path" >/dev/null 2>&1
      rubocop_exit=$?
      # Surface ONLY genuine offenses (rubocop exit 1). Exit 0 = clean or fully
      # autocorrected; exit >=2 = config/usage error; 127 = rubocop not installed
      # despite a .rubocop.yml (the global gem carries no install guarantee, unlike
      # npx-resolved biome). Those are setup problems, not lint findings — surfacing
      # their stderr would inject "command not found" into the agent's context on
      # every Ruby edit, so we stay silent on anything other than exit 1.
      if [[ $rubocop_exit -eq 1 ]]; then
        issues=$("${rubocop_cmd[@]}" --format emacs "$file_path" 2>&1)
        [[ -n "$issues" ]] && append_context "RuboCop issues in ${file_name}:"$'\n'"${issues}"
      fi
    fi
    ;;
esac

# ----- comment-width -----
# Runs AFTER the formatters so line numbers reflect the post-format file the
# agent will read next. Picks the comment lead per language: // for JS/TS, # for
# Ruby. Skips .d.ts (declaration overloads use intentionally vertical comments).
comment_marker=""
case "$file_ext" in
  js|jsx|ts|tsx|mjs|cjs) [[ "$file_path" != *.d.ts ]] && comment_marker="//" ;;
esac
case "$file_name" in
  *.rb|*.rake|*.gemspec|Gemfile|Rakefile) comment_marker="#" ;;
esac
if [[ -n "$comment_marker" ]]; then
  width_issues=$(check_comment_widths "$file_path" "$comment_marker")
  if [[ -n "$width_issues" ]]; then
    append_context "Comment-width issues in ${file_name} (See standards/commenting.md — wrap at ~160, not ~80):"$'\n'"${width_issues}"
  fi
fi

exit 0

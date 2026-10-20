# Shell: the tool shell is zsh

Every `Bash` tool call runs **zsh**, not bash. Bash-only idioms fail silently rather than erroring, so a wrong exit
code or an empty variable reads as success. A script you write to a file and run with `zsh tmp/<name>.sh` or `bash <name>.sh`
follows that interpreter's rules instead; `/bin/bash` on macOS is 3.2. `hooks/zsh-trap-guard.sh` refuses the
deterministic traps below with the fix in its message.

## Exit status

- `${PIPESTATUS[0]}` expands to nothing: zsh's array is lowercase `pipestatus` and 1-indexed. Use `${pipestatus[1]}`,
  `set -o pipefail`, or drop the pipe: `cmd > tmp/out.log 2>&1; echo "EXIT=$?"`.
- A backgrounded call reports its *last* statement's status, so `cmd > log 2>&1; echo "EXIT=$?"` reports the `echo`
  and a command that died at 127 notifies as exit 0. Make the command the final statement, or capture and re-raise:
  `rc=0; cmd > tmp/out.log 2>&1 || rc=$?; echo "EXIT=$rc" >> tmp/out.log; exit $rc`.
- `status` is a read-only synonym for `$?`: every `status=…`, `local status=` included, aborts the call, and it aborts
  *after* the captured command already ran, so a call that looks failed may have committed its side effect. Use
  `rc=$?`, and re-check external state before retrying a capture-then-check helper that died this way.

## Reserved names and expansion

- `path`, `cdpath`, `fpath` and `manpath` are arrays tied to `PATH` and friends. `for path in …` or `read -r label path`
  replaces the command search path, and every later non-builtin dies with *command not found*; behind `2>/dev/null` that
  is an all-zero table that reads as "absent everywhere". Name loop and `read` variables `p` or `file`, and never swallow
  stderr inside a loop whose zero is a finding.
- Unquoted parameter expansion does **not** word-split: `p="a b"; set -- $p` gives one argument where bash gives two.
  Use `${=p}`, a real array (`p=(a b); cmd "$p[1]" "$p[2]"`), or write the calls out. `$(…)` still splits, which is
  what hides the asymmetry.
- `${var,,}` / `${var^^}` are a `bad substitution` that aborts the whole call; inside a subshell or pipeline segment only
  that segment dies and `$?` reads 0, so a batch loop skips iterations and reports success. Use `${var:l}` / `${var:u}`.
- `$var:` followed by a modifier letter is a zsh modifier, quoted or not: `a A c e h l P q Q r s t u` always, `F` and `W`
  depending on what follows. `git cat-file -e "$tag:apps/x"` asks about `<cwd>/v5.1.38pps/x` and reads as "absent"
  behind `2>/dev/null`. Brace the name (`${tag}:apps/x`) or follow the colon with another expansion (`"$tag:$file"`).
- An unquoted leading `=` is EQUALS expansion (`=ls` → `/bin/ls`); `echo =====` aborts the call. Quote it.
- Quote glob patterns in command flags (`--include='*.md'`, `-name '*.rb'`). Unquoted, zsh expands them against the cwd
  first: no match aborts the call with `no matches found`; a match silently substitutes filenames and the command runs on
  the wrong argument and exits 0. Inside a pipeline the abort is subshell-contained, so a trailing `|| echo none` turns a
  search that never ran into a verified empty result.

## Redirects

- The tool shell may inherit `NO_CLOBBER` from the interactive rc (whether it survives varies by harness version). Then
  `>` refuses to overwrite and `>>` refuses to create, and two shapes hide it: a backgrounded `nohup … > log 2>&1 &`
  whose log exists never launches yet exits 0, leaving the previous run's log to be read as this run's (check the
  mtime); a failed `: > file` truncation turns a build-by-append loop into a doubled file. Use `>|` (truncate regardless)
  and `>>|` (append-or-create) by reflex in tool-call redirects. Script bodies and `zsh -c` children never source the rc.
- In a worktree-isolated session `>>|` is refused by the isolation guard while `>|` and `>>` run: `>>|` is zsh-only and a
  bash syntax error, so the bash-grammar check cannot read it as a redirect. Build the file with one `>|` write, or put
  the sequence in `tmp/<name>.sh` and run `zsh tmp/<name>.sh`; script bodies are never analyzed.

## Heredocs and literal characters

- A heredoc that contains another heredoc ends at the first line matching the outer delimiter, and **everything after
  that line executes** in the tool shell with every variable unset (`rm -rf "$REPO/tmp"` becomes `rm -rf /tmp`). Give
  the outer heredoc a delimiter unique to the payload, or write files that embed heredocs with the Write tool.
- Build control and invisible characters from codepoints (`0.chr`, `0xFF0C.chr('UTF-8')`, `String.fromCharCode(0)`),
  never from backslash-u escapes: an Edit/Write payload lands the escape as the real character, a repair Edit cannot
  match it, and a real NUL makes the file binary, which the bundled grep (ugrep with `-I`) skips silently; a `grep -r`
  over a tree exits 0 with that file missing from the results. `grep -a`, `/usr/bin/grep` and `rg` still see it.

## Searching and extracting

- grep is line-oriented. A multi-word phrase that straddles a wrapped line (comments wrap at ~160 characters, and
  several rule docs hard-wrap) returns nothing, and the empty result reads as "the text is gone". Grep the shortest
  distinctive token that cannot wrap, and confirm a zero-hit with a second, broader pattern before concluding anything
  is absent. A multiline mode is no rescue: the wrap injects indentation and the comment marker between the words.
- `grep A | grep B` needs A and B on the same physical line; a wrapped method chain or argument list drops members and
  the smaller set reads as complete. Filter at file scope (`grep -rl A …` and read the hits, or intersect two `-l` runs).
- `cut -d,` and `awk -F,` neither understand CSV quoting nor check your field index; both failures print plausible
  columns and exit 0, and a quoted comma shifts every later field on that row only. Confirm the field number against the
  header, and prefer a whole-file `grep -c` on a pattern that cannot shift, or a real parser (`ruby -rcsv`).
- macOS `/usr/bin/awk` counts bytes, not characters: `awk 'length > 160'` over-counts multi-byte text. It never misses a
  long line, so use it as the first pass and confirm with `grep -n '.\{161,\}' <file>`.

# Git on Windows Git Bash

The shell is MSYS but `git`, `jq`, `python` and `gh` are native Windows binaries, and both halves rewrite what passes
between them. Every rule below is harmless on macOS and Linux, so write scripts to it everywhere.

## `ref:path` arguments

MSYS path conversion mangles some colon arguments: `git show origin/main:.gitignore` becomes `origin\main;.gitignore`
(`fatal: ambiguous argument`). It triggers when the ref contains `/` and the path starts with a dot
(`origin/main:package.json` passes, `origin/main:.claude/settings.json` fails), so it looks intermittent. Prefix any
`ref:path` command with `MSYS_NO_PATHCONV=1`:

```bash
MSYS_NO_PATHCONV=1 git show origin/main:.gitignore
```

## Comparing paths

`pwd -P` is not canonical on MSYS: it normalizes differently depending on the input path format, so `cd C:/Users/…` and
`cd /c/Users/…` are the same location and can resolve to different strings, and a path under a mount alias (`/tmp` →
`AppData/Local/Temp`) resolves to `/tmp/…` from one entry form and `/c/Users/…/Temp/…` from another. Git compounds this:
`git rev-parse --show-toplevel` (and `--absolute-git-dir`, `--git-common-dir`) emit Windows form (`C:/Users/…`) while
the surrounding shell carries MSYS form (`/c/Users/…`).

Never test path identity by string-comparing resolved paths, and never derive a value one script `pwd -P`-resolves that
another script compares against (a per-repo lock key from `cd "$common_dir" && pwd -P`): the two diverge by input format
alone. Prefer a structural signal independent of path format: to tell a registered linked worktree from an orphaned
directory, test the shape of `git rev-parse --absolute-git-dir` (`*/worktrees/*`) plus the worktree's own `.git`
pointer, not `--show-toplevel` against the directory string.

## Native tools behind the shell

- **The winget `jq` ends every output line with CRLF.** `$(…)` strips the trailing CR with the newline, so most call
  sites work, but `read` keeps it, and a `while read id …` loop then walks `TT-26\r`. `update.sh` installs a `~/bin/jq`
  shim that adds `-b` (jq's LF switch) to every call; a machine that has not run it shows exactly that symptom.
- **Python writes stdio in the console code page with CRLF.** A `→` or `≈` in a report line raises `UnicodeEncodeError`
  under cp1252, and `open()` / `read_text()` decode files the same way. Every `.py` entry point reconfigures stdio to
  UTF-8 with LF and passes `encoding="utf-8"` explicitly. `python3` itself is a `~/bin` shim from `update.sh`
  (python.org ships `python.exe` only).
- **A POSIX-looking argument to a native binary is rewritten before the binary sees it**: `jq -n --arg p /tmp/x.rb`
  arrives as `C:/Users/<you>/AppData/Local/Temp/x.rb`, and a `.py` script echoes back the native spelling of any path it
  was handed. A test that hands a system path to a native tool as *data* sets `MSYS_NO_PATHCONV=1`; one that asserts on
  an echoed path compares through `wt_path_native` (`scripts/wt-path.sh`), never the raw `mktemp` string.
- **The POSIX-liveness suites self-skip here.** `wt-restamp`, `wt-disown` and `reap-worktrees` are built on
  `ps -o lstart=` / `-o comm=` / `-o ppid=`, and MSYS `ps` has no `-o` at all, so every death verdict degrades to
  `unknown` and their fixtures cannot be expressed. Each prints one counted `SKIP` line and exits 0 on
  `MINGW*|MSYS*|CYGWIN*`, so `pnpm test` stays green without mistaking the gap for coverage; `FORCE_POSIX_SUITES=1` runs
  one anyway. The same limitation is why a stale worktree on Windows needs a manual `wt-disown.sh --force` instead of
  being auto-resumed.
- **pnpm runs package scripts through cmd.exe here and reads `scriptShell` only from `pnpm-workspace.yaml`**, which pins
  `scriptShell: bash`; a project `.npmrc` or `npm_config_script_shell` is ignored. Without the pin a `hooks/x.test.sh && …`
  chain dies at *'hooks' is not recognized*, and a quoted glob reaches markdownlint with its quotes intact (0 files
  linted, exit 0). A machine without `bash` on PATH fails loudly with spawn ENOENT rather than mis-parsing.

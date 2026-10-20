---
paths:
  - "**/*.sh"
  - "**/*.bash"
  - "**/bin/*"
  - "**/script/*"
---

# Shell scripts

Rules for scripts written to a file. The tool shell itself is zsh; its traps are in
[standards/shell.md](../standards/shell.md).

## Which bash runs the script

- macOS `/bin/bash` is permanently 3.2, so a `#!/bin/bash` script runs on 3.2 locally, and so does a
  `#!/usr/bin/env bash` script unless a newer bash (Homebrew's) sits ahead on `PATH`. Linux CI executors run 5.x. The
  hazards below are local-macOS-specific, not a shebang quirk; verify on the interpreter the script actually gets.
- `/bin/bash -n <script>` is a cheap parse check and, on macOS, also rejects bash-4-only syntax (`;;&`, `|&`). It catches
  nothing at runtime: not the empty-array crash below, not a bash-4 builtin such as `declare -A`.

## `set -u` crashes on any empty array under bash < 4.4

`"${arr[@]}"` and `"${arr[*]}"` are both fatal `unbound variable` errors when `arr` is declared but empty; bash 4.4 fixed
it and 3.2 has it. Two shapes hit it:

- **A conditionally modified copy of the positional parameters** (`local args=("$@")`, then
  `args=(--flag "${args[@]}")`): rebind the function's own parameters instead, `set -- --flag "$@"`, which only rebinds
  inside that function. Never at a script's top level, where `set --` rewrites the live `$@` the dispatcher is about to
  read.
- **An auxiliary array alongside real positional args** (`extra=(); [ -n "$X" ] && extra+=(--x "$X")`): guard the
  expansion with the alternate-value idiom, `cmd "$@" ${extra[@]+"${extra[@]}"}`, which expands to nothing when empty.

Inside `$(…)` or a pipeline the crash kills only that subshell: the caller continues with an empty value and a non-zero
`$?`, so the quieter failure is the common one.

## A script resolves its repo from its own path

A script that sets `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` acts on the checkout it lives in,
whatever the shell's cwd. Invoked through an absolute path into another checkout or worktree, that checkout becomes the
actor (its slot, its registry, its stacks). Call a repo's scripts through a path inside the checkout you mean.

## Nothing gates a script that no test drives

Type and lint checks parse no shell, and most repos ship no shellcheck or shell test harness, so a green check is no
evidence for a script change unless a test covers it (a `*.test.sh` sibling run by hand, or a vitest that drives the
script as a subprocess). Verify by executing the script, in a throwaway worktree with heavy tools stubbed on `PATH` if
it drives containers, and say in the script's header how it is tested.

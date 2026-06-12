#!/bin/bash
# Pipes file content to linear-cli via stdin.
# Usage: linear-stdin.sh <file> <linear-cli-args...>
# Example: linear-stdin.sh tmp/comment.md issues comment PL-13 --body -
export PATH="$HOME/.cargo/bin:$PATH"
file="$1"; shift
linear-cli "$@" < "$file"

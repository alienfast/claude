#!/bin/bash
# Pipes file content to linear CLI via stdin
# Usage: linear-stdin.sh <file> <linear-args...>
# Example: linear-stdin.sh tmp/desc.md issues update PL-13 --description -
file="$1"; shift
linear "$@" < "$file"

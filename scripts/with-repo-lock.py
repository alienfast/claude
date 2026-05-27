#!/usr/bin/env python3
# with-repo-lock.py — Run a command while holding an exclusive flock keyed
# by a path (sha256 of realpath → ~/.claude/locks/repo-<sha>.lock). The OS
# releases the lock on exec'd process exit, including SIGKILL.

import fcntl
import hashlib
import os
import sys
import time


def main() -> None:
    if len(sys.argv) < 3:
        print("usage: with-repo-lock.py <key-path> <cmd> [args...]", file=sys.stderr)
        sys.exit(2)

    key_arg = sys.argv[1]
    cmd = sys.argv[2:]

    if not os.path.exists(key_arg):
        print(f"[finish-queue] ERROR: key-path does not exist: {key_arg}", file=sys.stderr)
        sys.exit(2)

    key_path = os.path.realpath(key_arg)
    sha = hashlib.sha256(key_path.encode()).hexdigest()[:16]
    lock_dir = os.path.expanduser("~/.claude/locks")
    os.makedirs(lock_dir, exist_ok=True)
    lock_path = os.path.join(lock_dir, f"repo-{sha}.lock")

    fd = os.open(lock_path, os.O_WRONLY | os.O_CREAT, 0o644)

    t0 = time.monotonic()
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"[finish-queue] waiting for {key_path} ...", file=sys.stderr, flush=True)
        fcntl.flock(fd, fcntl.LOCK_EX)
        elapsed = time.monotonic() - t0
        print(f"[finish-queue] acquired after {elapsed:.1f}s", file=sys.stderr, flush=True)

    os.ftruncate(fd, 0)
    os.write(fd, f"pid={os.getpid()} key={key_path}\n".encode())

    flags = fcntl.fcntl(fd, fcntl.F_GETFD)
    fcntl.fcntl(fd, fcntl.F_SETFD, flags & ~fcntl.FD_CLOEXEC)

    try:
        os.execvp(cmd[0], cmd)
    except OSError as e:
        print(f"[finish-queue] ERROR: cannot exec {cmd[0]!r}: {e}", file=sys.stderr)
        sys.exit(127)


if __name__ == "__main__":
    main()

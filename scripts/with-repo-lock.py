#!/usr/bin/env python3
# with-repo-lock.py — Run a command while holding an exclusive lock keyed
# by a path (sha256 of realpath → ~/.claude/locks/repo-<sha>.lock). The OS
# releases the lock on process exit, including SIGKILL.
#
# Unix: flock + execvp (the command replaces this process; the inherited fd
# holds the lock for the command's lifetime). Windows: msvcrt.locking +
# subprocess (execvp on Windows spawns a new pid and orphans the caller's
# waiter, so the wrapper stays alive holding the lock and forwards the exit
# code instead).

import hashlib
import os
import subprocess
import sys
import time

if os.name == "nt":
    import msvcrt
else:
    import fcntl


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
    if os.name == "nt":
        # Lock byte 0; file position must be 0 for the region to be the one
        # every contender locks. LK_NBLCK is the only sane primitive (LK_LOCK
        # gives up after ~10s), so blocking = poll.
        os.lseek(fd, 0, os.SEEK_SET)
        try:
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
        except OSError:
            print(f"[finish-queue] waiting for {key_path} ...", file=sys.stderr, flush=True)
            while True:
                try:
                    msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                    break
                except OSError:
                    time.sleep(0.5)
            elapsed = time.monotonic() - t0
            print(f"[finish-queue] acquired after {elapsed:.1f}s", file=sys.stderr, flush=True)
    else:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"[finish-queue] waiting for {key_path} ...", file=sys.stderr, flush=True)
            fcntl.flock(fd, fcntl.LOCK_EX)
            elapsed = time.monotonic() - t0
            print(f"[finish-queue] acquired after {elapsed:.1f}s", file=sys.stderr, flush=True)

    os.ftruncate(fd, 0)
    os.write(fd, f"pid={os.getpid()} key={key_path}\n".encode())

    if os.name == "nt":
        # Windows can't PID-tie the "already locked" sentinel (no exec-in-place:
        # the child gets a fresh PID, so finish-merge.sh's `$$` check re-locks and
        # deadlocks against us). Signal lock-held-ness explicitly instead; only
        # this wrapper ever sets it, and it dies with this process tree.
        os.environ["_WITH_REPO_LOCK_HELD"] = key_path
        # Callers pass shell scripts directly (finish-merge.sh re-execs itself);
        # CreateProcess can't run those (WinError 193) — retry through bash.
        try:
            rc = subprocess.call(cmd)
        except OSError as e:
            if isinstance(e, FileNotFoundError) or getattr(e, "winerror", None) == 193:
                try:
                    rc = subprocess.call(["bash", *cmd])
                except OSError as e2:
                    print(f"[finish-queue] ERROR: cannot exec {cmd[0]!r} (bash fallback failed: {e2})", file=sys.stderr)
                    sys.exit(127)
            else:
                print(f"[finish-queue] ERROR: cannot exec {cmd[0]!r}: {e}", file=sys.stderr)
                sys.exit(127)
        sys.exit(rc)

    flags = fcntl.fcntl(fd, fcntl.F_GETFD)
    fcntl.fcntl(fd, fcntl.F_SETFD, flags & ~fcntl.FD_CLOEXEC)

    try:
        os.execvp(cmd[0], cmd)
    except OSError as e:
        print(f"[finish-queue] ERROR: cannot exec {cmd[0]!r}: {e}", file=sys.stderr)
        sys.exit(127)


if __name__ == "__main__":
    main()

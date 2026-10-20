#!/usr/bin/env bash
# context-cost.sh — how many bytes of instructions does a session in this project load, and what does one edit inject?
#
# WHY: CLAUDE.md files and unscoped rules load every session; a path-scoped rule loads the first time a matching file is
# read or edited; every skill description sits in the listing on every turn. None of that is visible from inside a
# session except through /context, which needs a live session. This prints the same accounting from the files alone, so
# a config change can be measured before and after, and /reflect sweep can flag a regression.
#
# Usage: context-cost.sh [project-dir] [--paths p1,p2,…]
#   project-dir   defaults to the cwd; the user tree is $CLAUDE_USER_DIR (default ~/.claude)
#   --paths       repo-relative sample files to cost; defaults to a representative monorepo set
#
# Tokens are approximated as bytes/4. Globs follow the rule semantics: `**/` spans directories, `*` stays within one
# path segment, `{a,b}` alternates, and a pattern without `/` matches only at the project root.
#
# Run ./context-cost.test.sh after ANY change.

set -uo pipefail

PROJECT="$PWD"
SAMPLES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --paths) SAMPLES="${2:-}"; shift 2 ;;
    *) PROJECT="$1"; shift ;;
  esac
done

PROJECT="$PROJECT" USER_DIR="${CLAUDE_USER_DIR:-$HOME/.claude}" SAMPLES="$SAMPLES" python3 -I - <<'CONTEXT_COST_PY'
import glob, os, re

proj = os.path.abspath(os.environ["PROJECT"])
user = os.path.abspath(os.path.expanduser(os.environ["USER_DIR"]))
samples = [s for s in os.environ.get("SAMPLES", "").split(",") if s] or [
    "apps/api/app/models/user.rb", "apps/api/app/graph/mutations/foo.rb", "apps/api/app/concepts/user/foo.rb",
    "apps/api/spec/models/foo_spec.rb", "apps/app/src/domains/foo/Bar.tsx", "apps/app/src/lib/auth/foo.ts",
    "packages/ui/src/foo.tsx", "packages/ui/src/foo.stories.tsx", "packages/form/src/foo.ts",
    "ops/stacks/foo/index.ts", "package.json", "doc/foo.md",
]


def size(p):
    try:
        return os.path.getsize(p)
    except OSError:
        return 0


def frontmatter(path):
    """Return the frontmatter as {key: [values]}; a missing or unparseable block is {}."""
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end < 0:
        return {}
    out, key, buf = {}, None, []
    for line in text[3:end].split("\n"):
        m = re.match(r"^([A-Za-z_-]+):\s*(.*)$", line)
        if m and not line.startswith((" ", "\t", "-")):
            if key:
                out[key] = buf
            key, v = m.group(1), m.group(2).strip()
            buf = [v] if v and v not in (">", "|", ">-", "|-") else []
        elif key is not None:
            s = line.strip()
            if s.startswith("- "):
                s = s[2:].strip()
            if s:
                buf.append(s)
    if key:
        out[key] = buf
    return out


def paths_of(fm):
    vals = fm.get("paths")
    if vals is None:
        return None
    out = []
    for v in vals:
        v = v.strip()
        if v.startswith("[") and v.endswith("]"):
            v = v[1:-1]
        # A comma separates patterns only outside a {a,b} brace group.
        for part in re.split(r",(?![^{]*\})", v):
            part = part.strip().strip('"').strip("'")
            if part:
                out.append(part)
    return out


def glob_re(g):
    i, out = 0, ""
    while i < len(g):
        if g.startswith("**/", i):
            out += "(?:.*/)?"; i += 3; continue
        if g.startswith("**", i):
            out += ".*"; i += 2; continue
        c = g[i]
        if c == "*":
            out += "[^/]*"
        elif c == "?":
            out += "[^/]"
        elif c == "{" and g.find("}", i) > i:
            j = g.find("}", i)
            out += "(?:" + "|".join(re.escape(a) for a in g[i + 1:j].split(",")) + ")"; i = j
        elif c == "[" and g.find("]", i) > i:
            j = g.find("]", i)
            out += g[i:j + 1]; i = j
        else:
            out += re.escape(c)
        i += 1
    return re.compile("^" + out + "$")


def rules(root, label):
    out = []
    for p in sorted(glob.glob(os.path.join(root, "**", "*.md"), recursive=True)):
        fm = frontmatter(p)
        if fm is None:
            continue
        out.append((label + "/" + os.path.relpath(p, root), size(p), paths_of(fm)))
    return out


def descriptions(root):
    total, n = 0, 0
    for p in sorted(glob.glob(os.path.join(root, "*", "SKILL.md"))):
        fm = frontmatter(p) or {}
        total += len(" ".join(fm.get("description", []) + fm.get("when_to_use", [])))
        n += 1
    return n, total


def tok(b):
    return f"~{b // 4:,} tok"


all_rules = rules(os.path.join(user, "rules"), "user rules") + rules(os.path.join(proj, ".claude", "rules"), "project rules")
always = [(os.path.relpath(p, proj) if p.startswith(proj) else p, size(p)) for p in (
    os.path.join(user, "CLAUDE.md"), os.path.join(proj, "CLAUDE.md"), os.path.join(proj, ".claude", "CLAUDE.md"),
    os.path.join(proj, "CLAUDE.local.md")) if size(p)]
always += [(name, b) for name, b, globs in all_rules if globs is None]
always_total = sum(b for _, b in always)

print(f"Always-on in {proj} (loaded every session)")
for name, b in always:
    print(f"  {b:>9,}  {name}")
print(f"  {always_total:>9,}  TOTAL ({tok(always_total)})")

un, uc = descriptions(os.path.join(user, "skills"))
pn, pc = descriptions(os.path.join(proj, ".claude", "skills"))
print()
print(f"Skill listing (every turn): user {un} skills {uc:,} chars; project {pn} skills {pc:,} chars; "
      f"total {uc + pc:,} chars ({tok(uc + pc)})")

print()
print("Injection by sample edit (always-on + every path rule the edit matches)")
for rel in samples:
    hits = [(name, b) for name, b, globs in all_rules if globs and any(glob_re(g).match(rel) for g in globs)]
    total = always_total + sum(b for _, b in hits)
    names = ", ".join(f"{name} {b:,}" for name, b in hits) or "none"
    print(f"  {rel}  = {total:,} ({tok(total)})  [rules: {names}]")
CONTEXT_COST_PY

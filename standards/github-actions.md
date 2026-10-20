# CI Standards (GitHub Actions, CircleCI)

## Trace a CI behavior to the builds that actually run it

Finding a function in the CI tooling and a job that calls it says nothing about whether an ordinary PR build runs it,
and concluding that a workflow never reaches it is the mirror error. Before claiming any CI behavior applies to a normal
build, trace function → every job that calls it (including indirectly, through another CI function) → every workflow
that lists each job → that workflow's `when:` gate → that job's `branches:` filter.

## SHA-Pinning Third-Party Actions

When SHA-pinning a GitHub Action, resolve the pin with:

```bash
gh api repos/<owner>/<repo>/commits/refs/tags/<tag> --jq .sha
```

The `commits` endpoint peels annotated tags to the underlying commit SHA, which is what `uses:` requires.

**Do NOT** resolve the pin via `git/ref/tags/<tag>`:

```bash
# ❌ WRONG — for annotated tags this returns the tag OBJECT sha, not a commit
gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq .object.sha
```

For a lightweight tag this happens to return a commit SHA, but for an annotated tag it returns the SHA of the
tag object itself (`.object.type == "tag"`). That SHA is not a commit, so it must not be used as a `uses:` pin
— it reads as a valid 40-hex pin in review but does not identify the commit GitHub Actions pinning requires.

Keep the source tag as a trailing comment so the pin stays auditable:

```yaml
uses: owner/repo@<commit-sha> # v4
```

Bump actions to current majors while you are re-pinning — a pin freezes the version, so a stale pin stays
stale until someone touches it. `skills/standardize-tooling/references/publishing.md` is this standard's
consumer: it handles the workflow-authoring path and defers here for the pin mechanics.

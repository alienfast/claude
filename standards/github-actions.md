# GitHub Actions Standards

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

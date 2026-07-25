# Version-Aware Planning

Capability claims are version claims. Stating that a tool can or cannot do something, without having
checked which version the project runs, produces advice that is confidently wrong — the failure mode
that costs the most, because it looks authoritative.

## Detect versions before claiming anything

Read the actual versions first: dependency manifests (`package.json`, `Cargo.toml`, `pyproject.toml`),
the lockfile for what is really resolved, version-bearing config (`biome.json`'s `$schema`), and the
runtime pin (`.nvmrc`, `pyproject.toml`).

Never make a definitive statement about what is or isn't possible without that check — and this cuts
hardest in the negative direction. "Biome doesn't support config inheritance" is a claim that needs
version-specific documentation behind it, not a recollection.

## Research against the detected version

- Put the version in the query: "biome v2 configuration inheritance", not "biome configuration".
- Prefer versioned official docs over generic guides; check releases and recent issues for
  version-specific behavior.
- Cross-reference two authoritative sources before a definitive answer, and confirm the docs you
  found match the version you detected.

## Version-sensitive by default

Config schemas (Biome, ESLint, Prettier), build tooling (Vite, Webpack, Rollup), TypeScript compiler
options, framework APIs, and CLI flags all move between majors. Treat any claim about them as
requiring a version check.

Deprecations are the same problem seen from the other side — use the detected version to identify
what is actually deprecated, and see [Deprecation Standards](deprecation-handling.md).

## Re-check when reality disagrees

Configuration not behaving as documented, a CLI flag failing, docs conflicting with observed
behavior, or the user contradicting earlier advice are all signals that the version assumption was
wrong. Re-research against the real version and correct the guidance rather than defending it.

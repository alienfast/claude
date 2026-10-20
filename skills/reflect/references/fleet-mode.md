# Fleet mode (`/reflect fleet [checkout-path]`)

Read this when `/reflect` is invoked with the `fleet` argument — by `/fleet-retro` after its findings are adjudicated,
once per fleet run, never per issue. A single-session vantage cannot see the classes of problem that recur across a
run; this mode exists for them.

## Step 1 — Gather the run's evidence

The retro has already measured; read its artifacts instead of re-deriving: the fleet-metrics report (per-session,
churn, and flags tables plus the trend row), the window's `tmp/quality-review-verdict-*.md` files,
`tmp/fleet-linear-window.json` (the filings census), and the retro's own findings from the invoking context. Sample
session transcripts only to chase a specific signal — never wholesale.

## Step 2 — Detect cross-run friction

Session mode's Step 1 signals, aggregated across the run — plus the classes only a whole-run view exposes:

- **Filing quality**: duplicate-shaped filings, missing `related`/`blocks` links between sibling filings, mislabeled or
  stranded states, dedup searches run as phrases that structurally returned nothing.
- **Repeated friction**: the same workaround, refusal, or re-derivation appearing in two or more sessions — one
  session's noise is a fleet's pattern.
- **Config drift at fleet scale**: a skill step every session skipped, reinterpreted, or paid the same tax on.

## Step 3 — Verify, triage, apply, file

Exactly session mode's Steps 3–7: same adversarial bar-check and dedup, same triage gates, same apply/file routing
(including the `keeper` path for `~/.claude` targets — `references/filing.md`). The noise guard binds harder here, not
softer — one fleet yields at most one batch, and `No improvements identified.` remains a success.

Invoked with nothing to reflect on → `No improvements identified.` and return; add no latency-heavy work to clean runs.

# Recovering finding text from the transcript

Output reads this when composing the `Findings resolved` field after a compaction, or whenever a finding's wording is
not in context; Step 6 sub-step 1 uses the same recovery when the `### Nice-to-Have` persistence file is missing.

Compose the field from the run's own recorded text, never from recollection. Step 5's count-grounding rule yields
*counts*, and counts are exactly what survives a summarization: an observed one preserved accurate per-cycle counts
(`cycle 1 → 1H/3M`) while destroying every word of the finding text. Reconstructing that text from memory is how a
verdict block acquires a finding that did not happen, and **no consumer validates the field's content**:
`quality-review-write-verdict.sh` checks only that the line starts with a count or `none` (publish-then-warn, never
refuses), `finish-read-verdict.sh` never reads the field, and `fleet-metrics.py` flags a *missing* field but nothing
about a present one's truth. A fabrication reaches `/start` Step 10's verbatim reproduction, both persisted verdict
copies, and `fleet-metrics.py`'s findings-volume and origin aggregation — the signal `/fleet-retro` tunes the fleet on.
(It does not reach `/finish`'s Linear completion comment, which carries `VERDICT`, `CYCLES`, `SUB_ISSUES` and, on a
non-passing verdict only, `Open items:`.)

## Recover the wording

Grep the session transcript for the fix dispatch's own `Findings:` block, which quotes every finding it closes,
anchoring on the template literal — or on the re-review's `Previous findings addressed:`:

```bash
grep -oE 'Task for developer: Fix review findings.{0,14000}' <transcript>
```

- **Use the transcript path printed in the compaction notice**, never a JSONL picked by recency — concurrent fleet
  sessions make a wrong-file match easy.
- **The window must be wide.** In a worktree-isolated run (every `/auto` run is one) the READ-SCOPING and
  WRITE-PLACEMENT blocks sit between the anchor and the finding text, so a 1600-character window expires mid-block and a
  truncated match reads as a hit rather than a miss. Widening is safe: grep is line-oriented and `.` excludes newline,
  so the window stops at the record boundary regardless.
- **Do not bound it with `[^"]`** — finding text quotes phrases, and the escaped `\"` truncates the match mid-finding.
- **Do not anchor on a numbered finding tag** (`HIGH-1`, `MEDIUM-2`): nothing mandates the numbering — the template is
  `- [Finding 1]: …` — and a lane that wrote unnumbered `**HIGH — …**` headers returns zero hits, a partial recovery
  indistinguishable from a complete one.
- **Do not grep a severity word**: the mixed-case alternation matches this skill's own text and
  `agents/quality-reviewer.md`, both quoted into the transcript when the skill loads, and a bare `M[0-9]` matches base64 inside encrypted thinking
  blocks. The anchor above also matches this skill's own template prose — those copies are the ones with no
  READ-SCOPING block after them.
- **A fix agent's own summary tally is not a census.** Count the finding headers in the dispatch rather than reading
  the report's total — a report has claimed "all 7" against a dispatch carrying 8, having in fact fixed all 8.
- Where a finding genuinely cannot be recovered, say so in the field rather than inventing a line for it.

## `origin` is a factual claim too

The intuitive answer is often wrong: a defect in text the implementation wrote reads as `impl` until you check whether
the issue's own description supplied it. `linear-cli issues get <ISSUE-ID> -o json` settles it in one fetch — a
description that itself named the wrong channel makes the finding `spec`, since no plan composed from it could have
avoided it.

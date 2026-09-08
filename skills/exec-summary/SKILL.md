---
name: exec-summary
description: Compose a Slack-shareable executive summary of a change — problem first, then the fix, concise per item and complete per shipped issue (a hotfix or release bundle gets one ID-tagged line per customer-visible issue) — and put it straight on the clipboard as rich text, ready to paste into Slack. Sources from the current session by default, or a named issue/PR. Use when the user says 'exec summary', 'summary for <person>', 'summary I can share', or invokes /exec-summary.
---

# Executive Summary

Produce a short, shareable summary of a shipped change for a non-technical audience, delivered ready to paste into Slack. The reader is busy: the summary's only job is to introduce the problem and the change. Anything else costs readers. The one thing concision never buys is coverage — a business reader's question about a hotfix or release bundle is "did the issue we reported ship?", and a summary that folded that issue into "and other fixes" answers nothing. Words per item are cut; items are not.

## Arguments

- Optional: an issue ID (`BF-1716`), a PR number, or a topic phrase. Default source is **the current session** — the work just shipped or discussed. A PR number makes the PR the source: the census below over that PR decides what appears, not what the session happened to discuss — a session that touched one of a bundle's six issues does not get to summarize one.
- Optional: an audience name ("for Eric") — has no effect on content, only confirms the register: plain business language.

## Census before composing

A summary written from memory names what the session discussed and nothing else — measured on three bundled hotfix PRs that shipped 2, 5, and 6 issues, the shared text named zero. Enumerate first, from surfaces that cannot forget, then sort:

```bash
gh pr view <n> --json body,headRefName,commits --jq '.body, .headRefName, (.commits[] | .messageHeadline, .messageBody)' | grep -o -i -E '<KEY>-[0-9]+' | tr 'a-z' 'A-Z' | sort -u
```

`<KEY>` is the team's Linear key (`$LINEAR_TEAM` where the project exports it). The scan over-collects by design — commit bodies cite the follow-ups `/quality-review` filed and the siblings a fix supersedes (21 IDs on a PR that shipped 6), and the commit list itself over-reports on a long-lived branch with duplicated history (a hotfix bundle's list carried two prior releases' version bumps and an issue merged to `main` five days earlier) — so every ID is a candidate, never a conclusion. Sort each into one of three buckets:

- **Shipped, customer-visible** — passes both tests below, and a user, a customer, or the support team can see the difference. Gets a Solution bullet.
- **Shipped, internal** — passes both tests, but nobody outside engineering can tell (collation, alert routing, test coverage, refactors). Goes on the trailing internal line.
- **Referenced only** — fails either test: a follow-up, a superseded issue, a "see also", an issue whose content is already on the base, or one Linear marks `Duplicate` or `Canceled` (credit its work to the issue that absorbed it). Appears nowhere: tracked work stays in the tracker.

"Shipped" is two tests, and a commit subject or branch name satisfies neither on its own:

1. **In the diff against the base.** `git diff origin/<base>...HEAD` carries the change — the same bar pr-update's §4 applies to every "fixes" claim. An ID whose commits sit in the PR's history but whose content already reached the base through another PR nets to zero here and is referenced-only (measured: three such issues on one hotfix bundle, all `Done` in Linear).
2. **Goes live on merge.** A file that mirrors an externally managed system — a Descope snapshot, a vendor-console export, any config that reaches production through a tool or a console rather than the deploy — changes nothing when merged. A production mirror changed by export records a fix that was live *before* the PR; a dev- or staging-only change ships on a later promote. Neither is release content: leave it out, or state it as already live. Measured on a hotfix bundle: three of eleven roster bullets were Descope snapshot changes, and two of their commit bodies said "fixed in the console; this is its export".

A customer-visible change that rode along without an issue (a copy tweak, a screen reorder) is subject to both tests and, passing them, still gets its bullet. Every shipped ID lands in exactly one place; a shipped ID in neither is a defect, never a concision win.

## Delivery: rich-text clipboard, not chat

Chat cannot be the copy surface: the panel renders GitHub markdown, and copying it yields raw source. Nor is plain Slack-mrkdwn text enough: **Slack's default composer does not interpret markup syntax on paste** — `*bold*` and backticks arrive literally (measured; the raw-markup composer is an off-by-default preference). What the default composer DOES convert is a **rich-text paste**, exactly as when pasting from a webpage. So:

1. Compose the payload twice: a small **HTML fragment** (rules below) at `tmp/exec-summary-<topic>.html`, and a **markup-free plain-text fallback** at `tmp/exec-summary-<topic>.txt` — same content, quotation marks in place of `<code>`, no asterisks or other markup (an app that takes the text flavor must never show syntax characters). Repo-root `tmp/`, or the scratchpad when outside a repo.
2. Put BOTH on the clipboard with the bundled helper (macOS):

   ```bash
   osascript -l JavaScript ~/.claude/skills/exec-summary/set-clipboard-html.js tmp/exec-summary-<topic>.html tmp/exec-summary-<topic>.txt
   ```

   Verify with `osascript -e 'clipboard info'` — it must list `«class HTML»` AND `«class utf8»`. Both flavors are load-bearing: the AppleScript `«data HTML…»` one-liner sets HTML alone, and a clipboard with no plain-text type pastes as nothing in Slack (measured). `pbcopy` alone is the inverse failure — text only, so Slack renders markup characters literally (also measured; the default composer does not interpret markup syntax on paste).
3. Close with one line — **"On your clipboard — paste it wherever you like."** — and nothing else. Do NOT display the summary in chat: any rendering of it invites copying raw source, which pastes literally, and the sender previews it by pasting. Don't name Slack or any destination.

## Payload rules (HTML fragment)

1. **`<b>` for bold, `<code>` for strings** — Slack's rich paste converts both. One `<p>` per paragraph. No headings (`<h*>` — Slack has none), no `<u>` (Slack has no underline).
2. **Title**: `<b>` bold, then `<br>` and a rule line of exactly 25 `━`. The fixed-width rule is the underline — Slack cannot render a real one, and a title-length rule wraps in narrow panels.
3. **`<code>` for emphasis on specific strings** — user-visible messages, button labels, product terms. Never quotation marks for these; they don't stand out in Slack.
4. **Problem first, then the fix — two labeled blocks.** `<b>Problem:</b>` opens the body; `<b>Solution:</b>` gets an extra blank line above it, produced by a `<br>` at the START of the Solution paragraph (`<p><br><b>Solution:</b> …</p>`). A separate `&nbsp;`-only paragraph does NOT work — Slack's paste converter drops it entirely (measured); the in-paragraph `<br>` survives.
5. **On a multi-issue change the Solution block IS the roster.** A hotfix or release bundle gets one `•` bullet per shipped customer-visible issue — the issue ID first, a colon, then one sentence of what the customer or support can now see — complete over the census, customer-facing before support-facing. A customer-visible change with no issue gets a bullet without an ID. Shipped internal-only issues collapse into one closing paragraph with bare IDs: `Also in this release, with no customer-visible change: BF-1703, BF-1698.` A single-issue change keeps a prose Solution.
6. **Concise per item, complete per issue.** People stop reading long summaries; they can always ask questions. Concision cuts *within* a bullet — the mechanism, the adjective, the second example — never the bullet: a shipped customer-visible issue is never what gets dropped to save space. When cutting, drop detail — never compress into fragments or jargon.
7. **Generous whitespace.** Paragraphs of 1–2 sentences, one `<p>` per block, `•` bullets as their own `<p>` paragraphs (literal `•` characters, not `<ul>` — list markup pastes with Slack's own tight list spacing and defeats the airiness).
8. **No deferments, follow-ups, known rough edges, review mechanics, or process detail.** Tracked work stays in the tracker — that is *future* work. Issues that shipped in this change are the content, not process detail.
9. **No ops or rollout lines.** Deploy status, environment names — operations detail, not business outcome.
10. **Business language.** No file paths, no code identifiers. Issue IDs are the one identifier that stays: they are the business's handle for "did our customer's issue ship?", and a summary without them cannot answer it. Bare ID, first on its bullet, a colon after it — never a close verb before it (`Fixed BF-1763`): the same text pasted into a PR body is a surface Linear scans, and the verb moves the issue on merge ([standards/git.md](../../standards/git.md) § Linear auto-close keywords). A concrete number (one user, five codes, 16 minutes) beats an adjective.
11. **Verbatim user-visible text earns its space.** A before/after of what users actually see is the most convincing evidence a copy change can offer — show the real strings in backticks.

## Skeleton (payload file contents)

Single-issue change:

```html
<p><b><Title — outcome, not mechanism></b><br>━━━━━━━━━━━━━━━━━━━━━━━━━</p>
<p><b>Problem:</b> <what users hit, why it matters now. Concrete numbers where real.></p>
<p><br><b>Solution:</b> <what changed, in outcome terms:></p>
<p>• <verbatim new string in <code>…</code>></p>
<p>• <verbatim new string in <code>…</code>></p>
<p><closing sentence if one is genuinely needed></p>
```

Multi-issue change (hotfix or release bundle) — the Solution is the roster, complete over the census:

```html
<p><b><Title — the headline outcome></b><br>━━━━━━━━━━━━━━━━━━━━━━━━━</p>
<p><b>Problem:</b> <the headline problem, 1–2 sentences. The roster carries the rest.></p>
<p><br><b>Solution:</b></p>
<p>• BF-1763: <one sentence — what the customer or support can now see></p>
<p>• BF-1716: <one sentence — the verbatim new string in <code>…</code> where the change is the copy></p>
<p>• <a customer-visible change that rode along without an issue></p>
<p>Also in this release, with no customer-visible change: BF-1703, BF-1698.</p>
```

## Accuracy

Every claim must be true of what actually shipped — same bar as pr-update's Executive Summary: over-claiming in the most-shared text is the worst case. A roster bullet claims that issue shipped in this change, so a bullet for a referenced-only ID (a follow-up the commit body cites) is the same over-claim as any other — the census sort is what keeps it out. If the change shipped to one environment only, claim nothing rollout-shaped (rule 9 already bars the line either way).

## Relationship to pr-update

`pr-update`'s `## Executive Summary` block is the PR-description variant of this skill: same voice, same problem-first ordering, same concision bar, same census and roster on a multi-issue PR. Its mechanics differ — it stays GitHub markdown (`**bold**`, `## Executive Summary` heading, trailing PR link, no clipboard step) because it lives in a PR body, not a Slack message — and the PR body is the surface Linear scans, which is why the ID-first, no-close-verb form is the rule in both.

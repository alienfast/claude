---
name: exec-summary
description: Compose a Slack-shareable executive summary of a change for business readers — a single issue is problem first, then the fix; a hotfix or release bundle is a headline, a roll-up by theme, and the per-issue ID list last as a reference — concise per item and complete per shipped issue, put straight on the clipboard as rich text, ready to paste into Slack. Sources from the current session by default, or a named issue/PR. Use when the user says 'exec summary', 'summary for <person>', 'summary I can share', or invokes /exec-summary.
---

# Executive Summary

Produce a short, shareable summary of a shipped change for a non-technical audience, delivered ready to paste into Slack. The reader is busy: the summary's only job is to say what changed for them and why it matters. Anything else costs readers. A single-issue change is one problem and one fix. A hotfix or release bundle is many problems, so it reads as a headline and a roll-up by theme — the story a business reader actually follows — with the per-issue list last, as a reference. The one thing concision never buys is coverage — a business reader's second question about a bundle is "did the issue we reported ship?", and a summary that folded that issue into "and other fixes" answers nothing. Words per item are cut; items are not. Measured 2026-09-28 on a 54-issue release PR: one Problem paragraph over a 43-line ID-first roster, and the keeper's verdict was that no business user would read it — the problem read as one when many were solved, nothing rolled the list up, and the list belonged last, like a bibliography.

## Arguments

- Optional: an issue ID (`BF-1716`), a PR number, or a topic phrase. Default source is **the current session** — the work just shipped or discussed. A PR number makes the PR the source: the census below over that PR decides what appears, not what the session happened to discuss — a session that touched one of a bundle's six issues does not get to summarize one.
- Optional: an audience name ("for Eric") — has no effect on content, only confirms the register: plain business language.

## Census before composing

A summary written from memory names what the session discussed and nothing else — measured on three bundled hotfix PRs that shipped 2, 5, and 6 issues, the shared text named zero. Enumerate first, from surfaces that cannot forget, then sort:

```bash
gh pr view <n> --json body,headRefName,commits --jq '.body, .headRefName, (.commits[] | .messageHeadline, .messageBody)' | grep -o -i -E '<KEY>-[0-9]+' | tr 'a-z' 'A-Z' | sort -u
```

`<KEY>` is the team's Linear key (`$LINEAR_TEAM` where the project exports it). The scan over-collects by design — commit bodies cite the follow-ups `/quality-review` filed and the siblings a fix supersedes (21 IDs on a PR that shipped 6), and the commit list itself over-reports on a long-lived branch with duplicated history (a hotfix bundle's list carried two prior releases' version bumps and an issue merged to `main` five days earlier) — so every ID is a candidate, never a conclusion. Sort each into one of three buckets:

- **Shipped, customer-visible** — passes both tests below, and a user, a customer, or the support team can see the difference. Its outcome is told in a theme bullet (the Solution, on a single-issue change) and its ID gets a line in the reference list.
- **Shipped, internal** — passes both tests, but nobody outside engineering can tell (collation, alert routing, test coverage, refactors). Goes on the trailing internal line.
- **Referenced only** — fails either test: a follow-up, a superseded issue, a "see also", an issue whose content is already on the base, or one Linear marks `Duplicate` or `Canceled` (credit its work to the issue that absorbed it). Appears nowhere: tracked work stays in the tracker.

"Shipped" is two tests, and a commit subject or branch name satisfies neither on its own:

1. **In the diff against the base.** `git diff origin/<base>...HEAD` carries the change — the same bar pr-update's §4 applies to every "fixes" claim. An ID whose commits sit in the PR's history but whose content already reached the base through another PR nets to zero here and is referenced-only (measured: three such issues on one hotfix bundle, all `Done` in Linear).
2. **Goes live on merge.** A file that mirrors an externally managed system — a Descope snapshot, a vendor-console export, any config that reaches production through a tool or a console rather than the deploy — changes nothing when merged. A production mirror changed by export records a fix that was live *before* the PR; a dev- or staging-only change ships on a later promote. Neither is release content: leave it out, or state it as already live. Measured on a hotfix bundle: three of eleven roster bullets were Descope snapshot changes, and two of their commit bodies said "fixed in the console; this is its export".

A customer-visible change that rode along without an issue (a copy tweak, a screen reorder) is subject to both tests and, passing them, still gets a theme bullet — it has no ID, so no reference line. Every shipped ID lands in exactly one place; a shipped ID in neither is a defect, never a concision win.

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
4. **Single-issue change: problem first, then the fix — two labeled blocks.** `<b>Problem:</b>` opens the body; `<b>Solution:</b>` gets an extra blank line above it, produced by a `<br>` at the START of the Solution paragraph (`<p><br><b>Solution:</b> …</p>`). A separate `&nbsp;`-only paragraph does NOT work — Slack's paste converter drops it entirely (measured); the in-paragraph `<br>` survives.
5. **Multi-issue change: a headline, a roll-up by theme, then the issue list last.** A hotfix or release bundle has many problems, so no single Problem block: open with a headline paragraph (1–3 sentences, what this release is about in the business's words), then 3–6 themes. Each theme is a `<b>` bold name as its own paragraph — named for what the reader does or gets (`Managing an organization`, `Support and admin tools`), never a component or subsystem — then one sentence of the problem that theme solves, then 2–6 `•` outcome bullets. No issue IDs in the themes: the reader is following the story, and the ID is noise there. Close with `<b>Issues in this release</b>` as its own paragraph and one `•` line per shipped customer-visible issue — the ID first, a colon, then a short label that makes the issue recognizable — sorted by ID: a lookup, not a second narrative. Shipped internal-only issues collapse into one closing paragraph with bare IDs: `Also in this release, with no customer-visible change: BF-1698, BF-1703.` Theme names and the reference heading get the extra blank line (`<p><br><b>…</b></p>`), the same way Solution does.
6. **Concise per item, complete per issue.** People stop reading long summaries; they can always ask questions. Concision cuts *within* a bullet — the mechanism, the adjective, the second example — never the bullet, and never a reference line: a shipped customer-visible issue is never what gets dropped to save space. When cutting, drop detail — never compress into fragments or jargon.
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

Multi-issue change (hotfix or release bundle) — the themes tell the story, the issue list is the reference, complete over the census:

```html
<p><b><Title — the headline outcome></b><br>━━━━━━━━━━━━━━━━━━━━━━━━━</p>
<p><headline: 1–3 sentences — what this release is about, in the business's words></p>
<p><br><b><Theme — what the reader does or gets></b></p>
<p><one sentence: the problem this theme solves></p>
<p>• <outcome — what is better now; the verbatim new string in <code>…</code> where the change is the copy></p>
<p>• <outcome — a customer-visible change that rode along without an issue goes here too></p>
<p><br><b><Next theme></b></p>
<p><one sentence: its problem></p>
<p>• <outcome></p>
<p><br><b>Issues in this release</b></p>
<p>• BF-1716: <short label — enough to recognize the issue, not to explain it></p>
<p>• BF-1763: <short label></p>
<p>Also in this release, with no customer-visible change: BF-1698, BF-1703.</p>
```

## Accuracy

Every claim must be true of what actually shipped — same bar as pr-update's Executive Summary: over-claiming in the most-shared text is the worst case. A roster bullet claims that issue shipped in this change, so a bullet for a referenced-only ID (a follow-up the commit body cites) is the same over-claim as any other — the census sort is what keeps it out. If the change shipped to one environment only, claim nothing rollout-shaped (rule 9 already bars the line either way).

## Relationship to pr-update

`pr-update`'s `## Executive Summary` block is the PR-description variant of this skill: same voice, same shapes (problem then fix on a single issue; headline, themes, then the issue list on a bundle), same concision bar, same census. Its mechanics differ — it stays GitHub markdown (`**bold**`, `## Executive Summary` heading, `###` for the theme and `Issues in this release` headings, trailing PR link, no clipboard step) because it lives in a PR body, not a Slack message — and the PR body is the surface Linear scans, which is why the ID-first, no-close-verb form is the rule in both.

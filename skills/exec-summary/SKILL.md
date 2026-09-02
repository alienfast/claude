---
name: exec-summary
description: Compose a Slack-shareable executive summary of a change — problem first, then the fix, as concise as possible — and put it straight on the clipboard as rich text, ready to paste into Slack. Sources from the current session by default, or a named issue/PR. Use when the user says 'exec summary', 'summary for <person>', 'summary I can share', or invokes /exec-summary.
---

# Executive Summary

Produce a short, shareable summary of a shipped change for a non-technical audience, delivered ready to paste into Slack. The reader is busy: the summary's only job is to introduce the problem and the change. Anything else costs readers.

## Arguments

- Optional: an issue ID (`BF-1716`), a PR number, or a topic phrase. Default source is **the current session** — the work just shipped or discussed.
- Optional: an audience name ("for Eric") — has no effect on content, only confirms the register: plain business language.

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
5. **As concise as possible.** People stop reading long summaries; they can always ask questions. When cutting, drop detail — never compress into fragments or jargon.
6. **Generous whitespace.** Paragraphs of 1–2 sentences, one `<p>` per block, `•` bullets as their own `<p>` paragraphs (literal `•` characters, not `<ul>` — list markup pastes with Slack's own tight list spacing and defeats the airiness).
7. **No deferments, follow-ups, known rough edges, review mechanics, or process detail.** Tracked work stays in the tracker.
8. **No ops or rollout lines.** Deploy status, environment names — operations detail, not business outcome.
9. **Business language.** No file paths, no code identifiers. A concrete number (one user, five codes, 16 minutes) beats an adjective.
10. **Verbatim user-visible text earns its space.** A before/after of what users actually see is the most convincing evidence a copy change can offer — show the real strings in backticks.

## Skeleton (payload file contents)

```html
<p><b><Title — outcome, not mechanism></b><br>━━━━━━━━━━━━━━━━━━━━━━━━━</p>
<p><b>Problem:</b> <what users hit, why it matters now. Concrete numbers where real.></p>
<p><br><b>Solution:</b> <what changed, in outcome terms:></p>
<p>• <verbatim new string in <code>…</code>></p>
<p>• <verbatim new string in <code>…</code>></p>
<p><closing sentence if one is genuinely needed></p>
```

## Accuracy

Every claim must be true of what actually shipped — same bar as pr-update's Executive Summary: over-claiming in the most-shared text is the worst case. If the change shipped to one environment only, claim nothing rollout-shaped (rule 8 already bars the line either way).

## Relationship to pr-update

`pr-update`'s `## Executive Summary` block is the PR-description variant of this skill: same voice, same problem-first ordering, same concision bar. Its mechanics differ — it stays GitHub markdown (`**bold**`, `## Executive Summary` heading, trailing PR link, no clipboard step) because it lives in a PR body, not a Slack message.

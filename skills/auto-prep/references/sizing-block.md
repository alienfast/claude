# The `sizing` block of `tmp/fleet-recommendation-<slug>.json`

The block records what the recommendation assumed so `/fleet-retro` can compare realized burn against it; a projection
that missed is then visible rather than silently repeated. It is not a sizing input — the count comes from lanes and the
cap `scripts/fleet-cap.sh` reads (`/fleet-launch` § The count — 3 per account with room).

Take `rate` and `peak_5h_observed` each as the MAX of its own column over the recent fleets in
`tmp/fleet-metrics-history.jsonl`, never the latest retro alone and never both from one row: a peak is a floor on the
account's capacity only when the fleet was actually working, and a starved or throttled run would otherwise reset it; and
the row with the largest 5h total is the widest fleet, not the hottest session (2026-10-30: the rate read off the
5-session row projected 180k per session-hour against a realized 275k, 1.52x under, while the 3-session row carried 276k).

```bash
jq -s 'map(select(.peak_5h_output_tokens)) | sort_by(.fleet_start) | .[-6:]
       | {rate: (map(.output_tokens_per_session_hour_at_peak // empty) | max), peak5h: (map(.peak_5h_output_tokens) | max)}' tmp/fleet-metrics-history.jsonl
```

- A history with neither field falls back to the latest retro's `windows` block
  (`~/.claude/scripts/fleet-metrics.py --json | jq .windows`).
- Use `output_tokens_per_session_hour_at_peak`, never `output_tokens_per_session_hour_all_sessions`: the all-sessions
  mean pools idle and interactive sessions with fleet ones and lands about half the truth.
- Rows also carry `peak_five_hour_pct` and `five_hour_fits_sessions` — the meter's own peak and the retro's Headroom
  verdict. Take the LATEST row's fit, `null` included, state it beside its `sessions` in the report ("the meter fit 4 at
  n=3 last run"; "no fit: the account reports no `five_hour` window"), and persist it as `five_hour_fits_sessions`.
  Never reach back to an older row for a non-null fit: an account that reports no `five_hour` window (Claude Ultra,
  since 2026-10-31) makes every new row null, and the fallback would pin a pre-change figure into every recommendation
  (the 2026-10-30 files carried 27 from the 2026-10-25 fleet; `skills/fleet-retro/references/windows.md`).

The report shows the projected burn per 5h window (`n × 5 × rate`) beside the observed peak so the margin is visible.

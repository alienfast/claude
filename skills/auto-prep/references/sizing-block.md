# The `sizing` block of `tmp/fleet-recommendation.json`

The block records what the recommendation assumed so `/fleet-retro` can compare realized burn against it; a projection
that missed is then visible rather than silently repeated. It is not a sizing input — the count comes from lanes and the
cap `scripts/fleet-cap.sh` reads (`/fleet-launch` § The count — 3 per account with room).

Take `rate` and `peak_5h_observed` as the MAX over the recent fleets in `tmp/fleet-metrics-history.jsonl`, never the
latest retro alone: a peak is a floor on the account's capacity only when the fleet was actually working, and a starved or
throttled run would otherwise reset it.

```bash
jq -s 'map(select(.peak_5h_output_tokens)) | sort_by(.fleet_start) | .[-6:]
       | max_by(.peak_5h_output_tokens)
       | {rate: .output_tokens_per_session_hour_at_peak, peak5h: .peak_5h_output_tokens}' tmp/fleet-metrics-history.jsonl
```

- A history with neither field falls back to the latest retro's `windows` block
  (`~/.claude/scripts/fleet-metrics.py --json | jq .windows`).
- Use `output_tokens_per_session_hour_at_peak`, never `output_tokens_per_session_hour_all_sessions`: the all-sessions
  mean pools idle and interactive sessions with fleet ones and lands about half the truth.
- Rows also carry `peak_five_hour_pct` and `five_hour_fits_sessions` — the meter's own peak and the retro's Headroom
  verdict. Take the latest row with a non-null fit, state it beside its `sessions` in the report ("the meter fit 4 at
  n=3 last run"), and persist it as `five_hour_fits_sessions` (`null` when none exists).

The report shows the projected burn per 5h window (`n × 5 × rate`) beside the observed peak so the margin is visible.

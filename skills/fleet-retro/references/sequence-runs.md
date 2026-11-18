# A `/fleet-solo` or `/fleet-sequence` run

Read from `/fleet-retro` Step 1 when the run to retro is a drain or a sequence: the operator names one, or a
`tmp/fleet-sequence-<slug>.json` marker was written (its mtime) since the last history row's `recorded_at`.

## Scope it from the runner's marker

The marker is `tmp/fleet-sequence-<slug>.json` (`solo` for a drain, else the lowercased first ID of the list), and
`.issues[<ID>].session` is the session set: `jq -r '[.issues[].session // empty] | join(",")' <marker>`. Measure it with
`--sessions <those keys> --no-record`. Everything that reads a history row reads it as a parallel fleet (the trend
tail, `/fleet-forecast`'s hours-per-issue calibration, `/auto-prep`'s sizing block), and a one-at-a-time run's row would
enter all three with its session count, one per issue, as `n`. Skipping the row strands nothing: no `fleet-deadline`
marker names these ledgers, so the next launch clears them once their sessions are dead whether or not a retro measured
them (`skills/fleet-launch/SKILL.md` § Ledger expiry).

A run retro'd after a launch has therefore usually lost its ledgers, and a `then-fleet` drain is always retro'd after
one. The analyzer still measures the named sessions from their transcripts and flags each `ran without a surviving
ledger`; for these sessions that flag is the expiry, not a fault (2026-11-17: neither ledger of a two-issue drain was
left the morning after the fleet that launched 12 seconds behind it).

## Reconcile the runner against its sessions

The analyzer reads neither the runner's marker nor its log, so a runner fault shows only in this comparison:

- Each `.issues[<ID>].outcome` against that session's ledger (`tmp/auto-state-<session>.json`) and git. An outcome other
  than `shipped` whose ledger says shipped is a runner fault, and a drain then dispatched its next issue beside a live
  session (2026-11-11: an issue recorded `unknown` with `ended_epoch == started_epoch` merged six hours later). With the
  ledger gone, git answers alone: whether the issue's commits reached the base.
- Each `started_epoch` against the write time of every earlier session's ledger. A ledger written after a later issue
  started means the two ran at once, which breaks the one-at-a-time guarantee a `solo` issue depends on. Use the
  ledger's write, not the transcript's last timestamped record: the runner moves on at the ledger and the merge, and a
  session's trailing records land minutes after it. With the ledger gone, use the earlier issue's landing commit
  (`.issues[<ID>].landed_sha`, or `git log --grep=<ID>` on the base when the runner recorded none): a later
  `started_epoch` before that commit's committer date is the same overlap (2026-11-17: a clean hand-off read 81 seconds
  clear this way).
- Every `WARN` line in `tmp/fleet-sequence-<slug>.log` against git before reporting it (2026-11-11: three `none of the
  commits … mention <ID>` warnings sat on landings whose newest commit was `Merge <ID>`).

Both 2026-11-11 faults were the runner's and are fixed; the comparison is what found them.

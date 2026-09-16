#!/usr/bin/env bash
# Link a Sentry error issue to a Linear issue through Sentry's "External Links" (the UI's "+ Link issue"), so the
# mapping shows in the issue sidebar and Linear gets a `sentry` attachment on its side — an Activity comment does
# neither. Linear is an integration-platform Sentry app, so the link is the same `external-issue-actions` POST the
# UI's form submits: resolve the org's `linear` installation, ask the app's search hook for the Linear issue's uuid
# (exact identifier match on the returned label), POST the link, and confirm it on the issue's `external-issues`
# listing. A repeat returns the existing record (measured 2026-09-16), so re-running a sweep cannot stack links.
#
# Performance issues (`performance_*` issue types) are refused up front: the action endpoint answers
# `Could not find the corresponding issue for the given groupId` and their `external-issues` listing 403s
# (measured 2026-09-16), so their back-link lives in the Linear issue's description alone.
#
# Exit: 0 linked (or already linked); 2 usage/prereq; 3 performance issue; 4 no Linear app installed for the org;
# 5 Linear issue not found by the app's search; 6 the link POST returned no record; 7 read-back did not show it.

set -uo pipefail

usage() { echo "usage: link-linear.sh <org/project> <SENTRY-SHORT-ID> <LINEAR-ID>   e.g. link-linear.sh alienfast/basefund BASEFUND-1F0 BF-1939" >&2; exit 2; }
[ $# -eq 3 ] || usage
target="$1"; sid="$2"; lid="$3"
org="${target%%/*}"; project="${target#*/}"
[ -n "$org" ] && [ -n "$project" ] && [ "$org" != "$target" ] || usage
command -v jq >/dev/null 2>&1 || { echo "link-linear: jq not installed" >&2; exit 2; }
command -v sentry >/dev/null 2>&1 || { echo "link-linear: sentry CLI not installed" >&2; exit 2; }

view="$(sentry issue view "$sid" --json --fresh --fields id,issueType 2>/dev/null)" || { echo "link-linear: cannot read $sid" >&2; exit 2; }
gid="$(printf '%s' "$view" | jq -r '.id // empty')"
itype="$(printf '%s' "$view" | jq -r '.issueType // empty')"
[ -n "$gid" ] || { echo "link-linear: $sid resolved no numeric id" >&2; exit 2; }
case "$itype" in
  performance_*) echo "link-linear: $sid is a $itype issue — Sentry refuses external links on performance issues; record the mapping in the Linear description instead" >&2; exit 3 ;;
esac

pid="$(sentry api "projects/$org/$project/" 2>/dev/null | jq -r '.id // empty')"
[ -n "$pid" ] || { echo "link-linear: cannot resolve project id for $target" >&2; exit 2; }

inst="$(sentry api "organizations/$org/sentry-app-installations/" 2>/dev/null | jq -r '[.[]? | select(.app.slug == "linear" and .status == "installed")] | .[0].uuid // empty')"
[ -n "$inst" ] || { echo "link-linear: no installed 'linear' Sentry app on org $org — install Linear's Sentry integration (Settings → Integrations) first" >&2; exit 4; }

luuid="$(sentry api "sentry-app-installations/$inst/external-requests/?uri=/hooks/sentry/issues/search&projectId=$pid&query=$lid" 2>/dev/null \
  | jq -r --arg lid "$lid" '[.choices[]? | select(.[1] | startswith($lid + " "))] | .[0][0] // empty')"
[ -n "$luuid" ] || { echo "link-linear: Linear's search hook returned no issue labelled '$lid …' — check the identifier, and that the Linear app can see that team" >&2; exit 5; }

resp="$(sentry api "sentry-app-installations/$inst/external-issue-actions/" -X POST \
  -d "{\"groupId\":\"$gid\",\"action\":\"link\",\"uri\":\"/hooks/sentry/issues/link\",\"issueId\":\"$luuid\"}" 2>&1)"
eid="$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null)"
[ -n "$eid" ] || { echo "link-linear: link POST returned no record for $sid ↔ $lid: $resp" >&2; exit 6; }

listed="$(sentry api "issues/$gid/external-issues/" 2>/dev/null | jq -r --arg eid "$eid" '[.[]? | select(.id == $eid)] | .[0].displayName // empty')"
[ -n "$listed" ] || { echo "link-linear: POST answered record $eid but the external-issues listing for $sid does not show it" >&2; exit 7; }

echo "linked: $sid ↔ $lid (external issue $eid, shown as $listed)"

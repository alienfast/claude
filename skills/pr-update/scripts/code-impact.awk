# Categorize `git diff --numstat -M -l0` output into purpose buckets for the PR Code Impact table.
#
# Usage:  git diff --numstat -M -l0 "$BASE"...HEAD | awk -f code-impact.awk
#
# This program is the single source of truth — both SKILL.md (inline path) and analyze-pr.sh run it via
# `awk -f`, never inline. Keeping it in a file is deliberate: passed through the shell, awk's $1/$2/$3
# would be expanded away by Bash and the program would silently mis-count. Edit categories here only.
#
# Buckets are first-match-wins, ordered most-specific to least. Lock files are dropped entirely so churn
# in generated lockfiles never skews the totals.
{
  if ($3 ~ /lock\.yaml$|lock\.json$|\.lock$/) next
  added += $1; removed += $2; file = $3
  if (file ~ /\.stories\./)                             { sa += $1; sr += $2 }   # Storybook stories
  else if (file ~ /mock|Mock/)                          { ma += $1; mr += $2 }   # Test mocks
  else if (file ~ /generated|packages\/graphql\//)      { ga += $1; gr += $2 }   # Generated code (codegen)
  else if (file ~ /packages\/e2e\//)                    { ea += $1; er += $2 }   # E2E package (Playwright)
  else if (file ~ /\.test\.[jt]sx?$|_spec\.rb$/)        { ua += $1; ur += $2 }   # Unit tests (Vitest + RSpec)
  else if (file ~ /ops\//)                              { ia += $1; ir += $2 }   # Infrastructure / operations
  else if (file ~ /\.(yml|yaml|json|css|scss|svg|md)$/) { la += $1; lr += $2 }   # Config, locales, styles, assets
  else                                                  { ca += $1; cr += $2 }   # App code (everything else)
}
END {
  printf "%-20s %8s %8s %8s\n", "Category", "Added", "Removed", "Net"
  printf "%-20s %8d %8d %8d\n", "App code",      ca, cr, ca-cr
  printf "%-20s %8d %8d %8d\n", "Unit tests",    ua, ur, ua-ur
  printf "%-20s %8d %8d %8d\n", "E2E tests",     ea, er, ea-er
  printf "%-20s %8d %8d %8d\n", "Stories",       sa, sr, sa-sr
  printf "%-20s %8d %8d %8d\n", "Mocks",         ma, mr, ma-mr
  printf "%-20s %8d %8d %8d\n", "Generated",     ga, gr, ga-gr
  printf "%-20s %8d %8d %8d\n", "Ops/Infra",     ia, ir, ia-ir
  printf "%-20s %8d %8d %8d\n", "Config/Assets", la, lr, la-lr
  printf "%-20s %8d %8d %8d\n", "TOTAL",         added, removed, added-removed
}

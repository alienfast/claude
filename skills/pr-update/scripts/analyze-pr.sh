#!/bin/bash
# PR Analysis Helper Script
# Quick analysis of PR scope and changes

set -euo pipefail

# Base branch: explicit arg ($1) wins; otherwise resolved from the PR / repo default below.
BASE="${1:-}"

echo "========================================"
echo "PR SCOPE ANALYSIS"
echo "========================================"
echo ""

# Get current branch
BRANCH=$(git branch --show-current)
echo "📍 Current Branch: $BRANCH"
echo ""

# Get PR info if it exists
if command -v gh &> /dev/null; then
  # Fetch PR with state information for validation
  pr_info=$(gh pr view --json number,title,state,mergedAt,headRefName,baseRefName 2>/dev/null)

  if [[ -n "$pr_info" ]]; then
    pr_state=$(echo "$pr_info" | jq -r '.state // "UNKNOWN"')
    pr_merged_at=$(echo "$pr_info" | jq -r '.mergedAt // "null"')
    pr_number=$(echo "$pr_info" | jq -r '.number')
    PR_TITLE=$(echo "$pr_info" | jq -r '.title')
    pr_base=$(echo "$pr_info" | jq -r '.baseRefName')
    [[ -z "$BASE" && -n "$pr_base" && "$pr_base" != "null" ]] && BASE="$pr_base"

    # Security Fix #6: Validate pr_state is a known value
    case "$pr_state" in
      OPEN|CLOSED|MERGED|UNKNOWN) ;;
      *)
        echo "WARNING: Unexpected PR state: $pr_state" >&2
        pr_state="UNKNOWN"
        ;;
    esac

    # Security Fix #6: Validate pr_number is a positive integer
    if [[ -z "$pr_number" ]] || [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
      echo "ERROR: Invalid or missing PR number" >&2
      exit 1
    fi

    # Validate PR state before analysis (non-blocking, warning only)
    if [[ "$pr_state" != "OPEN" ]]; then
      echo "⚠️  Warning: PR #$pr_number is $pr_state" >&2

      if [[ "$pr_state" == "MERGED" || "$pr_merged_at" != "null" ]]; then
        echo "⚠️  This PR was merged. Analysis will show historical changes only." >&2
      elif [[ "$pr_state" == "CLOSED" ]]; then
        echo "⚠️  This PR was closed without merging." >&2
      else
        echo "⚠️  PR state is unclear: $pr_state" >&2
      fi

      echo "" >&2
      echo "Continue with analysis? (y/N): " >&2
      read -r response

      if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Analysis cancelled." >&2
        exit 1
      fi
    fi

    echo "🔗 PR #$pr_number: $PR_TITLE"
    echo ""
  else
    echo "ℹ️  No PR found for this branch"
    echo ""
  fi
fi

# Resolve the base branch (mirror SKILL.md §2): explicit arg > PR base > repo default > main.
if [[ -z "$BASE" ]]; then
  BASE="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
fi
BASE="${BASE:-main}"
echo "🎯 Base branch: $BASE"
echo ""

# Commit count
COMMIT_COUNT=$(git log "$BASE"..HEAD --oneline | wc -l | tr -d ' ')
echo "📊 Commits in PR: $COMMIT_COUNT"
echo ""

# Files changed summary
echo "📁 Files Changed Summary:"
git diff "$BASE"...HEAD --stat | tail -1
echo ""

# Major areas of change
echo "🎯 Major Areas Changed:"
git diff "$BASE"...HEAD --name-only | cut -d/ -f1 | sort | uniq -c | sort -rn | head -10
echo ""

# Documentation changes
DOC_CHANGES=$(git diff "$BASE"...HEAD --name-only | grep -E '\.md$|^doc/' || true)
if [ -n "$DOC_CHANGES" ]; then
  echo "📝 Documentation Changes:"
  echo "$DOC_CHANGES" | head -10 | sed 's/^/   /'
  DOC_COUNT=$(echo "$DOC_CHANGES" | wc -l | tr -d ' ')
  if [ "$DOC_COUNT" -gt 10 ]; then
    echo "   ... and $((DOC_COUNT - 10)) more"
  fi
  echo ""
fi

# Infrastructure changes
INFRA_CHANGES=$(git diff "$BASE"...HEAD --name-only | grep -E '^cloud/' || true)
if [ -n "$INFRA_CHANGES" ]; then
  echo "☁️  Infrastructure Changes:"
  echo "$INFRA_CHANGES" | head -10 | sed 's/^/   /'
  INFRA_COUNT=$(echo "$INFRA_CHANGES" | wc -l | tr -d ' ')
  if [ "$INFRA_COUNT" -gt 10 ]; then
    echo "   ... and $((INFRA_COUNT - 10)) more"
  fi
  echo ""
fi

# CI/CD changes
CICD_CHANGES=$(git diff "$BASE"...HEAD --name-only | grep -E '\.yml$|\.yaml$|\.circleci|\.github/workflows' || true)
if [ -n "$CICD_CHANGES" ]; then
  echo "🔄 CI/CD Changes:"
  echo "$CICD_CHANGES" | sed 's/^/   /'
  echo ""
fi

# Package changes
if git diff "$BASE"...HEAD --name-only | grep -q 'package.json'; then
  echo "📦 Dependency Changes Detected"
  echo "   Run: git diff $BASE...HEAD -- package.json"
  echo ""
fi

# Code impact summary
echo "📈 Code Impact Summary:"
git diff --shortstat -M -l0 "$BASE"...HEAD
echo ""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
git diff --numstat -M -l0 "$BASE"...HEAD | awk -f "$SCRIPT_DIR/code-impact.awk"
echo ""

echo "========================================"
echo "Use this data to verify what's actually"
echo "in the final state before documenting!"
echo "========================================"

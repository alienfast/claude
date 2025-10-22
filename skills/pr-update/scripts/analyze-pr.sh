#!/bin/bash
# PR Analysis Helper Script
# Quick analysis of PR scope and changes

set -euo pipefail

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
  if gh pr view --json number,title,url &> /dev/null; then
    PR_NUMBER=$(gh pr view --json number -q .number)
    PR_TITLE=$(gh pr view --json title -q .title)
    PR_URL=$(gh pr view --json url -q .url)
    echo "🔗 PR #$PR_NUMBER: $PR_TITLE"
    echo "   $PR_URL"
    echo ""
  else
    echo "ℹ️  No PR found for this branch"
    echo ""
  fi
fi

# Commit count
COMMIT_COUNT=$(git log main..HEAD --oneline | wc -l | tr -d ' ')
echo "📊 Commits in PR: $COMMIT_COUNT"
echo ""

# Files changed summary
echo "📁 Files Changed Summary:"
git diff main...HEAD --stat | tail -1
echo ""

# Major areas of change
echo "🎯 Major Areas Changed:"
git diff main...HEAD --name-only | cut -d/ -f1 | sort | uniq -c | sort -rn | head -10
echo ""

# Documentation changes
DOC_CHANGES=$(git diff main...HEAD --name-only | grep -E '\.md$|^doc/' || true)
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
INFRA_CHANGES=$(git diff main...HEAD --name-only | grep -E '^cloud/' || true)
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
CICD_CHANGES=$(git diff main...HEAD --name-only | grep -E '\.yml$|\.yaml$|\.circleci|\.github/workflows' || true)
if [ -n "$CICD_CHANGES" ]; then
  echo "🔄 CI/CD Changes:"
  echo "$CICD_CHANGES" | sed 's/^/   /'
  echo ""
fi

# Package changes
if git diff main...HEAD --name-only | grep -q 'package.json'; then
  echo "📦 Dependency Changes Detected"
  echo "   Run: git diff main...HEAD -- package.json"
  echo ""
fi

echo "========================================"
echo "Use this data to verify what's actually"
echo "in the final state before documenting!"
echo "========================================"

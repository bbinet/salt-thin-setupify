#!/bin/bash
set -euo pipefail

# Only run in remote (Claude Code on the web) sessions
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Configure git identity
git config --global user.name "Bruno Binet"
git config --global user.email "bruno.binet@gmail.com"

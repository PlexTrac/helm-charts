#!/usr/bin/env bash
# One-time audit of the full git history before making this repository public.
# Run this locally, review any findings, and add safe commit SHAs to the
# `commits` allowlist in .gitleaks.toml if they are confirmed false positives.
#
# Prerequisites: gitleaks >= 8.x
#   brew install gitleaks          # macOS
#   https://github.com/gitleaks/gitleaks/releases  # Linux/Windows
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if ! command -v gitleaks &>/dev/null; then
  echo "Error: gitleaks not found. Install it first (see script header)." >&2
  exit 1
fi

echo "==> Scanning full git history for secrets..."
echo "    This may take a moment on large repos."
echo ""

gitleaks detect \
  --config .gitleaks.toml \
  --verbose \
  --report-format sarif \
  --report-path gitleaks-history-report.sarif

echo ""
echo "==> Scan complete. No secrets found in git history."
echo "    Review gitleaks-history-report.sarif for details."

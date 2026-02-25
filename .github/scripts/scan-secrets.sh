#!/usr/bin/env bash
set -euo pipefail

if rg --line-number --hidden --glob '!*.md' --glob '!*.tpl' --glob '!values.schema.json' '(?i)(password|secret|token|api[_-]?key)\s*:\s*["\x27]?[A-Za-z0-9/+_=.-]{12,}["\x27]?$' charts docs .github; then
  echo "Potential plaintext secret detected. Use placeholders or external secret references."
  exit 1
fi

echo "No obvious plaintext secrets detected."

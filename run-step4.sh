#!/usr/bin/env bash
# run-step4.sh — run the step 4 exit test (org session buffer + resume).
# Exit 0 = STEP 4 PASSED (a session closed and reopened; history carried).
set -uo pipefail
cd "$(dirname "$0")"

# load API keys from .env if present (never commit .env)
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

ELPA="spike/.elpa"
[ -d "$ELPA" ] || emacs --batch -l spike/install-gptel.el >&2

exec emacs --batch \
  --directory "$ELPA/gptel-20260728.211" \
  --directory . \
  --eval "(setq load-prefer-newer t)" \
  --eval "(setq package-user-dir (expand-file-name \"$ELPA\" default-directory))" \
  --eval "(package-initialize)" \
  -l test-step4.el

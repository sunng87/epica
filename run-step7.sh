#!/usr/bin/env bash
# run-step7.sh — run the step 7 exit test (skills loader).
# Exit 0 = STEP 7 PASSED.
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
  --eval "(setq package-user-dir (expand-file-name \"spike/.elpa\" default-directory))" \
  --eval "(package-initialize)" \
  -l test-step7.el

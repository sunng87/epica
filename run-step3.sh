#!/usr/bin/env bash
# run-step3.sh — run the step 3 exit test (buffer-native tools).
# Exit 0 = STEP 3 PASSED (a multi-step edit task on a live buffer
# succeeded via edit-region, with undo available; tools registered).
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
  -l test-step3.el

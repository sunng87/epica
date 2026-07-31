#!/usr/bin/env bash
# run-step2.sh — run the step 2 exit test (define-epica-tool + the loop).
#
# Exit 0 = STEP 2 PASSED (model called a tool via the epica loop and
# recovered a buffer secret; the call/result/settled hooks all fired).
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

# load-prefer-newer: during dev, source edits must beat a stale .elc
# (byte-compiling epica.el creates epica.elc; without this, require
# silently loads the old .elc and ignores your edits).
exec emacs --batch \
  --directory "$ELPA/gptel-20260728.211" \
  --directory . \
  --eval "(setq load-prefer-newer t)" \
  --eval "(setq package-user-dir (expand-file-name \"$ELPA\" default-directory))" \
  --eval "(package-initialize)" \
  -l test-step2.el

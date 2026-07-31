#!/usr/bin/env bash
# run-step6.sh — run the step 6 exit test.
# Exit 0 = STEP 6 PASSED.
set -uo pipefail
cd "$(dirname "$0")"          # -> test/

# load API keys from the project-root .env if present (never commit .env)
if [ -f ../.env ]; then
  set -a
  # shellcheck disable=SC1091
  . ../.env
  set +a
fi

ELPA="elpa"
[ -d "$ELPA" ] || emacs --batch -l install-gptel.el >&2

# lisp/ holds the production code; load-prefer-newer keeps source edits
# from being shadowed by a stale .elc
exec emacs --batch \
  --directory "$ELPA/gptel-20260728.211" \
  --directory ../lisp \
  --eval "(setq load-prefer-newer t)" \
  --eval "(add-to-list 'load-path \"/usr/share/emacs/30.2/lisp\")" \
  --eval "(setq package-user-dir (expand-file-name \"$ELPA\" default-directory))" \
  --eval "(package-initialize)" \
  -l test-step6.el

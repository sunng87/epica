#!/usr/bin/env bash
# run.sh — invoke the gptel provider spike (historical, step 1).
#
# Usage:
#   ./run.sh                       # uses EPICA_PROVIDER (default llamacpp)
#   EPICA_PROVIDER=anthropic ./run.sh   # needs ANTHROPIC_API_KEY
#
# Optional overrides:
#   EPICA_MODEL=<model-id>         # pin a specific model
#   EPICA_LLMACPP_HOST=http://host:port   # non-default router address
set -euo pipefail
cd "$(dirname "$0")"      # -> test/spike/

ELPA="../elpa"
[ -d "$ELPA" ] || emacs --batch -l ../install-gptel.el >&2

echo ">> EPICA_PROVIDER=${EPICA_PROVIDER:-llamacpp}"

# Hand gptel + deps to the batch emacs via load-path, then run the spike.
exec emacs --batch \
  --directory "$ELPA/gptel-20260728.211" \
  --eval "(setq load-prefer-newer t)" \
  --eval "(setq package-user-dir (expand-file-name \"$ELPA\" default-directory))" \
  --eval "(package-initialize)" \
  -l spike.el

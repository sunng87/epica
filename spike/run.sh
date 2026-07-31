#!/usr/bin/env bash
# run.sh — invoke the gptel provider spike.
#
# Usage:
#   ./spike/run.sh                       # defaults to llamacpp (local router, no key)
#   EPICA_PROVIDER=anthropic ./spike/run.sh   # needs ANTHROPIC_API_KEY
#   EPICA_PROVIDER=openai    ./spike/run.sh   # needs OPENAI_API_KEY
#   EPICA_PROVIDER=gemini    ./spike/run.sh   # needs GEMINI_API_KEY
#
# Optional overrides:
#   EPICA_MODEL=<model-id>               # pin a specific model
#   EPICA_LLMACPP_URL=http://host:port   # non-default router address
set -euo pipefail

cd "$(dirname "$0")/.."   # -> project root (epica/)

ELPA="spike/.elpa"

if [ ! -d "$ELPA" ]; then
  echo ">> gptel not installed; running install-gptel.el first" >&2
  emacs --batch -l spike/install-gptel.el >&2
fi

echo ">> EPICA_PROVIDER=${EPICA_PROVIDER:-anthropic}  EPICA_MODEL=${EPICA_MODEL:-<default>}"

# Hand gptel + deps to the batch emacs via load-path, then run the spike.
exec emacs --batch \
  --directory "$ELPA/gptel-20260728.211" \
  --eval "(setq package-user-dir (expand-file-name \"$ELPA\" default-directory))" \
  --eval "(package-initialize)" \
  -l spike/spike.el

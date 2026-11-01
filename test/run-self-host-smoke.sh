#!/usr/bin/env bash
# Optional end-to-end agent smoke against a local llama.cpp router.
# Does not load .env or use cloud credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
exec emacs -Q --batch \
  -L test/elpa/gptel-20260728.211 \
  -L test/elpa/llama-20260601.1455 \
  -L test/elpa/cond-let-20260701.1237 \
  -L lisp \
  -l test/self-host-smoke.el

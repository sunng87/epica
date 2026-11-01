#!/usr/bin/env bash
# Run deterministic, network-free ERT regressions against the checked-out code.
set -euo pipefail
cd "$(dirname "$0")/.."
exec emacs -Q --batch \
  -L test/elpa/gptel-20260728.211 \
  -L test/elpa/llama-20260601.1455 \
  -L test/elpa/cond-let-20260701.1237 \
  -L lisp \
  -l test/epica-session-tests.el \
  -l test/epica-loop-tests.el \
  -l test/epica-buffer-tests.el \
  -l test/epica-ui-tests.el \
  -l test/epica-project-tests.el \
  -l test/epica-skill-tests.el \
  -l test/epica-extension-tests.el \
  -f ert-run-tests-batch-and-exit

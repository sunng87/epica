# epica

**An Emacs-native coding agent.** epica is an LLM-powered coding harness
that lives inside Emacs — built on live buffers, Org sessions and
stateful Eshell, rather than treating the editor as a file viewer.

> **Status:** the original 8-step build (design → interactive UI) is
> complete. Offline ERT regressions cover the current core; the older
> model-backed integration suites have not been rerun after the latest
> fixes. See [`design.org`](./design.org) for the architecture.

---

## Install

**Requirements:** Emacs 29.1+, [`gptel`](https://github.com/karthink/gptel),
`transient` (built into Emacs 30 / GNU ELPA). Not on MELPA yet — install
from this repo. Production code lives in `lisp/`; `test/` and `.env`
are test-harness-only and never needed for real use.

```elisp
;; use-package (recommended)
(use-package epica
  :load-path "~/src/epica/lisp"
  :ensure gptel
  :after gptel)

;; once published to a forge, alternatively:
;;   :vc (:url "https://github.com/<you>/epica" :lisp-dir "lisp")
;; straight.el:
;;   :straight (epica :type git :host github :repo "<you>/epica"
;;                    :files ("lisp/*.el"))
```

`:lisp-dir` / `:files` are required: production code lives in `lisp/`,
not the repo root. One `(require 'epica)` pulls in the whole agent
(tools + UI). Only `lisp/epica.el` carries a `Package-Requires` header —
sub-files must not (package-vc merges headers; a self-reference breaks
activation).

After install: configure gptel first (see Providers), then `M-x epica`.
`C-c C-s` (or `C-c C-p`) opens a prompt-drafting buffer (magit-commit
style: write your prompt, `C-c C-c` sends, `C-c C-k` cancels, and the
window closes on send). Optionally enable session keybindings via
epica's own hook surface:

```elisp
(add-hook 'epica-session-start-hook (lambda () (epica-minor-mode 1)))
```

---

## Why

Most coding agents read files off disk, spawn a fresh shell per command,
and present their work as text you re-open later — the editor is a
*viewer* for their output. epica runs on the opposite premise: **the
editor is the agent's workspace**, so the agent works *with* you on what
you're already looking at.

## What epica gives you

- **Live buffer edits with free undo** — `edit-region` operates on the
  visible (possibly narrowed) buffer with case-sensitive, unique text
  matching; undo rides `buffer-undo-list`. `write-buffer` edits the
  file-visiting buffer and refuses to overwrite unsaved changes.
- **Narrowing is context** — `read-buffer` sees the visible region;
  optional line offsets let the model read large buffers in slices.
- **Edits fail closed** — an ambiguous or missing match is rejected;
  edits never target text hidden by narrowing. Stable read-to-edit
  region handles are not implemented yet.
- **The agent's shell IS Emacs' shell** — one stateful `eshell-run` per
  session in interactive Emacs. Eshell commands and Elisp expressions
  complete asynchronously without blocking redisplay. Batch-mode
  Eshell is stateless.
- **Project awareness as an extension** — optionally load
  `epica-project` for project.el discovery/search and Git tools.
- **Hooks are the extension system** — `epica-tool-call-hook` (block),
  `epica-tool-result-hook` (rewrite), `epica-session-start-hook`, …
  Any Emacs package can extend epica; there is no plugin loader.

**Built-in tools:** `open-file`, `read-buffer`, `edit-region`,
`save-buffer`, `write-buffer`, `eshell-run`, asynchronous `webfetch`
(url.el + shr), and `load-skill`. `epica-project` adds project and Git
tools when explicitly required. Project-local `.agents/skills/`
overrides global skills of the same name.

**Sessions** are file-visiting org-mode buffers: one heading per turn,
branching and LLM-driven compaction built in. Turn and tool payloads
use Org fixed-width lines so headings in model output cannot become
conversation structure. The originating project directory is saved
with the session and restored when reopened.

## Providers

- **Real integration:** configure gptel normally (key, backend, model).
  Leave `epica-backend`/`epica-model` nil and `epica-run` inherits
  `gptel-backend`/`gptel-model`. gptel's auth is epica's auth — there is
  no epica-specific key storage.
- **Test harness only:** the suites pick DeepSeek from
  `DEEPSEEK_API_KEY` (gitignored `.env`, see `.env.example`) or fall
  back to a local llama.cpp router. Real use never touches `.env`.

## Offline tests

Run `test/run-offline.sh` for deterministic ERT tests of session
round-tripping, tool dispatch, asynchronous operations, buffer edits,
skills and prompt routing. It uses local dependencies under `test/elpa/`
and does not call an LLM or read `.env`.

With a local llama.cpp router at `127.0.0.1:8331`, run
`test/run-self-host-smoke.sh`: epica uses a local model to open/read a
file, edit and save another, and invoke its asynchronous Eshell tool.
It uses no cloud API key and creates only temporary test files. The
older `test/run-step*.sh` scripts are separate model-backed checks.

## Philosophy

epica's design philosophy is Emacs' design philosophy: a minimal,
extensible core where the interesting behavior lives in user-contributed
code wired together by hooks. Fit Emacs — don't port another tool's
mental model into it.

## See also

- [`design.org`](./design.org) — architecture and build history
- [gptel](https://github.com/karthink/gptel) — provider layer
- [Agent Skills standard](https://agentskills.io) — shared skill format

## License

TBD.

# epica

**An Emacs-native coding agent.** epica is an LLM-powered coding harness
that lives entirely inside Emacs — built on buffers, overlays, eshell,
and Emacs' own code-intelligence tooling, not on a shell + filesystem
foundation.

> **Status:** the 8-step build (design → interactive UI) is complete and
> all test suites pass. See [`design.org`](./design.org) for the
> architecture.

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
Optionally enable session keybindings via epica's own hook surface:

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
  buffer you're viewing; undo rides `buffer-undo-list`, nothing to
  invent. Writes through `write-buffer` stay in sync with visited files
  (no stale-modtime prompts).
- **Narrowing is context** — `read-buffer` sees what you've narrowed,
  not an offset/limit fiction.
- **Markers keep edits stable** — no broken string matches when the
  buffer changes between plan and apply.
- **The agent's shell IS Emacs' shell** — one `eshell-run` per session,
  stateful across calls, and every command *or elisp expression*
  returns a value, exactly like typing in eshell.
- **Emacs' code intelligence as tools** — xref, project, imenu, eglot
  diagnostics; the agent navigates the way you do.
- **Hooks are the extension system** — `epica-tool-call-hook` (block),
  `epica-tool-result-hook` (rewrite), `epica-session-start-hook`, …
  Any Emacs package can extend epica; there is no plugin loader.

**Tools:** `read-buffer`, `edit-region`, `write-buffer`, `eshell-run`,
`webfetch` (url.el + shr — no curl), `load-skill` (Agent Skills
standard — pi's skills work verbatim).

**Sessions** are org-mode buffers: one heading per turn, branching and
LLM-driven compaction built in, plain readable text on disk.

## Providers

- **Real integration:** configure gptel normally (key, backend, model).
  Leave `epica-backend`/`epica-model` nil and `epica-run` inherits
  `gptel-backend`/`gptel-model`. gptel's auth is epica's auth — there is
  no epica-specific key storage.
- **Test harness only:** the suites pick DeepSeek from
  `DEEPSEEK_API_KEY` (gitignored `.env`, see `.env.example`) or fall
  back to a local llama.cpp router. Real use never touches `.env`.

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

# epica

**An Emacs-native coding agent.** epica is an LLM-powered coding harness
that lives entirely inside Emacs — built on buffers, overlays, eshell,
and Emacs' own code-intelligence tooling, not on a shell + filesystem
foundation.

> **Status:** in active design. See [`design.org`](./design.org) for the
> full architecture. This README describes the intended user experience
> and what makes epica different.

---

## Installation

**Requirements:** Emacs 29.1+, [`gptel`](https://github.com/karthink/gptel)
(the provider layer), and `transient` (built into Emacs 30, GNU ELPA
otherwise). epica is not on MELPA yet — install it from this
repository. Pick the mechanism that matches your setup.

### use-package (recommended)

Point `:load-path` at this checkout:

```elisp
(use-package epica
  :load-path "~/src/epica/lisp"   ; <-- production code lives in lisp/
  :ensure gptel
  :after gptel)
;; That's it. Requiring `epica' pulls in the buffer-native tools and the
;; interactive UI (epica.el requires them after `provide'); `epica-menu'
;; and the five tools are immediately available.

;; optional: the example extension (destructive-command gate + redaction)
;; (use-package epica-ext-demo
;;   :load-path "~/src/epica/lisp"
;;   :after epica)
```

### package-vc (when the repo is published to a forge)

```elisp
(use-package epica
  :vc (:url "https://github.com/<you>/epica" :lisp-dir "lisp")
  :after gptel)
```

`:lisp-dir "lisp"` is **required** — production code lives in `lisp/`
and package-vc defaults to the repo root. Requiring `epica` loads the
whole agent (tools + UI). Also note: only `lisp/epica.el` carries a
`Package-Requires` header — sub-files must not, because package-vc
merges headers from every `.el` and a self-reference breaks activation.

### straight.el

```elisp
(use-package epica
  :straight (epica :type git :host github :repo "<you>/epica"
                   :files ("lisp/*.el"))   ; production code lives in lisp/
  :after gptel)
```

`:files ("lisp/*.el")` is **required** — straight's default recipe looks
at the repo root only. String patterns are flattened into the package
directory (paths lose their subdirectory), so all four `.el` files land
on load-path directly.

### After install

1. **Configure gptel first** — epica inherits everything from it
   (backend, model, API key). See [Providers & API keys](#providers--api-keys).
2. **Start a session:** `M-x epica` (or `M-x epica-menu` for the full
   command menu).
3. **Optional — auto-enable the keybindings** in session buffers, via
   epica's own hook surface:

   ```elisp
   ;; C-c C-s send · C-c C-m menu · C-c C-n new session · C-c C-r resume
   (add-hook 'epica-session-start-hook (lambda () (epica-minor-mode 1)))
   ```

The `.env` file and everything under `test/` (suites, runners, the
step-1 spike) are **test-harness-only** — real integration never
touches them. Production code lives in `lisp/`.

---

## Why epica

Most coding agents today (Claude Code, Cursor, Aider, pi, …) share one
shape: they read files off disk, run a fresh shell per command, and
present their work as text you then have to open and review. The editor
is a *viewer* for the agent's output.

epica is built on the opposite premise: **the editor is the agent's
workspace.** Because Emacs' primitives — live buffers, overlays,
narrowing, markers, a Lisp-native shell — are richer than files + bash,
the agent can work *with* you on what you're already looking at, with
undo, reviewable edits, and the whole codebase a keypress away.

## The six structural wins

These are not features bolted on. They fall out of choosing Emacs as the
substrate.

### 1. Live buffer edits, with free undo

Other agents edit files on disk via fragile exact-string matching; you
see the result only by re-opening the file. epica edits **the buffer
you're already viewing**. Undo rides on `buffer-undo-list` /
`undo-tree` — nothing to invent. Proposed edits render as **overlays
you accept or reject**, so every change is reviewable in place.

### 2. Narrowing is context management

Other tools fake "show the model only part of the file" with line
offsets and limits. epica uses Emacs' native `narrow-to-region`: **the
agent's view and your view can be the same narrowed region.** Point it
at a function, and that's all it sees.

### 3. Markers make edits stable

If a buffer changes between the agent planning an edit and applying it —
because you typed something, or another edit landed — **markers track
the right location automatically.** No re-reading, no broken string
matches.

### 4. A stateful shell

Other agents spawn a fresh bash process per command and lose state each
time. epica runs in a **persistent eshell session**: environment
variables, working directory, and even defined functions carry across
calls. The agent can build up real shell state over a task.

### 5. Your codebase, as tools — for free

Because Emacs already understands code, epica gets a tool layer other
agents fake with grep-and-parse:

- `xref-find-definitions` / `xref-find-references`
- `project-find-regexp` across the whole project
- `imenu` outline navigation
- live flymake / eglot diagnostics
- `dired`, `magit`, `org`, and anything else you already use

The agent jumps to definitions and reads compile errors the same way you
do.

### 6. The extension surface is Emacs itself

Other agents invent their own plugin loaders, registration APIs, and
hot-reload systems. epica doesn't need one — **Emacs *is* the extension
system.** Hooks (`epica-tool-call-hook`, `epica-turn-end-hook`, …),
`advice-add`, and `define-minor-mode` are the API. Any Emacs package
can extend the agent, and any Emacs user already knows how.

---

## Design highlights

- **Built on [gptel](https://github.com/karthink/gptel).** We reuse
  gptel's provider, streaming, and auth layer rather than reimplementing
  HTTP/SSE for 30+ providers. epica's novelty is the agentic loop and
  buffer-native tools — not yet another OpenAI client.

- **Sessions are org-mode buffers.** Each turn is a heading, tool calls
  fold into sub-headings, branching is `org-clone-subtree`, and
  compaction collapses a range of headings into a summary. You get tree
  navigation, search, folding, and export for free — the session file is
  just readable plain text.

- **Skills follow the [Agent Skills standard](https://agentskills.io).**
  The same `SKILL.md` format used by pi and other agents, so on-demand
  capability packages are portable across ecosystems.

- **Minimal core, hook-driven everywhere.** Every decision point in the
  agent loop fires a hook. Permission gates, custom compaction,
  git-checkpointing, plan mode, sub-agents — all are ordinary Emacs
  packages that add hooks, not features baked into the core.

- **Four buffer-native tools at the center:** `read-buffer`,
  `edit-region`, `write-buffer`, `eeshell-run`. Plus thin wrappers over
  Emacs' code-intelligence commands, enabled as needed.

## How epica differs from other agents

|                                   | epica          | Typical agent (pi, Aider, …) |
|-----------------------------------|----------------|------------------------------|
| Edits                             | live buffer    | file on disk                 |
| Undo                              | native Emacs   | re-implemented               |
| Reviewing a change                | inline overlay | re-open file                 |
| Context scope                     | narrowing      | offset/limit math            |
| Shell                             | stateful eshell | fresh bash per call         |
| Code navigation                   | xref / project | grep + parse                 |
| Extension mechanism               | hooks / advice | bespoke loader               |
| Session format                    | org buffer     | JSON / JSONL                 |
| Provider backend                  | gptel          | custom                       |

## Philosophy

epica's design philosophy is Emacs' design philosophy: a minimal,
extensible core where the interesting behavior lives in user-contributed
code wired together by hooks. We aim to *fit* Emacs, not port another
tool's mental model into it.

## Providers & API keys

There are two entirely separate paths: **real integration uses gptel's
own setup; the `.env` mechanism is test-harness-only.**

### Real integration — configure gptel, epica inherits it

epica reuses gptel as the provider layer, so you configure your provider
exactly as you would for gptel alone:

```elisp
;; your init.el
(require 'epica)
(require 'epica-tools)
(require 'epica-ui)
;; gptel handles keys: M-x gptel, gptel-api-key, or auth-source
(gptel-make-deepseek "DeepSeek" :stream t)
```

With `epica-backend`/`epica-model` left nil (their defaults), every
`epica-run` falls back to `gptel-backend`/`gptel-model` — so epica uses
whatever backend, model, and key handling you already have in gptel.
There is no epica-specific key storage: gptel's auth is epica's auth.

### Test harness — `.env` + `epica-default-backend`

The automated suites (`test/test-step*.el`, `test/run-step*.sh`) cannot assume an
interactive gptel setup, so they pick a backend themselves:
`epica-default-backend` uses **DeepSeek when `DEEPSEEK_API_KEY` is set,
else the local llama.cpp router** (no-key fallback). The runners source
`.env` for that key:

```bash
cp .env.example .env          # fill in DEEPSEEK_API_KEY
./test/run-step2.sh           # uses DeepSeek; no key → local router
```

`.env` is gitignored — the key never reaches git. If you prefer, set
`DEEPSEEK_API_KEY` in your shell profile instead.

### Which model

- Test harness: `EPICA_MODEL` (in `.env` or the environment) overrides;
  default `deepseek-v4-flash`, or the local Qwen when falling back.
- Real integration: whatever `gptel-model` is — epica never overrides
  it (and respects a user-configured `gptel-max-tokens` too).

## Status & roadmap

epica is in the design phase. The intended build order (see
[`design.org`](./design.org) for detail):

1. gptel provider spike
2. `define-epica-tool` + minimal agent loop
3. the four buffer-native tools
4. org-mode session buffer + persistence
5. hook surface + first extension example
6. branching + compaction
7. skills loader
8. slash-command / transient UI

## License

TBD.

## See also

- [`design.org`](./design.org) — full architecture and rationale
- [gptel](https://github.com/karthink/gptel) — provider backend
- [llm.el](https://github.com/ahyatt/llm) — alternative thin provider layer
- [Agent Skills standard](https://agentskills.io) — shared skill format

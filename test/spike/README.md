# epica gptel provider spike

Validates build step 1 of `../../design.org`: that gptel's streaming +
tool-use loop is suitable as epica's provider backend.

## What it proves

All three exit criteria in one run, against a **local** model (no API
key):

1. **Streaming** — tokens arrive incrementally via the gptel callback.
2. **Tool round-trip** — the model calls a tool, gptel executes it, the
   result is fed back, the model continues.
3. **Buffer-native tool** — the tool under test, `read_buffer`, reads a
   *live Emacs buffer* the LLM never sees as text.

The model is asked to recover a secret planted in an Emacs buffer; it
must call `read_buffer` to get it. A pass prints
`>>> SPIKE PASSED: model recovered the buffer secret via tool <<<`.

## Run

```bash
# Default: local llama.cpp router (no key needed)
./run.sh

# Point elsewhere
EPICA_LLMACPP_HOST=host:port ./run.sh         # different router
EPICA_MODEL=gemma4 ./run.sh                   # different local model
EPICA_PROVIDER=anthropic ANTHROPIC_API_KEY=sk-ant-... ./run.sh
```

The router's model list is auto-discovered from `/v1/models`, so any
local model id works without code changes.

## Layout

- `install-gptel.el` — installs gptel into `test/elpa/`
  (does not touch `~/.emacs.d`)
- `spike.el` — the spike itself
- `run.sh` — entrypoint

## Findings (recorded in `../../design.org`)

- gptel's tool-use streaming fits epica's loop. Confirmed working.
- `gptel-model` must be a **symbol**; `intern` model ids.
- Custom OpenAI-compatible endpoints need an explicit `:models` list or
  gptel substitutes its hardcoded defaults (→ HTTP 400).
- Streaming callback fires `t` per HTTP request, not per conversation.
  Terminal for a tool loop = a turn with text **and** no tool call.
- Reasoning models (`reasoning_content`) think long — budget time.
- Qwen3.6-35B-A3B is an excellent, fast tool-caller. Gemma 4 E4B would
  not load in 6 min and Gemma tool-calling is historically weak.

---
description: z3Fusion with a custom panel — pass --models <model@runner,...> :: <question> to compose any mix of models/providers/local runners, or omit --models to let detect_panel.sh recommend the richest legacy preset automatically
argument-hint: "[--models <model@runner,...> ::] <your question>"
---
Invoke the **z3fusion** skill on the task below. Unlike the four pinned presets (`/z3fusion-claude`,
`/z3fusion-gpt5.6`, `/z3fusion-gemini`, `/z3fusion-3`), this command lets the panel be composed freely instead of
forcing one fixed legacy slug.

**Parse `$ARGUMENTS` first, before doing anything else:**

- If it starts with `--models` followed by a comma-separated list and then `::`, everything between
  `--models` and `::` is the panel spec; everything after `::` is the actual task (trim surrounding
  whitespace off both pieces). Example: `--models opus@claude,llama4@ollama,deepseek/deepseek-v4-pro@openrouter
  :: Compare X and Y` → panel spec = `opus@claude,llama4@ollama,deepseek/deepseek-v4-pro@openrouter`, task =
  `Compare X and Y`.
- Otherwise there is no `--models` prefix: the whole of `$ARGUMENTS` is the task, and the panel is not
  forced — run `bash <skill_dir>/scripts/detect_panel.sh` per the skill's own Step 0 and use whichever slug
  it recommends (it probes `codex`, `agy`, a local Ollama CLI/server, a local LM Studio server, and whatever
  provider API keys are set, then falls back all the way to two independent in-session Claude panelists if
  nothing else is reachable).

**Panel spec syntax — each comma-separated entry is a slot `model@runner`:**

- A bare `model` with no `@runner` (or the explicit `@claude` spelling of the same thing) means an
  **in-session Claude Agent-tool subagent** — handled entirely by the orchestrating Claude Code session, no
  external script involved.
- `model@codex` runs that model through `codex exec` (GPT family, local subscription, full local tool
  access against a throwaway copy of the workdir).
- `model@agy` runs that model through `agy` / Antigravity under a pseudo-TTY (Gemini family today).
- `model@ollama` runs a fully local model via the Ollama CLI/server — zero API key required, e.g.
  `llama4@ollama` or `qwen3.6-coder@ollama`.
- `model@<provider>` for any other runner name dispatches through `scripts/run_panelist.sh`, which resolves
  it against a built-in OpenAI-compatible provider table (`openrouter`, `lmstudio`, `ollama-api`, `openai`,
  `groq`, `together`, `fireworks`, `deepseek`, `mistral`, `xai`, `google`) or a runner registered in
  `~/.claude/z3fusion-runners.json`. OpenRouter alone proxies hundreds of models behind plain slug strings
  with no CLI needed, e.g. `deepseek/deepseek-v4-pro@openrouter`, `anthropic/claude-opus-4.8@openrouter`,
  `meta-llama/llama-4-maverick@openrouter`, `x-ai/grok-4@openrouter`.

Every slot becomes one blind, independent panelist under the same rules as the pinned presets: no "lenses",
every panelist gets the task **verbatim**, none sees another's work, and the orchestrating Claude Code
session is always the judge and writes the final answer — the panelist models have no way to call back out
to spawn it, so the pipeline can't be reversed regardless of how exotic the panel spec is.

**Two example invocations:**

- `/z3fusion --models opus@claude,llama4@ollama,deepseek/deepseek-v4-pro@openrouter :: Compare Rust's async
  runtime story to Go's goroutines for a high-throughput ingestion service.` — three panelists: an
  in-session Claude subagent, a fully local Llama 3.3 running through Ollama (no API key), and DeepSeek V3.2
  routed through OpenRouter (needs `OPENROUTER_API_KEY`).
- `/z3fusion Should we replace our internal REST gateway with gRPC for service-to-service calls?` — no
  `--models` prefix, so the panel is whatever `detect_panel.sh` recommends on this machine, falling back all
  the way to the two-independent-in-session-Claude-panelists preset if no external CLI/server/key is
  reachable.

Follow the skill's SKILL.md exactly (preflight → fan out in parallel → judge picking the track that fits
the task → grounded final deliverable → save provenance → present). For a research/analysis task, present
the standard audit-trail sections (Consensus / Contradictions / Partial coverage / Unique insights / Blind
spots); for a code/artifact task, run both candidates and merge them into one working result with a merge
rationale.

Dispatch each non-Claude slot through `scripts/run_panelist.sh <runner> <model> <prompt_file> <output_file>
[effort]` as the skill describes — do not reimplement its per-runner logic here. If a slot's
CLI/server/API is unavailable (exit 127), it times out (exit 124), or it otherwise fails (exit 1/2), drop
that panelist, record a one-line degradation note, and finish with whatever panel remains rather than
aborting — the same graceful-degradation contract as the pinned presets, just applied to an arbitrary spec
instead of a fixed slug.

Raw input (parse per the rules above before treating any of it as the task): $ARGUMENTS

---
name: fusion
description: >-
  Answer a hard question by fanning it out to a PANEL of models running in parallel — each answering
  independently with web search and bash, none seeing the others' work — then having the orchestrating
  Claude Code session judge every response into a structured analysis (consensus, contradictions, partial
  coverage, unique insights, blind spots) and write a final answer grounded in it. The panel is fully
  composable: 1-8 slots, each an independent "model@runner" pairing from ANY provider — in-session Claude
  Agent-tool subagents, the GPT family via the codex CLI, the Gemini family via the agy/Antigravity CLI,
  fully local Ollama models, a local LM Studio / vLLM / any OpenAI-compatible server, or literally any
  OpenRouter-listed model from any provider (Anthropic, OpenAI, Google, DeepSeek, Meta/Llama, Mistral,
  xAI/Grok, Qwen, and more) via an OPENROUTER_API_KEY. Four legacy slugs remain as zero-config presets
  (opus4.8-4.8, opus4.8-gpt5.5, opus4.8-gemini3.1pro, opus4.8-gpt5.5-gemini3.1pro) but they are convenience
  defaults, not the ceiling — pass a custom "--models" panel string of comma-separated model@runner slots
  instead. The orchestrating Claude Code session (whichever model it is actually running as) always judges
  and writes the final answer — the pipeline can't be reversed, because external panelist CLIs/APIs have no
  way to call back into this session. Runs on local CLI subscriptions or fully local models with no metered
  API required for the legacy presets, and can also reach metered provider APIs when configured. Saves a
  timestamped provenance .md per run, and answers in French by default. Use this whenever the user asks to
  "run it through z3Fusion", says /fusion, wants a multi-model / panel / ensemble answer, wants a question
  cross-checked across models, or wants a higher-confidence answer with consensus and blind spots surfaced —
  even if they don't say "fusion". General-purpose: any topic (research, law, strategy, technical,
  personal). Best for high-stakes research, design calls, and debugging where being confidently wrong is
  expensive.
---

# z3Fusion

z3Fusion turns one prompt into a panel. The question goes to several models **at the same time**, each
answering independently — with web search and bash, and with no knowledge of the others. Then the
orchestrating Claude Code session (this very session — whichever model it is actually running as: Opus,
Sonnet, Haiku, Fable, whatever the user selected via `/model`) reads every answer, extracts the structure of
the panel's reasoning (what they agree on, where they conflict, what only one saw, what they all missed),
and writes a final answer grounded in that analysis.

The whole mechanism is **independence, then synthesis**. The diversity that makes a panel beat a single
model is harvested, not manufactured: running the same prompt independently yields different reasoning
paths, tool calls, and sources. So there are **no assigned "lenses" or personas** — every panelist gets the
user's task **verbatim** and answers it straight. (See `references/panel.md`.)

**One hard rule, stated plainly as a scope boundary: the panel is freely composable across any model or
provider, but the judge and final synthesizer is always the orchestrating Claude Code session itself — the
pipeline can't be reversed.** External panelist CLIs and APIs (codex, agy, a local Ollama model, an
OpenRouter-listed model, any OpenAI-compatible server) have no way to call back into this session to spawn
more subagents, judge the panel, or write the final synthesis — only the orchestrator can do that, because
that capability lives in this session, not in a shelled-out CLI or an HTTP response. This is a real
limitation, not an implementation detail to gloss over: compose the panel however rich you like, across
however many providers you like, but the judge slot is never one of the panelists and is never itself
swappable to an external model.

**Design reference.** This skill's shape is a local implementation of [OpenRouter's Fusion Router](https://openrouter.ai/docs/guides/routing/routers/fusion-router): its `analysis_models` array (1-8
models, any provider, run in parallel with web tools) judged/synthesized by one outer `model` is exactly
what Step 2 (fan-out) and Step 3 (judge) do here — the difference is this skill dispatches every panelist
itself, locally, over CLI/API calls, instead of delegating that fan-out to OpenRouter's server-side plugin.
That means z3Fusion works **with or without an OpenRouter account**: the legacy presets and any local/CLI
runner need no OpenRouter key at all. When `OPENROUTER_API_KEY` *is* set, it additionally unlocks the
`<model>@openrouter` runner so any panel slot can point at literally any OpenRouter-listed model as a plain
per-model HTTP call — this is the robust, verified path, and it is what makes "any provider" real without
depending on OpenRouter's own multi-model plugin behavior. Separately, `providers.sh` also exposes an
EXPERIMENTAL `extra_json` passthrough (see Step 2's `openrouter` bullet) for advanced users who want to
attach OpenRouter's own native fusion plugin as a nested meta-panelist inside a single panel slot — that
path is opt-in, unverified against real provider responses in this environment, and clearly labeled
experimental; it is not needed for, and does not replace, the plain per-model path above.

Throughout, `<skill_dir>` is the directory containing this SKILL.md (when installed:
`~/.claude/skills/fusion`). Write the user's question **verbatim** to `/tmp/fusion_question.txt` first —
several steps reuse it.

## Step 0 — Pick the panel

```bash
bash <skill_dir>/scripts/detect_panel.sh
```

It probes every runner this machine can currently reach — not just `codex`/`agy` but also a local Ollama
CLI/server, a local LM Studio server, and whichever provider API keys are set in the environment (e.g.
`OPENROUTER_API_KEY`, `OPENAI_API_KEY`, `GROQ_API_KEY`, and the rest of the table in `providers.sh`) — and
prints a `SLUG=` line recommending the richest of the 4 legacy presets, plus a `RUNNERS AVAILABLE:` table
so you can see everything else that is composable beyond those 4 presets.

| Slug | Panel | Requires |
| --- | --- | --- |
| `opus4.8-4.8` | the same prompt run twice as 2 independent in-session Claude panelists | nothing — always available |
| `opus4.8-gpt5.5` | in-session Claude + GPT-5.5 in parallel | `codex` CLI |
| `opus4.8-gemini3.1pro` | in-session Claude + Gemini 3.1 Pro in parallel | `agy` CLI |
| `opus4.8-gpt5.5-gemini3.1pro` | in-session Claude + GPT-5.5 + Gemini 3.1 Pro in parallel | `codex` + `agy` CLIs |

Beyond these 4 presets, compose an ad hoc panel with `--models` — a comma-separated list of `model@runner`
slots, one per panelist. A bare model name with no `@` always means an in-session Claude Agent-tool
subagent (`opus` and `opus@claude` mean the same thing); every other slot's `runner` half selects how that
panelist is invoked (see Step 2). A few concrete examples, mixing local and cloud:

- `--models opus@claude,gpt-5.5@codex,gemini-3.1-pro@agy` — the legacy 3-model panel, spelled out
  explicitly instead of via a slug.
- `--models opus@claude,llama3.3@ollama,deepseek/deepseek-v3.2@openrouter` — one in-session Claude
  panelist, one fully local Ollama model (no API key), one OpenRouter-routed frontier model.
- `--models qwen2.5@ollama,llama-4-maverick@openrouter,gpt-5.5@codex,gemini-3.1-pro@agy,claude@claude` — a
  5-slot panel spanning a local model, OpenRouter, codex, agy, and in-session Claude in one call.

If the user named a slug (or used a pinned `/fusion-*` command) or passed `--models`, honor it — but if a
required CLI/server/key for a given slot is missing, say so, drop that panelist, and fall back to the
next-richest option (Step 2's graceful-degradation rules) rather than failing outright. Otherwise use the
detector's recommendation. Register additional local/remote runners for `--models` to use in
`~/.claude/fusion-runners.json` (see `scripts/providers.sh` for its exact shape).

## Step 1 — Preflight (informational, never a gate)

```bash
bash <skill_dir>/scripts/preflight.sh <SLUG> /tmp/fusion_question.txt
```

Show its output to the user (rough token/call estimate + Codex cap reminder), then proceed. It never
blocks. Each panelist is bounded by a per-panelist timeout (`FUSION_TIMEOUT`, default 300s) baked into the
runners; raise it for heavy deep-research questions (`FUSION_TIMEOUT=600 bash <skill_dir>/scripts/...`).

## Step 2 — Fan out, in parallel and blind

Read `references/panel.md`. Build each panelist's prompt as the user's task **verbatim** plus the short
instruction to research with web + bash and return a complete, self-contained answer as one of several
independent experts who won't see the others' work. Do **not** assign lenses; do **not** pre-digest the
task. (Answer in the user's question language.)

Launch **all panelists in a single turn** so they run concurrently:

- **In-session Claude panelist(s)** (any slot with no `@`, or explicitly `@claude`) → the `Agent` tool,
  `subagent_type: general-purpose` (web + bash built in). For `opus4.8-4.8`, spawn **two** independent
  Claude subagents with the *same* prompt — two cold runs. For every other panel, spawn **one** Claude
  subagent per `@claude` slot alongside the other panelists. Spawn them in the same message so they run at
  once. When each returns, write its answer to a temp file for provenance: `/tmp/fusion_opusA.md` (and
  `/tmp/fusion_opusB.md` for a second Claude run, etc.).
- **Every other panelist slot** (`codex`, `agy`, `ollama`, `openrouter`, `lmstudio`, or any custom runner
  registered in `~/.claude/fusion-runners.json`) → write its prompt to a temp file, then call the generic
  dispatcher:
  ```bash
  fusion_run_dir="$(mktemp -d "${TMPDIR:-/tmp}/fusion-panel.XXXXXX")"
  bash <skill_dir>/scripts/run_panelist.sh <runner> <model> "$fusion_run_dir/<runner>_prompt.md" "$fusion_run_dir/<runner>_out.md" [effort]
  ```
  Allocate one unique `fusion_run_dir` per z3Fusion invocation and put every prompt/output file for that
  invocation under it. Never use fixed paths like `/tmp/fusion_codex_prompt.txt` or
  `/tmp/fusion_codex_out.md`; multiple Claude Code sessions can run z3Fusion concurrently, and fixed names let
  one run read another run's prompt or answer.

  `run_panelist.sh` is the single entry point every non-Claude panelist goes through; it dispatches to the
  right underlying runner for you:
  - `codex` runner (GPT family, or whichever model the slot names, e.g. `gpt-5.5@codex`) → copies the
    current repo/workdir to a throwaway directory, then launches `codex exec` with full local access
    against that copy. This preserves the live checkout while letting the codex panelist use the same local
    tools and keychain-backed credentials as a trusted terminal Codex run. `-o` makes codex write only its
    final answer to the output file; read it once it finishes. The slot's model half is passed through to
    codex's own `--model` flag when non-empty, so you can point this runner at a different GPT-family model
    without changing anything else about the call.
  - `agy` runner (Gemini family, or whichever model the slot names) → calls `agy` under a pseudo-TTY
    (working around agy bug #76, which emits empty stdout with no TTY) with a transcript-JSONL fallback and
    a hard anti-empty guard, so it never returns a silently empty answer. The slot's model half is exported
    as `AGY_MODEL` before invoking agy.
  - `ollama` runner (any locally-pulled model, zero API key) → prefers the `ollama` CLI, piping the prompt
    on stdin and stripping ANSI/control bytes from the captured output; falls back to the local
    `http://localhost:11434/api/chat` REST endpoint if the CLI is absent or produced empty output.
  - any other runner name (`openrouter`, `lmstudio`, `openai`, `groq`, `together`, `fireworks`, `deepseek`,
    `mistral`, `xai`, `google`, or a custom entry from `~/.claude/fusion-runners.json`) → a generic
    OpenAI-chat-completions-compatible HTTP call, using that provider's base URL and (if required) API key
    from `providers.sh`. This is what makes "any OpenRouter-listed model" real: point a slot at
    `<model>@openrouter` (e.g. `deepseek/deepseek-v3.2@openrouter`, `meta-llama/llama-4-maverick@openrouter`,
    `x-ai/grok-4@openrouter`) with `OPENROUTER_API_KEY` set, and it is a plain per-model HTTP call — this is
    the robust, verified path for "any provider" and needs nothing beyond a standard chat-completions body.
    `providers.sh` also carries an EXPERIMENTAL `extra_json` field (empty by default) that gets merged
    verbatim into that slot's request body; its intended, opt-in use is attaching OpenRouter's own native
    fusion plugin as a nested meta-panelist inside a single `openrouter` slot (see the Design reference
    note above and `providers.sh` itself for the exact merge point) — treat this as unverified/best-effort
    only, the plain per-model path above is what to reach for by default.

  Exit codes are uniform across every runner `run_panelist.sh` dispatches to, not just codex/agy: `127` =
  the runner's CLI/API/server is not available, or the runner name is unrecognized — drop that panelist;
  `124` = timed out (`FUSION_TIMEOUT`) — drop that panelist; any other non-zero exit = drop that panelist
  and note the panel downgraded; `0` = success (output file written, non-empty). This is the same
  exit-code-based graceful-degradation contract that previously applied only to codex/agy — it now applies
  identically to every runner, built-in or custom.

Keep panelists isolated: never paste one panelist's output into another's prompt. The orchestrating session
(you) is the judge and must stay separate from the panelists — for `opus4.8-4.8`, or any custom panel with
multiple `@claude` slots, every Claude panelist is a spawned subagent, not you, so your synthesis reads all
answers fresh.

**Graceful degradation.** If a panelist exits non-zero, remove it, record a one-line degradation note (e.g.
`gemini dropped: agy empty -> opus4.8-gpt5.5`, or `llama3.3@ollama dropped: ollama unreachable (127)`), and
continue with what's left. For the legacy presets, the fallback order is:
`opus4.8-gpt5.5-gemini3.1pro` → `opus4.8-gpt5.5` → ultimate `opus4.8-4.8` (two independent in-session Claude
runs, zero external CLI). For `opus4.8-gemini3.1pro`, dropping Gemini falls back to `opus4.8-4.8` (spawn a
second independent Claude panelist) so the judge still sees two blind answers. For a custom `--models`
panel, the same rule applies generically: drop any failed slot, note the degradation, and continue with
whatever panelists remain. A degraded run still completes; never abort because one runner failed.

## Step 3 — Judge (pick the track that fits the task)

Once every panelist has returned, read `references/judge_rubric.md` and **classify the deliverable first**,
because code and prose merge completely differently:

- **Artifact task** (code, script, config, Minecraft mod/datapack, schema — the user wants a buildable
  thing) → **Track A: run both, then merge**. You are integrating two *implementations* into one working
  program, not writing a report. **Run each candidate with bash first** to see what actually works and what
  breaks in each, decide what to keep based on observed behavior (not on which looks better), graft the
  parts that worked onto the stronger base, then **run the merged result and fix until it passes**. The
  panel's value here is that two independent attempts expose each other's bugs — running both is how you
  find which one is actually right, so the merge ends up **more correct than either input**. (If it truly
  can't be executed here — needs the live game or an unavailable toolchain — fall back to seam-reasoning
  and mark it unverified.)
- **Research / analysis task** (the user wants understanding or a recommendation) → **Track B: structured
  synthesis** — the five sections: **Consensus**, **Contradictions**, **Partial coverage**, **Unique
  insights**, **Blind spots**. Don't average or smooth over conflict; independent agreement is your
  highest-confidence signal, honest disagreement is the most useful thing the panel produces. Write this
  analysis to `/tmp/fusion_analysis.md` for the provenance record.

Either way: attribute decisions to each panelist (by model / run), and weight a panelist that actually ran
the code or read a primary source over one reasoning from memory. If a panelist failed or was dropped, the
judge treats it as **absent** — never as silent agreement.

## Step 4 — Final deliverable

- **Track A (code/artifact):** emit the complete, merged artifact — every file, ready to run as-is, not a
  diff or "take A's X and B's Y." Per `judge_rubric.md`, you got here by **running both candidates** and
  keeping what worked, and you **run the merged result and fix it until it passes** before presenting.
  Follow with a tight merge rationale: what each candidate did when run, what you took from each, and what
  you verified.
- **Track B (research):** write the answer grounded in the structured analysis — lead with high-confidence
  consensus, fold in unique insights, flag what stays uncertain. It must follow *from* the synthesis, not
  be one panelist's answer lightly edited. Write it to `/tmp/fusion_final.md` for the provenance record.

## Step 5 — Save provenance

Save the run to an internal provenance file under `~/.claude/fusion-runs/` (raw panelist answers + the
analysis + the final answer, timestamped, for auditing):

```bash
FUSION_PANEL_NOTE="<degradation note, or empty>" \
FUSION_ESTIMATE="<the preflight one-liner, optional>" \
bash <skill_dir>/scripts/save_run.sh <SLUG> /tmp/fusion_question.txt /tmp/fusion_analysis.md /tmp/fusion_final.md \
  "opus-A=/tmp/fusion_opusA.md" "gpt5.5=$fusion_run_dir/codex_out.md" "gemini=$fusion_run_dir/gemini_out.md"
```

(`save_run.sh` substitutes a placeholder for any answer file that is missing or empty, so a degraded panel
still produces a complete record.) For a custom `--models` panel, pass one `label=path` pair per panelist
actually launched — label each with its `model@runner` slot (e.g. `llama3.3@ollama=$fusion_run_dir/ollama_out.md`)
instead of the legacy `opus-A`/`gpt5.5`/`gemini` labels above.

## Step 6 — Present

Lead with the **final deliverable** — the merged working artifact (Track A) or the grounded answer
(Track B) — then the audit trail beneath it: for code, what each candidate did when run + the
merge rationale + what you verified; for research, the five-section analysis. Name the panel slug (or the
composed `--models` list) you ran and which panelists participated. If the panel downgraded because a
CLI/server/key was missing, say so and how to enable the fuller panel (install the missing CLI, start the
local server, or set the missing API key).

## Cost & latency note

A panel costs roughly N× a single answer in tokens and runs as slow as its slowest panelist. That's the
deliberate trade: you spend more to stop being confidently wrong where that's expensive. For quick or
low-stakes questions, a single direct answer is the right call — don't reach for z3Fusion when one model
would obviously do.

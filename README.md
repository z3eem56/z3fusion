# z3Fusion

**Fuse a panel of frontier models — any of them, from any provider, including ones running on your own
machine — into one grounded answer.**

z3Fusion is a [Claude Code](https://claude.com/claude-code) skill that runs a hard question through a
**panel → judge** pipeline. The same prompt is dispatched to several models *in parallel* — each answering
independently with web search and bash, none seeing the others' work — and then the orchestrating Claude
Code session (whichever model it's actually running as — Opus, Sonnet, Haiku, Fable, whatever `/model` is
set to) reads every answer, judges it into a structured analysis (consensus, contradictions, partial
coverage, unique insights, blind spots), and writes a final answer grounded in that analysis.

<p align="center">
  <img src="assets/pipeline.svg" alt="z3Fusion pipeline: a prompt fans out to several independent panelists (any model@runner mix, each answering blind with web + bash), which the orchestrating Claude Code session judges and synthesizes into consensus, contradictions, partial coverage, unique insights and blind spots, then writes a final grounded answer." width="100%">
</p>

## Why a panel beats one model

The diversity that makes a panel beat a single model is **harvested, not manufactured**: running the same
prompt independently yields different reasoning paths, tool calls, and sources — even two cold runs of the
*same* model diverge enough that synthesizing them beats running it once. So z3Fusion assigns no contrived
"lenses" or personas; every panelist gets the task **verbatim** and answers it straight.

On the DRACO deep-research benchmark, [OpenRouter](https://openrouter.ai/docs/guides/routing/routers/fusion-router)
found that fusing model answers consistently beats the individual models — and that a meaningful chunk of
the lift comes from the *synthesis step itself*, not just from mixing architectures. z3Fusion implements that
same independence-then-judge pipeline locally in Claude Code.

**Design reference.** z3Fusion's panel → judge shape is a local implementation of
[OpenRouter's Fusion Router](https://openrouter.ai/docs/guides/routing/routers/fusion-router): its
`analysis_models` array (1-8 models, any provider, run in parallel with web tools) judged/synthesized by
one outer `model` is exactly what z3Fusion's fan-out + judge steps do — the difference is z3Fusion dispatches
every panelist itself, locally, over CLI/API calls, so it works fully **with or without** an OpenRouter
account. (OpenRouter also ships fusion as a hosted, server-side capability — its
[z3Fusion plugin](https://openrouter.ai/docs/guides/features/plugins/z3fusion) — which is a different thing
from the Fusion Router design above; an `openrouter` panel slot can optionally attach that plugin as an
EXPERIMENTAL, opt-in path — see [Advanced: attach OpenRouter's own fusion plugin](#advanced-attach-openrouters-own-fusion-plugin).)

## The core feature: any model, any provider, `model@runner`

Every panel slot is a **`model@runner`** pairing — 1 to 8 of them per panel, in any combination. There is
no fixed roster:

| Runner | What it reaches | Needs |
| --- | --- | --- |
| *(no `@runner`, or `@claude`)* | An **in-session Claude Agent-tool subagent** — this very Claude Code session, spawned as a blind panelist | nothing — always available |
| `codex` | The **GPT family**, via the [`codex` CLI](https://github.com/openai/codex) (`codex exec`, full local tool access against a throwaway repo copy) | `codex` CLI, logged in |
| `agy` | The **Gemini family**, via the `agy` / Antigravity CLI (pseudo-TTY workaround for its print-mode bug) | `agy` CLI, keyring seeded |
| `ollama` | **Any locally-pulled Ollama model** — zero API key, never leaves your machine | `ollama` CLI or local server |
| `lmstudio` | A model loaded in **LM Studio**'s local server | LM Studio running (`localhost:1234`) |
| `openrouter` | **Any model OpenRouter lists, from any provider** — Anthropic, OpenAI, Google, DeepSeek, Meta/Llama, Mistral, xAI, Qwen, and hundreds more, addressed as a plain slug like `deepseek/deepseek-v4-pro` | `OPENROUTER_API_KEY` |
| `openai`, `groq`, `together`, `fireworks`, `deepseek`, `mistral`, `xai`, `google` | That provider's own hosted API, direct | that provider's API key |
| *(anything else)* | A runner **you register** — another HTTP provider or a bespoke local CLI — in `~/.claude/z3fusion-runners.json` | whatever you configure |

A few concrete panels this makes possible:

```
opus@claude,gpt-5.6@codex,gemini-3.1-pro@agy                              — the classic 3-model panel, spelled out
opus@claude,llama4@ollama,deepseek/deepseek-v4-pro@openrouter             — one hosted, one local, one OpenRouter
qwen3.6@ollama,llama-4-maverick@openrouter,gpt-5.6@codex,gemini-3.1-pro@agy,claude@claude   — 5 panelists, 4 providers
```

Compose these with `--models <model@runner,...>` via the generic `/z3fusion` command, or just ask in prose
("run z3Fusion with a local Llama model and DeepSeek from OpenRouter on …"). `detect_panel.sh` (z3Fusion's
Step 0) probes every runner reachable on your machine — CLIs on `PATH`, local servers, provider API keys in
your environment — and recommends the richest panel automatically if you don't specify one.

**Scope boundary, stated plainly:** the **panel** is freely composable across any provider — but the
**judge/synthesizer is always the orchestrating Claude Code session's own model**. External panelist
CLIs and APIs have no way to call back into this session to spawn the judge, so the pipeline can never be
reversed. That's a deliberate design boundary, not a bug to work around.

### Registering your own runner

Anything not built in — another OpenAI-compatible HTTP endpoint (an internal proxy, vLLM, a self-hosted
`llama.cpp` server), or a totally different local CLI — goes in `~/.claude/z3fusion-runners.json`:

```json
{
  "providers": {
    "my-vllm": {
      "baseUrl": "http://localhost:8000/v1",
      "apiKeyEnv": ""
    }
  },
  "custom": {
    "my-cli": {
      "template": "my-tool --model {model} --in {prompt_file} --out {output_file}"
    }
  }
}
```

- A `providers` entry is any OpenAI-chat-completions-compatible HTTP endpoint: set `baseUrl`, and
  `apiKeyEnv` to the name of an env var holding a bearer token (or `""` for a local no-auth server). It's
  then usable as `<model>@my-vllm`.
- A `custom` entry is a plain shell command template for a non-HTTP local CLI, with `{model}`,
  `{prompt_file}`, `{output_file}` placeholders substituted in. Usable as `<model>@my-cli`.
- Entries here override a built-in of the same name, so you can point `openrouter` at a proxy, or swap
  which env var it reads.

See `skills/z3fusion/scripts/providers.sh`'s header comment for the exact schema — that file is the source of
truth for it.

### Advanced: attach OpenRouter's own fusion plugin

`providers.sh` also carries an **EXPERIMENTAL** `extraJson` field (empty by default) that gets merged
verbatim into an `openrouter`-runner request body. Its intended, opt-in use is attaching OpenRouter's own
[native fusion plugin](https://openrouter.ai/docs/guides/routing/routers/fusion-router) as a nested
meta-panelist inside a single `openrouter` slot. This is unverified against real provider responses and not
needed for "any provider" to work — the plain per-model `<model>@openrouter` path above is the default,
robust way to reach any OpenRouter-listed model, and doesn't depend on this plugin's schema at all.

## The panels (quickstart / zero-config presets)

Four pinned panels to get going with, no custom `model@runner` spec required — these are convenience
defaults, not the ceiling:

| Slug | Panel | Requires |
| --- | --- | --- |
| `claude-claude` | the **same prompt run twice** as 2 independent in-session Claude panelists → the session judges | nothing — works everywhere |
| `claude-gpt5.6` | in-session Claude + **GPT-5.6 Sol** (codex) in parallel → the session judges | the `codex` CLI |
| `claude-gemini3.1pro` | in-session Claude + **Gemini 3.1 Pro** (agy) in parallel → the session judges | the `agy` CLI |
| `claude-gpt5.6-gemini3.1pro` | in-session Claude + GPT-5.6 Sol + Gemini 3.1 Pro in parallel → the session judges | `codex` + `agy` CLIs |

`detect_panel.sh` auto-detects which panelist CLIs are installed and recommends the richest of these four,
falling back gracefully when one is missing — a required CLI absent never aborts a run, it just drops that
panelist and notes the degradation.

## Install

```bash
git clone https://github.com/z3eem56/z3fusion.git
cd z3fusion
./install.sh
```

This copies the skill to `~/.claude/skills/z3fusion` and the slash commands to `~/.claude/commands`, then
prints a full report of which panels and runners your machine can currently use — legacy presets, local
Ollama/LM Studio reachability, and which provider API keys are set. Restart Claude Code (or run
`/reload-skills`) afterward.

> Override the target with `CLAUDE_CONFIG_DIR=/path/to/.claude ./install.sh`.

## Use it

Four ways, all equivalent under the hood:

- **Natural language** — just ask. The skill auto-triggers and picks the richest available panel:
  > "Run this through z3Fusion: is it safe to `ALTER TABLE … ADD COLUMN` on a 200M-row Postgres table in prod?"
- **Pinned slash commands** — force one of the four zero-config presets:
  ```
  /z3fusion-claude  does my JWT refresh-rotation design have a replay hole?
  /z3fusion-gpt5.6   is git push --force-with-lease actually safe on a shared branch?
  /z3fusion-gemini   is this migration script safe to run against a live replica?
  /z3fusion-3        full 3-family panel (Claude + GPT-5.6 Sol + Gemini 3.1 Pro)
  ```
- **Composable panel** — `/z3fusion --models <model@runner,...> :: <question>` to pick any mix of
  models/providers/local runners yourself, or `/z3fusion <question>` with no `--models` to let
  `detect_panel.sh` recommend the richest preset automatically.
- **Force a panel in prose** — "run the `claude-gpt5.6` z3Fusion on …", or "z3Fusion this with a local Ollama
  model and Grok from OpenRouter".

## What you get back

Every run returns the same structure: a **Final answer** up top, then an audit trail beneath it — with each
point attributed to the panelist that raised it, so you can trace any decision back to its source. Which
shape that audit trail takes depends on what you asked for:

- **Artifact task** (code, a script, a config, a schema) → **Track A**: the panelists' candidate
  implementations are each *actually run* — built, tested, exercised — and the judge merges the parts that
  demonstrably worked into one coherent artifact, then runs *that* and fixes it until it passes. You get the
  complete, ready-to-run result plus a tight merge rationale (what each candidate did when run, what was
  kept, what was verified) — never a diff, never two solutions pasted together.
- **Research / analysis task** → **Track B**: five sections — **Consensus** (what panelists independently
  agreed on, your highest-confidence signal), **Contradictions** (real disagreements, adjudicated where
  possible), **Partial coverage** (sub-questions only some panelists engaged), **Unique insights**
  (non-obvious points raised by exactly one panelist), and **Blind spots** (what the whole panel missed) —
  followed by a final answer that follows *from* that synthesis, not one panelist's answer lightly edited.

Every run is also written to a timestamped provenance file under `~/.claude/z3fusion-runs/` — raw panelist
answers, the analysis, and the final answer — for auditing later.

## Planning: `/z3fusion-plan` (iterative + OMC-integrated)

`/z3fusion-plan` applies the panel to **planning** specifically. Instead of one panel→judge pass, it runs the
panel as an **iterative loop** and plugs into the **oh-my-claudecode (OMC)** plan system end to end:

1. **Requirements** — *interactive* (you run `/z3fusion-plan` yourself): auto-chains OMC's `omc-plan`
   interview (one question at a time, explore-first, Analyst consult) → initial plan in
   `.omc/plans/<slug>.md`. *Non-interactive* (autonomous run, inside a sub-agent, or `--no-interview`): no
   interview — derives requirements from the existing story doc / plan context, so it never hangs waiting
   on an answer no one is there to give.
2. **Deepen (3 rounds, seeded)** — each round an in-session Claude panelist and a GPT-5.6 Sol panelist (via
   `codex`) independently critique-and-improve the current plan **in parallel and blind**; the session
   judges and synthesizes one tighter plan that seeds the next round. Stops early on `NO_MATERIAL_CHANGE`.
3. **Write back** — the converged plan is written back to `.omc/plans/<slug>.md`, kept **concise but
   content-dense** (the judge compresses across rounds rather than accumulating length).
4. **Handoff** — offers the OMC quality gate (`/omc-plan --review`) → execution (`/team` or `/ralph`).

```
/z3fusion-plan design the schema + flow for <feature>
```

It works best with OMC installed (falls back to a minimal inline interview without it) and needs the
`codex` CLI for the GPT-5.6 Sol half (otherwise it falls back to two independent Claude panelists per round).
Reserve it for high-stakes planning — it costs an interview + ~6 panelist runs + 3 judge passes.

### Optional backstop hook

`hooks/z3fusion-plan-nudge.sh` is an optional `PreToolUse` hook (matcher `Agent|Task`). When the orchestrator
is about to delegate a non-trivial *implementation* task to a sub-agent, it injects an advisory reminder to
run `/z3fusion-plan --no-interview` on it first. Advisory only (never blocks), de-dupes per task, skips
z3Fusion's own panelist spawns. `install.sh` copies it to `~/.claude/hooks/` but does **not** enable it — opt
in via `settings.json` (the installer prints the exact snippet).

## Requirements, per runner

- **Claude Code**, any model — panelist subagents and the judge always inherit the orchestrating session's
  own model. (The `claude-*` slug names mean "an in-session Claude subagent" — whichever model the session runs as.)
- `codex` runner: the [`codex` CLI](https://github.com/openai/codex), logged in to an account with GPT-5.6 Sol
  access (tested against `codex-cli` 0.139). Runs against a throwaway copy of the current repo/workdir with
  trusted local access, so tools like `gh`, test runners, Docker, and SDK-managed toolchains behave like
  they do in your terminal, without writing back to the live checkout.
- `agy` runner: the **`agy`** (Antigravity) CLI, installed with its keyring seeded — run `agy` once
  interactively to complete the Google OAuth, then headless runs reuse that login. Works around agy's
  print-mode bug (empty stdout under no TTY) via a pseudo-TTY, a transcript-JSONL fallback, and a hard
  anti-empty guard, so it never silently returns nothing.
- `ollama` runner: the [Ollama](https://ollama.com) CLI with the model already pulled, **or** just a local
  Ollama server running — no API key either way. Prefers the CLI (`ollama run <model>`), falls back to the
  local REST API if the CLI is absent or comes back empty.
- `lmstudio` runner: [LM Studio](https://lmstudio.ai)'s local server running with a model loaded
  (`localhost:1234`) — no API key.
- `openrouter` / `openai` / `groq` / `together` / `fireworks` / `deepseek` / `mistral` / `xai` / `google`
  runners: the matching API key set in your environment (`OPENROUTER_API_KEY`, `OPENAI_API_KEY`, etc.).
- Any custom runner: whatever you configured for it in `~/.claude/z3fusion-runners.json`.

Every z3Fusion invocation uses its own temporary prompt/output directory, so concurrent runs — in different
Claude Code sessions, or different panels in the same session — never read each other's panelist artifacts.
Each panelist is bounded by a per-panelist timeout (`FUSION_TIMEOUT`, default 300s; there's no
`timeout`/`gtimeout` on stock macOS, so runners wrap calls in a self-contained `perl` timeout helper).

Only `claude-claude` is truly zero-setup among the legacy presets; everything else lights up once its
CLI/server/key is available — and nothing ever *has* to be installed, since z3Fusion degrades gracefully to
whatever panel the machine can actually support.

## What's in here

```
skills/z3fusion/
  SKILL.md                  detect → preflight → blind fan-out → judge → grounded final → save
  scripts/
    _fusion_lib.sh          shared helpers: perl-based per-panelist timeout, have(), JSON content extraction
    _pty_run.py             pty.fork() runner so agy gets a TTY even under socket stdio (cmux/headless)
    detect_panel.sh         reports every reachable runner + recommends a legacy preset
    preflight.sh            non-blocking token/call estimate + Codex cap reminder
    run_panelist.sh         generic dispatcher: model@runner -> the right runner below
    run_codex.sh            runs a GPT-family panelist via codex exec (web + bash, timeout, optional --model)
    run_gemini.sh           runs a Gemini-family panelist via agy (pseudo-TTY + transcript fallback)
    run_ollama.sh           runs a fully local Ollama panelist (CLI + REST fallback, zero API key)
    run_openai_compat.sh    runs any OpenAI-chat-completions-compatible HTTP panelist (OpenRouter, hosted APIs, local servers)
    providers.sh            built-in provider table + ~/.claude/z3fusion-runners.json loader
    save_run.sh             writes the timestamped provenance .md to ~/.claude/z3fusion-runs/
  references/
    panel.md                why independent parallel runs (no lenses) — the panel mechanism
    judge_rubric.md         Track A (merge & verify) / Track B (structured synthesis) rubric
skills/z3fusion-plan/
  SKILL.md                  OMC interview → 3-round seeded panel → concise .omc/plans/ → review/execute
commands/
  z3fusion.md                 /z3fusion          (composable --models <model@runner,...> panel, any provider)
  z3fusion-claude.md         /z3fusion-claude  (pinned claude-claude panel)
  z3fusion-gpt5.6.md          /z3fusion-gpt5.6   (pinned claude-gpt5.6 panel)
  z3fusion-gemini.md          /z3fusion-gemini   (pinned claude-gemini3.1pro panel)
  z3fusion-3.md               /z3fusion-3        (pinned full claude-gpt5.6-gemini3.1pro panel)
  z3fusion-plan.md            /z3fusion-plan     (OMC-integrated iterative planning; reuses z3fusion's run_codex.sh)
hooks/
  z3fusion-plan-nudge.sh      optional PreToolUse backstop (not auto-enabled) — nudges /z3fusion-plan on spawn
install.sh                  copies the above into ~/.claude (hook copied but left disabled)
```

## Cost & latency

A panel costs roughly N× a single answer in tokens and runs as slow as its slowest panelist. That's the
deliberate trade: spend more to stop being confidently wrong where that's expensive. For quick or
low-stakes questions, a single direct answer is the right call — don't reach for z3Fusion when one model
would obviously do.

## License

MIT — see [LICENSE](LICENSE).

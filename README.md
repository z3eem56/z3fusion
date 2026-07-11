# Fusion

**Fuse a panel of frontier models into one top-tier answer.**

Fusion is a [Claude Code](https://claude.com/claude-code) skill that runs a hard question through a
**panel → judge** pipeline. The same prompt is dispatched to several models *in parallel* — each answering
independently with web search and bash, none seeing the others' work — and then the orchestrating
Claude Code session (whichever model it is actually running as — Opus, Sonnet, Haiku, Fable, whatever
`/model` is set to) judges every answer into a structured analysis (consensus, contradictions, partial
coverage, unique insights, blind spots) and writes a final answer grounded in it.

The mechanism is **independence, then synthesis**. The diversity that makes a panel beat a single model is
harvested, not manufactured: running the same prompt independently yields different reasoning paths, tool
calls, and sources — even two cold runs of the *same* model diverge enough that synthesizing them beats
running it once. So there are no contrived "lenses" or personas; every panelist gets the task verbatim and
answers it straight. Fuse **two in-session Claude runs**, or **Claude + GPT-5.5** (via the `codex` CLI),
into a result better than either alone.

The panel itself is a fully composable list of **`model@runner`** slots (1-8 of them), not limited to any
fixed roster: an in-session Claude subagent, GPT-5.5 via `codex`, Gemini via `agy`, a fully local model
running on your own machine through **Ollama** or **LM Studio** (zero API key), or literally any
**OpenRouter**-listed model from any provider (Anthropic, OpenAI, DeepSeek, Meta/Llama, Mistral, xAI, Qwen,
and more) the moment `OPENROUTER_API_KEY` is set. The three panels below are a zero-config starting point,
not the ceiling — see [**Bring your own model**](#bring-your-own-model) to compose anything beyond them.

**Design reference.** Fusion's panel → judge shape is a local implementation of
[OpenRouter's Fusion Router](https://openrouter.ai/docs/guides/routing/routers/fusion-router): its
`analysis_models` array (1-8 models, any provider, run in parallel) judged/synthesized by one outer `model`
is exactly what the fan-out + judge steps below do — the difference is Fusion dispatches every
panelist itself, locally, over CLI/API calls, so it works fully with **or without** an OpenRouter account.
(OpenRouter also ships fusion as a hosted, server-side capability — its
[Fusion plugin](https://openrouter.ai/docs/guides/features/plugins/fusion) — which is a different thing
from the Fusion Router design above: an `openrouter` panel slot can optionally attach that plugin via the
EXPERIMENTAL `extraJson` field in `~/.claude/fusion-runners.json`, but that path is opt-in and unverified
here; the plain per-model `model@openrouter` call described below is the default, robust path.)

```
                      ┌──────────────┐
                 ┌──▶ │  panelist 1  │ ─┐   (web + bash, independent)
                 │    └──────────────┘  │
                 │    ┌──────────────┐  │   ┌──────────────┐
 prompt ──▶ fan ─┼──▶ │  panelist 2  │ ─┼─▶ │ orchestrating│ ──▶ final answer
            out  │    └──────────────┘  │   │   session    │     (grounded in
                 │    ┌──────────────┐  │   │  (judge +    │      the analysis)
                 └──▶ │  panelist 3  │ ─┘   │  synthesize) │
                      └──────────────┘      └──────────────┘
              any model@runner mix            consensus · contradictions ·
              (each answers blind)             partial · unique · blind spots
```

The orchestrating Claude Code session **always** judges and writes the final answer — the pipeline
can't be reversed, because external panelist CLIs/APIs have no way to call back into this session to
spawn more subagents. **This is a stated scope boundary, not a bug:** the panel is freely composable
across any model/provider, but the judge is always this session's own model.

## The panels (quickstart / zero-config example)

Three pinned, zero-setup panels to get going with — no custom panel spec required:

| Slug | Panel | Requires |
| --- | --- | --- |
| `opus4.8-4.8` | the **same prompt run twice** as 2 independent in-session Claude panelists → the session judges | nothing — works everywhere |
| `opus4.8-gpt5.5` | in-session Claude + **GPT-5.5** (codex) in parallel → the session judges | the `codex` CLI |
| `opus4.8-gpt5.5-gemini3.1pro` | in-session Claude + GPT-5.5 + **Gemini 3.1 Pro** in parallel → the session judges | `codex` + `agy` CLIs |

The skill auto-detects which panelist CLIs are installed and uses the richest of these three panels
available, falling back gracefully when one is missing. These are convenience presets, not a limit —
any panel slot can be replaced or extended with any other `model@runner` pairing; see the next section.

## Bring your own model

Every panel slot is a composable **`model@runner`** pairing, so the three presets above are a starting
point, not the whole story. A few concrete combos, spanning cloud and fully local:

- `llama3.3@ollama` — a fully local Llama 3.3 served by **Ollama**, zero API key, never leaves your
  machine.
- `qwen2.5-coder@lmstudio` — a model already loaded in **LM Studio**'s local server (`localhost:1234`),
  also zero API key.
- `deepseek/deepseek-v3.2@openrouter`, `meta-llama/llama-4-maverick@openrouter`, or
  `x-ai/grok-4@openrouter` — any model **OpenRouter** lists, reached with a plain per-model HTTP call once
  `OPENROUTER_API_KEY` is set.
- `opus@claude,gpt-5.5@codex,llama3.3@ollama` — an in-session Claude subagent, GPT-5.5 via `codex`, and a
  fully local Ollama model, all in one panel.

Compose these with `--models <model@runner,...>` (e.g. via the generic `/fusion` command), or just ask in
prose. Register further local/remote runners — another local server, an internal proxy, a bespoke shell
command — in `~/.claude/fusion-runners.json`.

**Scope boundary, stated plainly:** the **panel** is freely composable across any provider — but the
**judge/synthesizer is always the orchestrating Claude Code session's own model**. External panelist
CLIs and APIs have no way to call back into this session to spawn the judge, so the pipeline can never be
reversed. That is a deliberate, stated design boundary, not a bug to work around.

## Install

```bash
git clone https://github.com/z3eem56/fusion.git
cd fusion
./install.sh
```

This copies the skill to `~/.claude/skills/fusion` and the slash commands to `~/.claude/commands`,
then prints which panels your machine can run. Restart Claude Code (or run `/reload-skills`) afterward.

> Override the target with `CLAUDE_CONFIG_DIR=/path/to/.claude ./install.sh`.

## Use it

Three ways, all equivalent under the hood:

- **Natural language** — just ask. The skill auto-triggers and picks the richest panel:
  > "Run this through Fusion: is it safe to `ALTER TABLE … ADD COLUMN` on a 200M-row Postgres table in prod?"
- **Pinned slash commands:**
  ```
  /fusion-opus4.8  does my JWT refresh-rotation design have a replay hole?
  /fusion-gpt5.5   is git push --force-with-lease actually safe on a shared branch?
  /fusion-gemini   is this migration script safe to run against a live replica?
  /fusion-3        full 3-family panel (Claude + GPT-5.5 + Gemini 3.1 Pro)
  ```
- **Composable panel** — `/fusion --models <model@runner,...> :: <question>` to pick any mix of
  models/providers/local runners yourself, or `/fusion <question>` with no `--models` to let
  `detect_panel.sh` recommend the richest legacy preset automatically.
- **Force a panel in prose** — "run the `opus4.8-gpt5.5` Fusion on …".

Every run returns the same structure: a **Final answer** up top, then the audit trail —
**Consensus / Contradictions / Partial coverage / Unique insights / Blind spots** — with each point
attributed to the panelist that raised it, so you can see how the answer was assembled. Every run is also
written to a timestamped provenance file under `~/.claude/fusion-runs/` (raw panelist answers + analysis +
final answer) for auditing.

## Planning: `/fusion-plan` (iterative + OMC-integrated)

`/fusion-plan` applies the panel to **planning**. Instead of one panel→judge pass it runs the panel as an
**iterative loop** and plugs into the **oh-my-claudecode (OMC)** plan system end to end:

1. **Requirements** — *interactive* (you run `/fusion-plan` yourself): auto-chains OMC's `omc-plan`
   interview (one question at a time, explore-first, Analyst consult) → initial plan in
   `.omc/plans/<slug>.md`. *Non-interactive* (autonomous run, inside a sub-agent, or `--no-interview`):
   **no interview** — derives requirements from the existing story doc / plan context, so it never hangs
   waiting on an answer no one is there to give.
2. **Deepen (3 rounds, seeded)** — each round an Opus 4.8 panelist and a GPT-5.5 panelist (via `codex`)
   independently critique-and-improve the current plan **in parallel and blind**; Opus 4.8 judges and
   synthesizes one tighter plan that seeds the next round. Stops early on `NO_MATERIAL_CHANGE`.
3. **Write back** — the converged plan is written back to the same `.omc/plans/<slug>.md`, kept **concise
   but content-dense** (the judge compresses across rounds rather than accumulating length).
4. **Handoff** — offers the OMC quality gate (`/omc-plan --review`) → execution (`/team` or `/ralph`).

```
/fusion-plan design the schema + flow for <feature>
```

The panel replaces only the *plan-thinking* step; OMC owns the interview, plan format, quality gate, and
execution. It works best with OMC installed; without OMC it falls back to a minimal inline interview. Like
the base panel it needs the `codex` CLI for the GPT-5.5 half (otherwise it falls back to two Opus 4.8
panelists per round). Reserve it for high-stakes planning — it costs an interview + ~6 panelist runs + 3
judge passes.

### Optional backstop hook

`hooks/fusion-plan-nudge.sh` is an optional `PreToolUse` hook (matcher `Agent|Task`). When the orchestrator
is about to delegate a non-trivial *implementation* task to a sub-agent, it injects an advisory reminder to
run `/fusion-plan --no-interview` on it first. It is advisory only (never blocks), de-dupes per task, and
skips fusion's own panelist spawns. `install.sh` copies it to `~/.claude/hooks/` but does **not** enable it
— opt in by adding it to your `settings.json` (the installer prints the snippet). Leave it off to keep
planning fully manual.

## Requirements

- **Claude Code**, any model (panelist subagents and the judge always inherit the orchestrating session's
  own model — the `opus4.8-*` slug names are historical/nominal, not a requirement to actually run Opus).
- For `opus4.8-gpt5.5`: the [`codex` CLI](https://github.com/openai/codex) installed and logged in to an
  account with GPT-5.5 access. The runner uses `codex exec` (tested against `codex-cli` 0.139).
  It runs against a throwaway copy of the current repo/workdir with trusted local access so tools such as
  `gh`, local test runners, Docker, and SDK-managed toolchains behave like they do in your terminal without
  writing back to the live checkout.
  Each Fusion invocation uses its own temporary prompt/output directory, so concurrent runs in different
  Claude Code sessions do not read each other's GPT panelist artifacts.
- For the 3-model panel: the **`agy`** (Antigravity) CLI installed and its keyring seeded — run `agy` once
  interactively to complete the Google OAuth, after which headless runs reuse that login. `run_gemini.sh`
  works around agy's print-mode bug (empty stdout under no TTY) by running it under a pseudo-TTY with a
  transcript-JSONL fallback and a hard anti-empty guard, so it never returns a silently empty answer. The
  pseudo-TTY is allocated by a `pty.fork()` Python helper (`_pty_run.py`) so it keeps working when the
  orchestrator itself runs in a socket (cmux / headless), where `script` aborts on `tcgetattr`.

Only the **`opus4.8-4.8`** panel is truly zero-setup; the GPT-5.5 and Gemini panels light up once their
CLIs are installed and authenticated. Note: there is no `timeout`/`gtimeout` on stock macOS, so the runners
use a self-contained `perl` timeout helper (`FUSION_TIMEOUT`, default 300s per panelist).

## What's in here

```
skills/fusion/
  SKILL.md                  detect → preflight → blind fan-out → judge → grounded final → save
  scripts/
    _fusion_lib.sh          shared helpers: perl-based per-panelist timeout, have()
    _pty_run.py             pty.fork() runner so agy gets a TTY even under socket stdio (cmux/headless)
    detect_panel.sh         picks the richest available panel
    preflight.sh            non-blocking token/call estimate + Codex cap reminder
    run_codex.sh            runs the GPT-5.5 panelist (web + bash) with a timeout, captures its answer
    run_gemini.sh           runs the Gemini 3.1 Pro panelist via agy (pseudo-TTY + transcript fallback)
    save_run.sh             writes the timestamped provenance .md to ~/.claude/fusion-runs/
  references/
    panel.md                why independent parallel runs (no lenses) — the panel mechanism
    judge_rubric.md         the structured analysis + grounded final answer
skills/fusion-plan/
  SKILL.md                  OMC interview → 3-round seeded panel → concise .omc/plans/ → review/execute
commands/
  fusion.md                 /fusion          (composable --models <model@runner,...> panel, any provider)
  fusion-opus4.8.md         /fusion-opus4.8  (pinned opus4.8-4.8 panel)
  fusion-gpt5.5.md          /fusion-gpt5.5   (pinned opus4.8-gpt5.5 panel)
  fusion-gemini.md          /fusion-gemini   (pinned opus4.8-gemini3.1pro panel)
  fusion-3.md               /fusion-3        (pinned full opus4.8-gpt5.5-gemini3.1pro panel)
  fusion-plan.md            /fusion-plan     (OMC-integrated iterative planning; reuses fusion's run_codex.sh)
hooks/
  fusion-plan-nudge.sh      optional PreToolUse backstop (not auto-enabled) — nudges /fusion-plan on spawn
install.sh                  copies the above into ~/.claude (hook copied but left disabled)
```

## Why a panel beats one model

On the DRACO deep-research benchmark, [OpenRouter](https://openrouter.ai/docs/guides/routing/routers/fusion-router)
found that fusing model answers consistently beats the individual models — and that a meaningful chunk of
the lift comes from the *synthesis step itself*, not just from mixing architectures: two independent runs
of one model, synthesized, beat that model run once. Fusion implements that same
independence-then-judge pipeline locally in Claude Code.

## Cost & latency

A panel costs roughly N× a single answer in tokens and runs as slow as its slowest panelist. That's the
deliberate trade: spend more to stop being confidently wrong where that's expensive. For quick or
low-stakes questions, a single direct answer is the right call.

## License

MIT — see [LICENSE](LICENSE).

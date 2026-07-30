---
description: z3Fusion panel of an in-session Claude panelist + Gemini 3.1 Pro in parallel, judged by the orchestrating Claude Code session (claude-gemini3.1pro)
argument-hint: <your question>
---
Invoke the **z3fusion** skill on the task below, forcing the `claude-gemini3.1pro` legacy panel:
an in-session Claude panelist (Agent subagent) and Gemini 3.1 Pro (via `agy`) answer the SAME
prompt IN PARALLEL, each independently with web + bash and neither seeing the other's work → the
orchestrating Claude Code session judges both answers and writes the final answer grounded in the analysis.

The Gemini slot is **hard-pinned to `gemini-3.1-pro-high`** — the runner always passes
`--model gemini-3.1-pro-high` to `agy`, never falls back to Flash, another Pro tier, or agy's configured
default, and fails the panelist outright if that model is unavailable.

Follow the skill's SKILL.md exactly (preflight → fan out in parallel → judge picking the track that fits the
task → grounded final deliverable → save provenance → present). For a research/analysis task present the
standard sections (Consensus / Contradictions / Partial coverage / Unique insights / Blind spots / Final
answer); for a code/artifact task run both candidates and merge them into one working result with a merge
rationale. Use exactly one in-session Claude panelist and one Gemini 3.1 Pro panelist — do NOT add a
GPT-5.6 Sol panelist or a second in-session Claude panelist. Pass the task verbatim to both; no "lenses".

If the `agy` CLI is missing or the Gemini panelist fails/times out, drop it, record a one-line degradation
note, and fall back to `claude-claude` (spawn a second independent in-session Claude panelist) so the judge
still sees two blind answers — never abort because one CLI failed.

If the Claude panelist's `Agent` call returns `Idle.` or another empty/sentinel result, do NOT treat it as
a failed panelist: follow SKILL.md Step 2 and run `scripts/claude_relay.py classify`, then `recover
--agent-id <agentId>` to pull the completed answer back. A recovered panelist is healthy and goes to the
judge like any other; only a genuinely unrecoverable one is dropped.

For a custom panel beyond this fixed 2-model preset — any mix of models, providers, or local runners — use
`/z3fusion --models <model@runner,...> :: <question>` instead.

Task: $ARGUMENTS

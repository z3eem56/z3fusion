---
description: z3Fusion full panel — an in-session Claude panelist + GPT-5.6 Sol + Gemini 3.1 Pro in parallel, judged by the orchestrating Claude Code session (claude-gpt5.6-gemini3.1pro)
argument-hint: <your question>
---
Invoke the **z3fusion** skill on the task below, forcing the richest legacy panel `claude-gpt5.6-gemini3.1pro`:
an in-session Claude panelist (Agent subagent), GPT-5.6 Sol (via `codex exec`), and Gemini 3.1 Pro (via
`agy`, hard-pinned to `gemini-3.1-pro-high`) answer the SAME prompt IN PARALLEL, each independently with
web + bash and none seeing the others' work → the orchestrating Claude Code session judges all three and
writes the final answer grounded in the analysis.

Follow the skill's SKILL.md exactly (preflight → fan out in parallel → judge picking the track that fits
the task → grounded final deliverable → save provenance → present). For a research/analysis task, present
the standard audit-trail sections (Consensus / Contradictions / Partial coverage / Unique insights / Blind
spots); for a code/artifact task, run both candidates and merge them into one working result with a merge
rationale. Pass the task verbatim to all three; no "lenses". Three families, one of each — do not add a
second in-session Claude panelist.

The Gemini slot runs under the **`karpathy-engineering-v1`** engineering governance profile, injected once
by `scripts/run_gemini.sh` from `references/gemini_governance.md` — do not restate it in the panel prompt.
It applies to the Gemini panelist only; the Claude and GPT-5.6 panelists are unaffected. A transient `agy`
timeout is retried **once** automatically at double the timeout; deterministic failures are not retried.

Run `scripts/claude_relay.py normalize --file <relay> --agent-id <agentId> --agent-status completed --out
<canonical>` on the Claude panelist's `Agent` result before judging (SKILL.md Step 2) — a completed
subagent can relay a sentinel wrapped in harness bookkeeping that looks like a real answer. Present per
SKILL.md Step 6: deliverable, then a verbatim `RAW PANEL OUTPUTS` section from
`scripts/render_raw_panel.sh`, then `JUDGE / SYNTHESIS`.

This command targets the FULL panel but degrades gracefully: if `codex` or `agy` is missing or a panelist
fails/times out, drop it, note the degraded panel in the output, and finish with what remains
(`claude-gpt5.6`, then ultimately `claude-claude`) rather than aborting.

For a custom panel beyond this fixed 3-model preset — any mix of models, providers, or local runners — use
`/z3fusion --models <model@runner,...> :: <question>` instead.

Task: $ARGUMENTS

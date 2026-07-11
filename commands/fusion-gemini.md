---
description: Fusion panel of an in-session Claude panelist + Gemini 3.1 Pro in parallel, judged by the orchestrating Claude Code session (opus4.8-gemini3.1pro)
argument-hint: <your question>
---
Invoke the **fusion** skill on the task below, forcing the `opus4.8-gemini3.1pro` legacy panel:
an in-session Claude panelist (Agent subagent) and Gemini 3.1 Pro (via `agy`, pseudo-TTY) answer the SAME
prompt IN PARALLEL, each independently with web + bash and neither seeing the other's work → the
orchestrating Claude Code session judges both answers and writes the final answer grounded in the analysis.

Follow the skill's SKILL.md exactly (preflight → fan out in parallel → judge picking the track that fits the
task → grounded final deliverable → save provenance → present). For a research/analysis task present the
standard sections (Consensus / Contradictions / Partial coverage / Unique insights / Blind spots / Final
answer); for a code/artifact task run both candidates and merge them into one working result with a merge
rationale. Use exactly one in-session Claude panelist and one Gemini 3.1 Pro panelist — do NOT add a
GPT-5.5 panelist or a second in-session Claude panelist. Pass the task verbatim to both; no "lenses".

If the `agy` CLI is missing or the Gemini panelist fails/times out, drop it, record a one-line degradation
note, and fall back to `opus4.8-4.8` (spawn a second independent in-session Claude panelist) so the judge
still sees two blind answers — never abort because one CLI failed.

For a custom panel beyond this fixed 2-model preset — any mix of models, providers, or local runners — use
`/fusion --models <model@runner,...> :: <question>` instead.

Task: $ARGUMENTS

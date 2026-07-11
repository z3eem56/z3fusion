---
description: Fusion full panel — an in-session Claude panelist + GPT-5.5 + Gemini 3.1 Pro in parallel, judged by the orchestrating Claude Code session (opus4.8-gpt5.5-gemini3.1pro)
argument-hint: <your question>
---
Invoke the **fusion** skill on the task below, forcing the richest legacy panel `opus4.8-gpt5.5-gemini3.1pro`:
an in-session Claude panelist (Agent subagent), GPT-5.5 (via `codex exec`), and Gemini 3.1 Pro (via `agy`,
pseudo-TTY) answer the SAME prompt IN PARALLEL, each independently with web + bash and none seeing the
others' work → the orchestrating Claude Code session judges all three and writes the final answer grounded
in the analysis.

Follow the skill's SKILL.md exactly (preflight → fan out in parallel → judge picking the track that fits
the task → grounded final deliverable → save provenance → present). For a research/analysis task, present
the standard audit-trail sections (Consensus / Contradictions / Partial coverage / Unique insights / Blind
spots); for a code/artifact task, run both candidates and merge them into one working result with a merge
rationale. Pass the task verbatim to all three; no "lenses". Three families, one of each — do not add a
second in-session Claude panelist.

This command targets the FULL panel but degrades gracefully: if `codex` or `agy` is missing or a panelist
fails/times out, drop it, note the degraded panel in the output, and finish with what remains
(`opus4.8-gpt5.5`, then ultimately `opus4.8-4.8`) rather than aborting.

For a custom panel beyond this fixed 3-model preset — any mix of models, providers, or local runners — use
`/fusion --models <model@runner,...> :: <question>` instead.

Task: $ARGUMENTS

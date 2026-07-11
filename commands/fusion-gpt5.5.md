---
description: Fusion panel of an in-session Claude panelist + GPT-5.5 in parallel, judged by the orchestrating Claude Code session (opus4.8-gpt5.5)
argument-hint: <your question>
---
Invoke the **fusion** skill on the task below, forcing the `opus4.8-gpt5.5` legacy panel:
an in-session Claude panelist (Agent subagent) and GPT-5.5 (via `codex exec`) answer the SAME prompt IN
PARALLEL, each independently with web + bash and neither seeing the other's work → the orchestrating Claude
Code session judges both answers and writes the final answer grounded in the analysis.

Follow the skill's SKILL.md exactly (fan out in parallel → judge → grounded final answer) and present the
standard sections (Consensus / Contradictions / Partial coverage / Unique insights / Blind spots / Final
answer). Use exactly one in-session Claude panelist and one GPT-5.5 panelist — do not add a Gemini panelist
or a second in-session Claude panelist. Pass the task verbatim to both; no "lenses". If the `codex` CLI is
not installed, stop and say so rather than silently downgrading to the opus4.8-4.8 panel.

For a custom panel beyond this fixed 2-model preset — any mix of models, providers, or local runners — use
`/fusion --models <model@runner,...> :: <question>` instead.

Task: $ARGUMENTS

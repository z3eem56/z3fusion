---
description: z3Fusion panel of two independent in-session Claude runs, judged by the orchestrating Claude Code session (claude-claude)
argument-hint: <your question>
---
Invoke the **z3fusion** skill on the task below, forcing the `claude-claude` legacy panel:
run the same prompt twice as TWO independent in-session Claude panelists (Agent subagents, in parallel,
neither seeing the other's work) → the orchestrating Claude Code session judges both answers and writes the
final answer grounded in the analysis.

Follow the skill's SKILL.md exactly (fan out in parallel → judge → grounded final answer) and present the
standard sections (Consensus / Contradictions / Partial coverage / Unique insights / Blind spots / Final
answer). Do NOT add a GPT-5.6 Sol or Gemini panelist, even if codex/gemini are installed — this command is
pinned to the pure in-session-Claude panel. Do not assign the two runs any "lenses" — pass the task
verbatim to both.

For a custom panel beyond this fixed 2-run preset — any mix of models, providers, or local runners — use
`/z3fusion --models <model@runner,...> :: <question>` instead.

Task: $ARGUMENTS

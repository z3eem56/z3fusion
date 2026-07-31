#!/usr/bin/env python3
"""claude_relay.py — normalize, validate and (when needed) recover a Claude panelist's answer.

WHY THIS EXISTS
---------------
An `Agent` tool call can come back `status: completed`, with real token spend and real tool
use, while the text relayed to the orchestrator is not the answer at all. Two things go wrong,
and they compound:

1. A `SubagentStop` hook re-wakes an already-finished subagent. The agent answered the task
   properly on its first turn, then produced progressively shorter replies to the spurious
   wake-ups, and finally a sentinel — `Idle.`, or "No new input received. I'll stop responding
   to these repeated hook notifications." The Agent tool faithfully returns the agent's LAST
   message. The real answer is not lost; it is in the subagent's own transcript.

2. The harness wraps that relay in its own bookkeeping — a `SECURITY WARNING:` block, the
   `agentId: … (use SendMessage …)` trailer, a `<usage>` element — and glues them onto the
   SAME LINE as the sentinel, with no separators. Observed verbatim (734 chars, one line):

       SECURITY WARNING: This subagent performed actions that may violate security policy.
       Reason: [Credential Exploration] … Review the subagent's actions carefully before
       acting on its output.No new input received. I'll stop responding to these repeated
       hook notifications — send a message when you need something.agentId: a2818ce2f1ab27992
       (use SendMessage with to: '…', summary: '<5-10 word recap>' to continue this agent)
       <usage>subagent_tokens: 58588 …</usage>

   Classifying THAT string as a whole says "normal": it is long, it is prose-shaped, and no
   single line is pure metadata. The wrapper made a sentinel look healthy. That is exactly the
   false positive this module now prevents.

So classification happens on the ANSWER, not on the envelope:

    raw relay -> strip_wrappers() -> residual -> classify_answer() -> normal | suspicious
                                                                        |
                                                      suspicious -> recover from transcript

Stripping is structural and anchored to the shapes the harness actually emits. Prose that
merely mentions "security", "warning", "agent" or "tool" matches none of these patterns and is
never touched.

RECOVERY IS KEYED ON AUTHORITATIVE METADATA
-------------------------------------------
The Agent tool result carries `agentId` (it is also echoed in the relayed text as
"agentId: <id>"). Claude Code stores that subagent's full transcript at:

    ~/.claude/projects/<encoded-cwd>/<parent-session-id>/subagents/agent-<agentId>.jsonl

so the transcript is located by exact agent id, never by reconstructing a guessed path.

USAGE
-----
  claude_relay.py normalize --file <relay_file> --out <canonical_file> [--agent-id <id>]
      The one call the orchestrator needs. Strips wrappers, classifies, recovers if
      suspicious, and writes the CANONICAL panel result plus <canonical_file>.provenance.json.
      exit 0 = <canonical_file> holds a validated answer (normal or recovered)
      exit 1 = no usable answer exists -> fail the panelist

  claude_relay.py classify --file <relayed_text_file> | --text "<relayed text>"
      exit 0 = the relayed result looks like a real answer ("normal")
      exit 3 = suspicious (empty / sentinel / wrapper-only / metadata-only / too short)

  claude_relay.py recover --agent-id <id> --out <file> [--agent-status completed]
      exit 0 = recovered (answer written to <file>, provenance to <file>.provenance.json)
      exit 1 = nothing recoverable -> the caller must fail the panelist

Biasing towards "attempt recovery" is deliberate and cheap: a short-but-genuine answer that
trips a heuristic simply round-trips through recovery unchanged, because recovery returns the
agent's own most complete message. A false "normal", by contrast, silently feeds a sentinel to
the judge — which is the failure that actually costs something.

LIMITS, STATED PLAINLY
----------------------
Sentinel detection is pattern-based on the wake-up-reply shapes actually observed, and a novel
phrasing can still slip through as "normal". That is why it is not the only line of defence:
`render_raw_panel.sh` re-classifies each canonical result when rendering and prints a visible
WARNING if one still looks degenerate, so a miss surfaces in the output instead of quietly
becoming the panel's answer. Two rules already had to be widened after a live counter-example —
expect that to happen again, and add the shape rather than loosening the gates.
"""
import argparse
import glob
import json
import os
import re
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

DEFAULT_PROJECTS_DIR = Path(os.path.expanduser("~")) / ".claude" / "projects"

# A relayed answer shorter than this is treated as suspicious and triggers a recovery attempt.
DEFAULT_MIN_CHARS = 40

# Sentinel phrasings are only credited as sentinels on a SHORT payload. A long answer that
# happens to quote one of them (documentation of this very failure mode, for instance) is
# never affected — which is what keeps requirement "don't strip legitimate security prose"
# structurally true rather than merely intended.
SENTINEL_MAX_CHARS = 400

# Statuses that mean the agent actually finished. Anything else must NOT be recovered from,
# because a still-running agent's transcript may hold only partial output.
COMPLETE_STATUSES = {"completed", "complete", "success", "succeeded", "done"}

# ---------------------------------------------------------------------------------------
# Wrapper stripping — harness envelope, never answer content
# ---------------------------------------------------------------------------------------
# Each entry is (wrapper_type, compiled_pattern). Every pattern is anchored to a literal
# harness shape: a leading `SECURITY WARNING:` block that closes on its own fixed sentence,
# the `agentId: … (use SendMessage …)` trailer, an XML `<usage>` / `<system-reminder>`
# element, a hook-notification line, a bare agent-status line. Free prose matches none of them.
_WRAPPERS = [
    # The security preamble. Primary branch runs to the harness's own closing sentence; the
    # bounded {0,2000} stops a stray later occurrence of that sentence from eating an answer.
    # Fallback branch (wording changed) takes the rest of the LINE only — and if that swallows
    # a one-line answer, the residual becomes empty, which classifies as `wrapper-only` and
    # routes to transcript recovery. It fails safe, never silently.
    ("security-warning", re.compile(
        r"^\s*SECURITY\s+WARNING\s*:\s*"
        r"(?:.{0,2000}?before acting on its output\.|[^\n]*)\s*",
        re.IGNORECASE | re.DOTALL)),
    # "agentId: abc123 (use SendMessage with to: '…', summary: '…' to continue this agent)"
    ("agent-id-trailer", re.compile(
        r"\s*agentId\s*:\s*\S+\s*\(\s*use\s+SendMessage[^)]*\)\s*",
        re.IGNORECASE)),
    # the same trailer without the parenthetical, on its own line
    ("agent-id-trailer", re.compile(r"^[ \t]*agentId\s*:\s*\S+[ \t]*$\n?",
                                    re.IGNORECASE | re.MULTILINE)),
    ("usage-block", re.compile(r"\s*<usage>.*?</usage>\s*", re.IGNORECASE | re.DOTALL)),
    ("system-reminder", re.compile(r"\s*<system-reminder>.*?</system-reminder>\s*",
                                   re.IGNORECASE | re.DOTALL)),
    # "SubagentStop hook … completed successfully: {…}", "PostToolUse:Bash hook …"
    ("hook-notice", re.compile(
        r"^[ \t]*(?:PreToolUse|PostToolUse|PostToolUseFailure|SubagentStop|Stop|SessionStart|"
        r"UserPromptSubmit|PreCompact|Notification)\b[^\n]*\bhook\b[^\n]*$\n?",
        re.IGNORECASE | re.MULTILINE)),
    # "[Agent completed]" / "Subagent finished."
    ("agent-status", re.compile(
        r"^[ \t]*\[?(?:sub)?agent\s+(?:has\s+)?"
        r"(?:completed|complete|finished|stopped|terminated|exited)\b[^\n]*\]?[ \t]*$\n?",
        re.IGNORECASE | re.MULTILINE)),
]

# Exact-match status words that are never a real deliverable.
_EXACT_SENTINELS = {
    "idle", "done", "ok", "okay", "complete", "completed", "finished",
    "acknowledged", "ack", "n/a", "na", "none", "(no content)", "no content",
    "no action", "no actions", "no change", "no changes", "no output", "no response",
    "nothing to do", "standing by",
}

# "Idle. Waiting on you." / "Idle. No new input — ..." are all the same sentinel.
_IDLE_PREFIX = re.compile(r"^idle\b", re.IGNORECASE)

# Openers no deliverable ever begins with — including the phrasings an agent uses when it is
# answering a spurious SubagentStop wake-up instead of delivering work. Deliberately
# START-ANCHORED and gated on SENTINEL_MAX_CHARS: a searched-anywhere version flagged a real
# 383-char answer that merely *quoted* "no new input received" while explaining this very
# failure mode. Anchoring is what makes "don't misclassify legitimate prose" structural.
_SENTINEL_OPENERS = re.compile(
    r"^(?:"
    r"no\s+(?:new\s+)?(?:input|action|actions|message|messages|instruction|instructions|"
    r"task|tasks|request|requests|update|updates|change|changes|content|output|response)\b"
    r"|nothing\s+(?:to\s+do|to\s+add|to\s+report|further|new|else|has\s+changed)\b"
    r"|still\s+(?:here|idle|waiting|standing\s+by)\b"
    r"|standing\s+by\b"
    r"|awaiting\s+"
    r"|waiting\s+(?:for|on)\b"
    r"|i'?m\s+(?:idle|done|finished|standing\s+by)\b"
    r")", re.IGNORECASE)

# The other shape a wake-up-loop reply takes: FIRST-PERSON commentary about the agent's own
# responding, rather than an answer to the task. Observed live, verbatim:
#   "I've now delivered this answer six times in response to repeated stop-hook notices that
#    contain no new request. I'm going to stop repeating it. The work is done and the
#    deliverable is in the transcript above — the parent agent should relay that paragraph."
# 250 chars, prose-shaped, no `Idle.`, no sentinel opener — it defeats every rule above. What
# makes it structural rather than lexical is the first person: an ANSWER never reports on its
# own delivery. Every alternative below is therefore anchored to "I", and all of them are gated
# on SENTINEL_MAX_CHARS, so an essay about this failure mode is unaffected.
_SELF_REPORT_STOP = re.compile(
    r"^i(?:'ve|\s+have)\s+(?:\w+\s+){0,2}(?:already\s+)?"
    r"(?:answered|delivered|provided|given|sent|posted|repeated|said)\b"
    r"|\bi(?:'m|\s+am)\s+(?:going\s+to\s+)?stop(?:ping)?\s+(?:responding|repeating|replying)\b"
    r"|\bi(?:'ll|\s+will)\s+stop\s+(?:responding|repeating|replying)\b",
    re.IGNORECASE)

# A line that is nothing but harness bookkeeping (used for the all-lines metadata check).
_METADATA_LINE = re.compile(
    r"^\s*agentid\s*:\s*\S+.*$|^\s*<usage>.*</usage>\s*$",
    re.IGNORECASE | re.DOTALL)


def strip_wrappers(text):
    """Remove harness/security/status envelopes from a relayed Agent result.

    Returns (residual, [wrapper_type, ...]) with the residual stripped of surrounding
    whitespace. Order-independent: every pattern is anchored, so applying them in sequence
    cannot cascade into answer content.
    """
    if not text:
        return "", []
    residual = text
    found = []
    for name, pattern in _WRAPPERS:
        new = pattern.sub("", residual)
        if new != residual:
            found.append(name)
            residual = new
    # dedupe, preserving order (the agentId trailer has two spellings)
    return residual.strip(), list(dict.fromkeys(found))


def classify_answer(residual, min_chars=DEFAULT_MIN_CHARS, had_wrappers=False):
    """Classify an already-unwrapped payload. None => it looks like a real answer."""
    if residual is None:
        return "empty"
    stripped = residual.strip()
    if not stripped:
        return "wrapper-only" if had_wrappers else "empty"

    flat = stripped.rstrip(".!。 ").strip().lower()
    if flat in _EXACT_SENTINELS:
        return "idle-sentinel" if flat == "idle" else "status-sentinel"
    if _IDLE_PREFIX.match(stripped):
        return "idle-sentinel"

    if len(stripped) <= SENTINEL_MAX_CHARS and (
            _SENTINEL_OPENERS.match(stripped) or _SELF_REPORT_STOP.search(stripped)):
        return "wakeup-sentinel"

    # Metadata-only relay: every line is harness bookkeeping.
    lines = [ln for ln in stripped.splitlines() if ln.strip()]
    if lines and all(_METADATA_LINE.match(ln) for ln in lines):
        return "metadata-only"

    if len(stripped) < min_chars:
        return "too-short"
    return None


def classify(text, min_chars=DEFAULT_MIN_CHARS):
    """Strip the harness envelope, then judge the answer. None => real answer."""
    residual, wrappers = strip_wrappers(text)
    return classify_answer(residual, min_chars, bool(wrappers))


def find_transcript(agent_id, projects_dir):
    """Locate agent-<agent_id>.jsonl by exact id. Newest wins if an id somehow repeats."""
    pattern = os.path.join(str(projects_dir), "*", "*", "subagents", f"agent-{agent_id}.jsonl")
    matches = sorted(glob.glob(pattern), key=lambda p: os.path.getmtime(p), reverse=True)
    return matches[0] if matches else None


def assistant_texts(transcript_path):
    """Ordered list of the subagent's own assistant text messages."""
    out = []
    with open(transcript_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if not isinstance(rec, dict) or rec.get("type") != "assistant":
                continue
            msg = rec.get("message")
            if not isinstance(msg, dict) or msg.get("role") != "assistant":
                continue
            content = msg.get("content")
            if isinstance(content, str):
                if content.strip():
                    out.append(content)
                continue
            if not isinstance(content, list):
                continue
            parts = [
                blk.get("text", "") for blk in content
                if isinstance(blk, dict) and blk.get("type") == "text"
            ]
            joined = "".join(parts)
            if joined.strip():
                out.append(joined)
    return out


def last_record_is_assistant(transcript_path):
    """True when the transcript ends on an assistant turn (not mid tool call)."""
    last = None
    with open(transcript_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if isinstance(rec, dict) and rec.get("type") in ("assistant", "user"):
                last = rec
    return bool(last) and last.get("type") == "assistant"


def recover_answer(agent_id, agent_status, projects_dir, min_chars, provenance):
    """Pull a completed subagent's best answer out of its own transcript.

    Returns (answer, None) on success or (None, reason) on failure. `provenance` is updated
    in place with what was inspected, so a failure is as auditable as a success.
    """
    status = (agent_status or "").strip().lower()
    if status and status not in COMPLETE_STATUSES:
        return None, f"agent did not complete (status={status!r}); refusing to read partial output"

    transcript = find_transcript(agent_id, projects_dir)
    if not transcript:
        return None, f"no transcript found for agent {agent_id}"
    provenance["transcript"] = transcript

    if not last_record_is_assistant(transcript):
        return None, f"agent {agent_id} transcript does not end on a completed assistant turn"

    texts = assistant_texts(transcript)
    if not texts:
        return None, f"agent {agent_id} transcript holds no assistant output"

    candidates = [t for t in texts if classify(t, min_chars) is None]
    provenance["assistant_messages"] = len(texts)
    provenance["candidates"] = len(candidates)
    if not candidates:
        return None, (f"agent {agent_id} produced no substantive output "
                      f"({len(texts)} assistant message(s), all sentinel/degenerate)")

    # Pick the LONGEST surviving candidate. In a normal transcript there is exactly one, so
    # this is the final message. Under the re-prompt loop this script exists for, the real
    # deliverable comes first and every later reply is a shorter restatement, so the longest
    # candidate is the panelist's most complete answer either way.
    return max(candidates, key=len), None


def _read_relay(args):
    """Return (text, error). A file that cannot be read is a suspicious relay, not a crash."""
    if getattr(args, "file", None):
        try:
            return Path(args.file).read_text(encoding="utf-8", errors="replace"), None
        except Exception as exc:
            return None, f"unreadable ({exc})"
    return (args.text or ""), None


def _write_answer(out, answer):
    out_path = Path(out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(answer.strip() + "\n", encoding="utf-8")


def _write_provenance(out, doc):
    try:
        path = Path(str(out) + ".provenance.json")
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2)
            fh.write("\n")
    except Exception:
        pass


def cmd_classify(args):
    text, err = _read_relay(args)
    if err:
        print(f"suspicious:{err}")
        return 3
    residual, wrappers = strip_wrappers(text)
    if wrappers:
        sys.stderr.write(
            f"claude_relay: stripped harness wrapper(s) before classifying: "
            f"{','.join(wrappers)} ({len(text)} -> {len(residual)} chars)\n")
    reason = classify_answer(residual, args.min_chars, bool(wrappers))
    if reason:
        print(f"suspicious:{reason}")
        return 3
    print("normal")
    return 0


def cmd_recover(args):
    # Prefer deriving the anomaly from what was actually relayed, so provenance names the real
    # symptom ("wakeup-sentinel", "metadata-only", ...) instead of a caller-supplied guess.
    anomaly = args.relay_anomaly
    if args.relayed_text is not None:
        anomaly = classify(args.relayed_text, args.min_chars) or "none"

    provenance = {
        "result_transport": "recovered-task-output",
        "relay_anomaly": anomaly,
        "agent_id": args.agent_id,
        "healthy": False,
    }
    if args.relayed_text is not None:
        _, wrappers = strip_wrappers(args.relayed_text)
        provenance["relay_wrapper_detected"] = bool(wrappers)
        provenance["relay_wrapper_type"] = ",".join(wrappers) or None

    answer, reason = recover_answer(
        args.agent_id, args.agent_status, args.projects_dir, args.min_chars, provenance)
    if answer is None:
        provenance["failure_reason"] = reason
        provenance["result_transport"] = "none"
        _write_provenance(args.out, provenance)
        sys.stderr.write(f"claude_relay: {reason}\n")
        return 1

    _write_answer(args.out, answer)
    provenance["healthy"] = True
    provenance["chars"] = len(answer.strip())
    _write_provenance(args.out, provenance)
    sys.stderr.write(
        f"claude_relay: recovered {len(answer.strip())} chars for agent {args.agent_id} "
        f"from {provenance.get('transcript')}\n")
    return 0


def cmd_normalize(args):
    """Raw relay -> canonical panel result, in one call.

    This is the whole pipeline the orchestrator is supposed to run, in a single command, so a
    sentinel can never reach the judge because a two-step procedure was only half-followed.
    """
    text, err = _read_relay(args)
    provenance = {
        "relay_wrapper_detected": False,
        "relay_wrapper_type": None,
        "relay_classification": "suspicious",
        "relay_anomaly": None,
        "result_transport": "none",
        "agent_id": args.agent_id or None,
        "healthy": False,
    }
    if err:
        provenance["relay_anomaly"] = err
        provenance["failure_reason"] = f"could not read the relayed result: {err}"
        _write_provenance(args.out, provenance)
        sys.stderr.write(f"claude_relay: {provenance['failure_reason']}\n")
        return 1

    residual, wrappers = strip_wrappers(text)
    provenance["relay_wrapper_detected"] = bool(wrappers)
    provenance["relay_wrapper_type"] = ",".join(wrappers) or None

    reason = classify_answer(residual, args.min_chars, bool(wrappers))
    provenance["relay_anomaly"] = reason
    provenance["relay_classification"] = "suspicious" if reason else "normal"

    if not reason:
        # Healthy relay. The canonical result is the ANSWER, without the harness envelope —
        # the envelope is not the panelist's work and must not reach the judge or the raw
        # panel output. When anything was stripped the untouched original is kept alongside,
        # so nothing is discarded silently.
        _write_answer(args.out, residual)
        if wrappers:
            raw_path = Path(str(args.out) + ".raw")
            raw_path.parent.mkdir(parents=True, exist_ok=True)
            raw_path.write_text(text, encoding="utf-8")
            provenance["raw_relay_path"] = str(raw_path)
            sys.stderr.write(
                f"claude_relay: stripped harness wrapper(s) {','.join(wrappers)}; "
                f"untouched relay kept at {raw_path}\n")
        provenance["result_transport"] = "normal"
        provenance["healthy"] = True
        provenance["chars"] = len(residual)
        _write_provenance(args.out, provenance)
        print("normal")
        return 0

    # Suspicious: the relay is an envelope, a sentinel, or both. The answer, if it exists, is
    # in the subagent's own transcript.
    if not args.agent_id:
        provenance["failure_reason"] = (
            f"relay is {reason} and no --agent-id was supplied, so the completed task output "
            f"cannot be recovered")
        _write_provenance(args.out, provenance)
        sys.stderr.write(f"claude_relay: {provenance['failure_reason']}\n")
        print(f"suspicious:{reason}")
        return 1

    answer, failure = recover_answer(
        args.agent_id, args.agent_status, args.projects_dir, args.min_chars, provenance)
    if answer is None:
        provenance["failure_reason"] = failure
        _write_provenance(args.out, provenance)
        sys.stderr.write(f"claude_relay: {failure}\n")
        print(f"suspicious:{reason}")
        return 1

    _write_answer(args.out, answer)
    provenance["result_transport"] = "recovered-task-output"
    provenance["healthy"] = True
    provenance["chars"] = len(answer.strip())
    _write_provenance(args.out, provenance)
    sys.stderr.write(
        f"claude_relay: relay was {reason}"
        + (f" (wrappers: {','.join(wrappers)})" if wrappers else "")
        + f"; recovered {len(answer.strip())} chars for agent {args.agent_id} "
          f"from {provenance.get('transcript')}\n")
    print("recovered-task-output")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    n = sub.add_parser("normalize",
                       help="raw relay -> validated canonical panel result (strip, classify, recover)")
    nsrc = n.add_mutually_exclusive_group(required=True)
    nsrc.add_argument("--file")
    nsrc.add_argument("--text")
    n.add_argument("--out", required=True)
    n.add_argument("--agent-id", default="",
                   help="agentId from the Agent tool result; required to recover a suspicious relay")
    n.add_argument("--agent-status", default="",
                   help="status from the Agent tool result; recovery refuses unless complete")
    n.add_argument("--min-chars", type=int, default=DEFAULT_MIN_CHARS)
    n.add_argument("--projects-dir", default=str(DEFAULT_PROJECTS_DIR))
    n.set_defaults(func=cmd_normalize)

    c = sub.add_parser("classify", help="is a relayed Agent result a real answer?")
    src = c.add_mutually_exclusive_group(required=True)
    src.add_argument("--file")
    src.add_argument("--text")
    c.add_argument("--min-chars", type=int, default=DEFAULT_MIN_CHARS)
    c.set_defaults(func=cmd_classify)

    r = sub.add_parser("recover", help="recover a completed subagent's answer by agent id")
    r.add_argument("--agent-id", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--agent-status", default="",
                   help="status from the Agent tool result; recovery refuses unless complete")
    r.add_argument("--relay-anomaly", default="idle-sentinel",
                   help="anomaly label for provenance when --relayed-text is not supplied")
    r.add_argument("--relayed-text", default=None,
                   help="the text the Agent tool actually returned; the anomaly is derived from it")
    r.add_argument("--min-chars", type=int, default=DEFAULT_MIN_CHARS)
    r.add_argument("--projects-dir", default=str(DEFAULT_PROJECTS_DIR))
    r.set_defaults(func=cmd_recover)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

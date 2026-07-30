#!/usr/bin/env python3
"""claude_relay.py — validate and, when needed, recover an in-session Claude panelist's answer.

WHY THIS EXISTS
---------------
An `Agent` tool call can come back `status: completed`, with real token spend and real tool
use, while the text relayed to the orchestrator is just a degenerate sentinel such as:

    Idle.

Observed cause: a `SubagentStop` hook re-woke an already-finished subagent several times. The
agent answered the task properly on its first turn, then produced progressively shorter
replies to the spurious wake-ups, and finally `Idle.`. The Agent tool faithfully returns the
agent's LAST message — by then the sentinel. The real answer is not lost; it is in the
subagent's own transcript.

Without recovery, z3Fusion would judge a healthy panelist as empty/absent and synthesize from
incomplete evidence. That is the failure this script prevents.

RECOVERY IS KEYED ON AUTHORITATIVE METADATA
-------------------------------------------
The Agent tool result carries `agentId` (it is also echoed in the relayed text as
"agentId: <id>"). Claude Code stores that subagent's full transcript at:

    ~/.claude/projects/<encoded-cwd>/<parent-session-id>/subagents/agent-<agentId>.jsonl

so the transcript is located by exact agent id, never by reconstructing a guessed path.

USAGE
-----
  claude_relay.py classify --file <relayed_text_file>
  claude_relay.py classify --text "<relayed text>"
      exit 0 = the relayed result looks like a real answer ("normal")
      exit 3 = suspicious (empty / whitespace / Idle. / sentinel / metadata-only / too short)

  claude_relay.py recover --agent-id <id> --out <file> [--agent-status completed]
      exit 0 = recovered (answer written to <file>, provenance to <file>.provenance.json)
      exit 1 = nothing recoverable -> the caller must fail the panelist

A short-but-genuine answer that trips the length heuristic simply round-trips through
recovery unchanged, so biasing towards "attempt recovery" costs nothing but a file read.
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

# Statuses that mean the agent actually finished. Anything else must NOT be recovered from,
# because a still-running agent's transcript may hold only partial output.
COMPLETE_STATUSES = {"completed", "complete", "success", "succeeded", "done"}

# Exact-match status words that are never a real deliverable.
_EXACT_SENTINELS = {
    "idle", "done", "ok", "okay", "complete", "completed", "finished",
    "acknowledged", "ack", "n/a", "na", "none", "(no content)", "no content",
}

# "Idle. Waiting on you." / "Idle. No new input — ..." are all the same sentinel.
_IDLE_PREFIX = re.compile(r"^idle\b", re.IGNORECASE)

# The harness's own bookkeeping block, e.g. "agentId: abc123 (use SendMessage ...) <usage>...".
_METADATA_ONLY = re.compile(
    r"^\s*agentid\s*:\s*\S+.*$|^\s*<usage>.*</usage>\s*$",
    re.IGNORECASE | re.DOTALL,
)


def classify(text, min_chars=DEFAULT_MIN_CHARS):
    """Return None when the text looks like a real answer, else a short reason string."""
    if text is None:
        return "empty"
    stripped = text.strip()
    if not stripped:
        return "empty" if text == "" else "whitespace-only"

    flat = stripped.rstrip(".!。 ").strip().lower()
    if flat in _EXACT_SENTINELS:
        return "idle-sentinel" if flat == "idle" else "status-sentinel"
    if _IDLE_PREFIX.match(stripped):
        return "idle-sentinel"

    # Metadata-only relay: every line is harness bookkeeping.
    lines = [ln for ln in stripped.splitlines() if ln.strip()]
    if lines and all(_METADATA_ONLY.match(ln) for ln in lines):
        return "metadata-only"

    if len(stripped) < min_chars:
        return "too-short"
    return None


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


def cmd_classify(args):
    if args.file:
        try:
            text = Path(args.file).read_text(encoding="utf-8", errors="replace")
        except Exception as exc:
            print(f"suspicious:unreadable ({exc})")
            return 3
    else:
        text = args.text or ""
    reason = classify(text, args.min_chars)
    if reason:
        print(f"suspicious:{reason}")
        return 3
    print("normal")
    return 0


def cmd_recover(args):
    # Prefer deriving the anomaly from what was actually relayed, so provenance names the real
    # symptom ("too-short", "metadata-only", ...) instead of a caller-supplied guess.
    anomaly = args.relay_anomaly
    if args.relayed_text is not None:
        anomaly = classify(args.relayed_text, args.min_chars) or "none"

    provenance = {
        "result_transport": "recovered-task-output",
        "relay_anomaly": anomaly,
        "agent_id": args.agent_id,
        "healthy": False,
    }

    def bail(reason, code=1):
        provenance["failure_reason"] = reason
        provenance["result_transport"] = "none"
        _write_provenance(args.out, provenance)
        sys.stderr.write(f"claude_relay: {reason}\n")
        return code

    status = (args.agent_status or "").strip().lower()
    if status and status not in COMPLETE_STATUSES:
        return bail(f"agent did not complete (status={status!r}); refusing to read partial output")

    transcript = find_transcript(args.agent_id, args.projects_dir)
    if not transcript:
        return bail(f"no transcript found for agent {args.agent_id}")
    provenance["transcript"] = transcript

    if not last_record_is_assistant(transcript):
        return bail(f"agent {args.agent_id} transcript does not end on a completed assistant turn")

    texts = assistant_texts(transcript)
    if not texts:
        return bail(f"agent {args.agent_id} transcript holds no assistant output")

    candidates = [t for t in texts if classify(t, args.min_chars) is None]
    provenance["assistant_messages"] = len(texts)
    provenance["candidates"] = len(candidates)
    if not candidates:
        return bail(
            f"agent {args.agent_id} produced no substantive output "
            f"({len(texts)} assistant message(s), all sentinel/degenerate)")

    # Pick the LONGEST surviving candidate. In a normal transcript there is exactly one, so
    # this is the final message. Under the re-prompt loop this script exists for, the real
    # deliverable comes first and every later reply is a shorter restatement, so the longest
    # candidate is the panelist's most complete answer either way.
    answer = max(candidates, key=len)

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(answer.strip() + "\n", encoding="utf-8")

    provenance["healthy"] = True
    provenance["chars"] = len(answer.strip())
    _write_provenance(args.out, provenance)
    sys.stderr.write(
        f"claude_relay: recovered {len(answer.strip())} chars for agent {args.agent_id} "
        f"from {transcript}\n")
    return 0


def _write_provenance(out, doc):
    try:
        path = Path(str(out) + ".provenance.json")
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2)
            fh.write("\n")
    except Exception:
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

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

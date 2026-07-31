#!/usr/bin/env bash
# render_raw_panel.sh — render the RAW PANEL OUTPUTS section of a z3Fusion result.
#
# Usage:
#   render_raw_panel.sh <label=path> [<label=path> ...]
#
# Prints, to stdout, a block the orchestrator pastes VERBATIM into the final answer, above the
# judge's analysis. Its whole purpose is that the operator can see what each panelist actually
# produced instead of the judge's summary of it — an answer that only says "Gemini agreed" is
# unauditable, and a judge that quietly paraphrases a panelist cannot be checked.
#
# For each panelist it prints:
#   - the model identity, backend, whether the model pin was verified, and the transport the
#     answer arrived on, read from <path>.provenance.json (the runner's own record, not a
#     claim made in the answer text);
#   - the canonical answer verbatim, or — past FUSION_RAW_PREVIEW_CHARS — a bounded preview
#     with an explicit truncation banner naming the character count and the on-disk artifact.
#     Nothing is ever silently shortened, and the complete artifact always stays on disk.
#
# It reads the CANONICAL result file, so a Claude panelist whose relay was recovered shows the
# recovered answer, never the sentinel it replaced. If a file still classifies as a degenerate
# relay, that is called out inline rather than displayed as if it were healthy.
#
# Env:
#   FUSION_RAW_PREVIEW_CHARS  preview budget per panelist in characters (default 4000).
#
# Exit codes: 0 rendered | 2 bad usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_fusion_lib.sh"

if [ "$#" -lt 1 ]; then
  echo "usage: render_raw_panel.sh <label=path> [<label=path> ...]" >&2
  exit 2
fi

# Normalize each path to a spelling the interpreter can actually open. MSYS rewrites POSIX
# paths in argv on the way into a native python.exe, but only when the argument LOOKS like a
# path — a `label=path` pair whose label contains spaces or parentheses defeats that heuristic
# and Python then gets an unopenable "/tmp/..." (observed: every panelist rendering as MISSING).
# `cygpath -m` gives C:/... with forward slashes, which both Windows and MSYS bash accept.
specs=()
for spec in "$@"; do
  label="${spec%%=*}"
  path="${spec#*=}"
  if [ -n "$path" ] && [ "$path" != "$spec" ] && have cygpath; then
    path="$(cygpath -m "$path" 2>/dev/null || printf '%s' "$path")"
  fi
  specs+=( "$label=$path" )
done

PREVIEW_CHARS="${FUSION_RAW_PREVIEW_CHARS:-4000}" RELAY_DIR="$SCRIPT_DIR" \
"$FUSION_PY" - "${specs[@]}" <<'PYEOF'
import json
import os
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

sys.path.insert(0, os.environ["RELAY_DIR"])
try:
    from claude_relay import classify
except Exception:                                     # never let a lint break the render
    def classify(_text):
        return None

try:
    PREVIEW = max(200, int(os.environ.get("PREVIEW_CHARS", "4000")))
except ValueError:
    PREVIEW = 4000

RULE = "=" * 50


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except Exception:
        return None


def provenance(path):
    try:
        with open(path + ".provenance.json", encoding="utf-8") as fh:
            doc = json.load(fh)
        return doc if isinstance(doc, dict) else {}
    except Exception:
        return {}


def identity(prov):
    """Lines describing WHO answered and HOW the answer arrived, from the runner's record."""
    lines = []
    backend = prov.get("backend") or prov.get("runtime_backend")
    if not backend and prov.get("result_transport"):
        backend = "in-session Claude Agent subagent"
    if backend:
        lines.append(f"- Backend: {backend}")
    if prov.get("model"):
        lines.append(f"- Model: {prov['model']}")
    if "model_pin_verified" in prov:
        lines.append(f"- Model verified: {str(prov['model_pin_verified']).lower()}"
                     + (f" (routed: {prov['routed_model_label']})"
                        if prov.get("routed_model_label") else ""))
    if prov.get("output_transport"):
        lines.append(f"- Transport: {prov['output_transport']}")
    if prov.get("result_transport"):
        lines.append(f"- Result transport: {prov['result_transport']}")
    if prov.get("relay_classification"):
        note = f"- Relay: {prov['relay_classification']}"
        if prov.get("relay_anomaly"):
            note += f" ({prov['relay_anomaly']})"
        if prov.get("relay_wrapper_detected"):
            note += f", harness wrapper stripped: {prov.get('relay_wrapper_type')}"
        lines.append(note)
    if prov.get("attempts") and prov["attempts"] > 1:
        lines.append(f"- Attempts: {prov['attempts']} (retry reason: {prov.get('retry_reason')})")
    if prov.get("governance_profile"):
        lines.append(f"- Governance profile: {prov['governance_profile']}")
    return lines


print(RULE)
print("RAW PANEL OUTPUTS")
print(RULE)

for spec in sys.argv[1:]:
    label, _, path = spec.partition("=")
    label = label.strip() or "(unlabelled)"
    path = path.strip()
    content = read(path) if path else None
    prov = provenance(path) if path else {}

    print()
    print(f"### [{label}]")
    for line in identity(prov):
        print(line)

    if content is None or not content.strip():
        print(f"- Artifact: {path or '(none)'} — MISSING OR EMPTY")
        print()
        print("_(no output — this panelist was dropped; the judge treats it as absent, "
              "never as agreement)_")
        continue

    body = content.strip()
    chars = len(body)
    nbytes = len(body.encode("utf-8"))
    truncated = chars > PREVIEW
    print(f"- Artifact: {path} ({chars} characters, {nbytes} bytes)"
          + (" — PREVIEW TRUNCATED BELOW" if truncated else ""))

    reason = classify(body)
    if reason:
        print(f"- WARNING: this canonical result still classifies as a degenerate relay "
              f"({reason}). It is shown as-is; recovery did not run or found nothing.")

    print()
    print(body[:PREVIEW] if truncated else body)
    if truncated:
        print()
        print(f"[TRUNCATED PREVIEW — showing the first {PREVIEW} of {chars} characters. "
              f"Nothing was discarded: the complete answer is on disk at {path}.]")

print()
print(RULE)
print("END RAW PANEL OUTPUTS")
print(RULE)
PYEOF

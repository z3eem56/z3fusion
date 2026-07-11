#!/usr/bin/env bash
# _fusion_lib.sh — shared helpers for the Fusion panelist runners.
#
# Sourced (not executed) by run_codex.sh and run_gemini.sh:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/_fusion_lib.sh"
#
# Why this exists: macOS has no `timeout`/`gtimeout` (those ship with GNU coreutils,
# not installed here). _run_with_timeout reproduces GNU `timeout` semantics with a
# small self-contained perl fork+alarm wrapper: it sends SIGTERM on the deadline,
# then SIGKILL after a 2s grace, returns the command's real exit status, and returns
# 124 when the command was killed for running over time.

# Default per-panelist budget in seconds; override with FUSION_TIMEOUT.
FUSION_TIMEOUT="${FUSION_TIMEOUT:-300}"

have() { command -v "$1" >/dev/null 2>&1; }

# _run_with_timeout SECONDS cmd [args...]
# Exit status = the command's own status, or 124 if it was killed for timing out.
_run_with_timeout() {
  local secs="$1"; shift
  perl -e '
    my $secs = shift @ARGV;
    my $pid = fork();
    exit 127 unless defined $pid;
    if ($pid == 0) { exec @ARGV or exit 127; }   # child: become the real command
    local $SIG{ALRM} = sub { kill "TERM", $pid; sleep 2; kill "KILL", $pid; };
    alarm $secs;
    waitpid($pid, 0);
    my $rc = $?;
    alarm 0;
    exit 124 if ($rc & 127);   # killed by a signal (our TERM/KILL) => timed out
    exit($rc >> 8);            # otherwise propagate the command exit code
  ' "$secs" "$@"
}

# _extract_openai_content JSON_FILE OUTPUT_FILE
# Reads an OpenAI-chat-completions-shaped JSON response (choices[0].message.content),
# falling back to a bare Ollama-native shape (message.content) when there's no "choices"
# array, and writes just that text to OUTPUT_FILE. Missing/unreadable/malformed JSON, or a
# response matching neither shape, is NOT an error here: OUTPUT_FILE is simply left empty.
# The caller does the anti-empty guard (same convention as every existing runner), not this
# helper.
_extract_openai_content() {
  local json_file="$1" output_file="$2"
  python3 -c '
import json
import sys

json_file, output_file = sys.argv[1], sys.argv[2]
data = None
try:
    with open(json_file, "r", encoding="utf-8", errors="replace") as f:
        data = json.load(f)
except Exception:
    data = None

text = ""
if isinstance(data, dict):
    try:
        text = data["choices"][0]["message"]["content"] or ""
    except (KeyError, IndexError, TypeError):
        try:
            text = data["message"]["content"] or ""
        except (KeyError, TypeError):
            text = ""

with open(output_file, "w", encoding="utf-8") as f:
    f.write(text if isinstance(text, str) else "")
' "$json_file" "$output_file"
}

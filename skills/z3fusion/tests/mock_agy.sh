#!/usr/bin/env bash
# mock_agy.sh — stand-in for the `agy` CLI, installed as `agy` on PATH by run_tests.sh.
#
# It records the exact argv it was called with (so a test can assert the model pin) and
# replays a canned agy 1.1.8 response selected by $MOCK_AGY_MODE.
#
# Env contract:
#   MOCK_AGY_MODE     json_ok | json_empty | text_after_bad_json | nonzero | timeout_json
#   MOCK_AGY_ARGV     file to append each invocation's argv to (one arg per line, "--" between)
#   MOCK_AGY_NO_PIN   1 => `agy models` does NOT list gemini-3.1-pro-high
#   MOCK_AGY_CONV     conversation id to report/write a transcript under
#   MOCK_AGY_STALE    1 => back-date the written transcript so it predates the invocation
#   AGY_CLI_DIR       fake ~/.gemini/antigravity-cli root the transcript is written into

set -uo pipefail

if [ "${1:-}" = "models" ]; then
  if [ "${MOCK_AGY_NO_PIN:-}" = "1" ]; then
    printf 'gemini-3.6-flash-high\ngemini-3.6-flash-low\ngemini-3.1-pro-low\n'
  else
    printf 'gemini-3.6-flash-high\ngemini-3.1-pro-high\ngemini-3.1-pro-low\n'
  fi
  exit 0
fi

# --- record the invocation ------------------------------------------------------------
if [ -n "${MOCK_AGY_ARGV:-}" ]; then
  { printf '%s\n' "$@"; printf -- '--\n'; } >> "$MOCK_AGY_ARGV"
fi

fmt="text"
logfile=""
model=""
prev=""
for a in "$@"; do
  [ "$prev" = "--output-format" ] && fmt="$a"
  [ "$prev" = "--log-file" ] && logfile="$a"
  [ "$prev" = "--model" ] && model="$a"
  prev="$a"
done

conv="${MOCK_AGY_CONV:-mock-conv-0001}"

# Emulate agy's own log, including the line that reveals which model it ACTUALLY routed to.
# MOCK_AGY_LABEL forces a mismatch (agy accepting --model but resolving to something else).
if [ -n "$logfile" ]; then
  mkdir -p "$(dirname "$logfile")" 2>/dev/null
  {
    printf 'I0000 00:00:00.000000 1 printmode.go:113] Print mode: starting (promptLength=1, model="%s", conversationID="")\n' "$model"
    printf 'I0000 00:00:00.000000 1 model_config_manager.go:272] Propagating selected model override to backend: label="%s"\n' \
      "${MOCK_AGY_LABEL:-$model}"
  } > "$logfile"
fi

# _write_transcript — emulate agy persisting the turn to its own on-disk transcript, and
# registering this workspace -> conversation in its cache (keyed by native path, as agy does).
_write_transcript() {
  [ -n "${AGY_CLI_DIR:-}" ] || return 0
  local tdir="$AGY_CLI_DIR/brain/$conv/.system_generated/logs"
  mkdir -p "$tdir" "$AGY_CLI_DIR/cache"
  printf '%s\n' \
    '{"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"q"}' \
    '{"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"TRANSCRIPT-RECOVERED-ANSWER: this is the full model answer read back from agys own transcript."}' \
    > "$tdir/transcript.jsonl"

  local ws="$PWD"
  command -v cygpath >/dev/null 2>&1 && ws="$(cygpath -w "$PWD" 2>/dev/null || printf '%s' "$PWD")"
  WS="$ws" CONV="$conv" LCJ="$AGY_CLI_DIR/cache/last_conversations.json" python - <<'PYEOF'
import json, os
path = os.environ["LCJ"]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    data = {}
data[os.environ["WS"]] = os.environ["CONV"]
json.dump(data, open(path, "w", encoding="utf-8"), indent=1)
PYEOF

  if [ "${MOCK_AGY_STALE:-}" = "1" ]; then
    touch -t 202601010000 "$tdir/transcript.jsonl"
  fi
}

case "${MOCK_AGY_MODE:-json_ok}" in
  json_ok)
    printf '{"conversation_id":"%s","status":"SUCCESS","response":"MOCK-NATIVE-ANSWER: delivered on agys own structured stdout.","duration_seconds":1.0,"num_turns":1}\n' "$conv"
    exit 0
    ;;

  json_unicode)
    # Multiline + non-ASCII + quotes/backslashes, to prove nothing is mangled or word-split.
    printf '{"conversation_id":"%s","status":"SUCCESS","response":"Ligne 1 : réponse — ≤ 5 ✓\\nLigne 2 : \\"guillemets\\" et \\\\backslash\\nLigne 3 : 日本語 ok","duration_seconds":1.0,"num_turns":1}\n' "$conv"
    exit 0
    ;;

  json_empty)
    # exit 0 but an empty response — the historical Windows empty-stdout behavior.
    _write_transcript
    printf '{"conversation_id":"","status":"SUCCESS","response":"","duration_seconds":1.0,"num_turns":1}\n'
    exit 0
    ;;

  text_after_bad_json)
    if [ "$fmt" = "json" ]; then
      printf 'this is not json at all\n'
      exit 0
    fi
    printf 'MOCK-TEXT-ANSWER: delivered on plain stdout because structured output was unusable.\n'
    exit 0
    ;;

  nonzero)
    # A real failure. A fresh, perfectly valid transcript also exists — the runner must NOT
    # use it to paper over the non-zero exit.
    _write_transcript
    printf '{"conversation_id":"","status":"ERROR","response":"","error":"upstream failure"}\n'
    exit 3
    ;;

  *)
    printf 'mock_agy: unknown MOCK_AGY_MODE=%s\n' "${MOCK_AGY_MODE:-}" >&2
    exit 9
    ;;
esac

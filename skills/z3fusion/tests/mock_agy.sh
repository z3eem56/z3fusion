#!/usr/bin/env bash
# mock_agy.sh — stand-in for the `agy` CLI, installed as `agy` on PATH by run_tests.sh.
#
# It records the exact argv it was called with (so a test can assert the model pin) and
# replays a canned agy 1.1.8 response selected by $MOCK_AGY_MODE.
#
# Env contract:
#   MOCK_AGY_MODE     json_ok | json_unicode | json_empty | text_after_bad_json | nonzero
#                     | timeout_always | timeout_bare | timeout_then_ok | auth_error
#   MOCK_AGY_ARGV     file to append each invocation's argv to (one arg per line, "--" between)
#   MOCK_AGY_NO_PIN   1 => `agy models` does NOT list gemini-3.1-pro-high
#   MOCK_AGY_CONV     conversation id to report/write a transcript under
#   MOCK_AGY_STALE    1 => back-date the written transcript so it predates the invocation
#   MOCK_AGY_COUNT    file used to count print invocations, so a mode can behave differently
#                     on attempt 1 vs attempt 2 (`agy models` never counts)
#   MOCK_AGY_CWD      file to append the working directory of each print invocation to, so a
#                     test can prove attempt 2 ran in a different workspace than attempt 1
#   MOCK_AGY_PROMPT   file to write the verbatim `--print` argument to (last invocation wins)
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
if [ -n "${MOCK_AGY_CWD:-}" ]; then
  printf '%s\n' "$PWD" >> "$MOCK_AGY_CWD"
fi

# Which print attempt is this? (`agy models` returned above, so it never inflates the count.)
attempt_n=1
if [ -n "${MOCK_AGY_COUNT:-}" ]; then
  printf 'x' >> "$MOCK_AGY_COUNT"
  attempt_n="$(wc -c < "$MOCK_AGY_COUNT" | tr -d ' ')"
fi

fmt="text"
logfile=""
model=""
prompt_arg=""
prev=""
for a in "$@"; do
  [ "$prev" = "--output-format" ] && fmt="$a"
  [ "$prev" = "--log-file" ] && logfile="$a"
  [ "$prev" = "--model" ] && model="$a"
  [ "$prev" = "--print" ] && prompt_arg="$a"
  prev="$a"
done

# The prompt is multi-line, so the one-arg-per-line argv log cannot be parsed back into it.
# Capture it verbatim to its own file, which is what lets a test compare the composed prompt
# byte for byte (governance injected exactly once, task preserved, nothing else added).
if [ -n "${MOCK_AGY_PROMPT:-}" ]; then
  printf '%s' "$prompt_arg" > "$MOCK_AGY_PROMPT"
fi

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

  timeout_always)
    # The transient failure actually observed in production: exit 1 + "timeout waiting for
    # response" + no answer. Eligible for exactly one automatic retry.
    printf '{"conversation_id":"","status":"ERROR","response":"","error":"timeout waiting for response"}\n'
    exit 1
    ;;

  timeout_bare)
    # Same condition surfaced without any structured result at all.
    printf 'timeout waiting for response\n' >&2
    exit 1
    ;;

  timeout_then_ok)
    # Attempt 1 times out, attempt 2 answers — the case that previously needed a manual re-run
    # at a longer FUSION_TIMEOUT.
    if [ "$attempt_n" -le 1 ]; then
      printf '{"conversation_id":"","status":"ERROR","response":"","error":"timeout waiting for response"}\n'
      exit 1
    fi
    printf '{"conversation_id":"%s","status":"SUCCESS","response":"MOCK-RETRY-ANSWER: delivered on the second attempt.","duration_seconds":1.0,"num_turns":1}\n' "$conv"
    exit 0
    ;;

  ttk|ttk_then_ok)
    # Simulates reaching the per-attempt time-to-kill boundary the way real agy 1.1.8 does:
    # partial work already persisted to its own transcript (verified live — agy accumulates
    # PLANNER_RESPONSE turns DURING a run), then exit 1 with "timeout waiting for response"
    # and no answer on stdout. The checkpoint stage must rebuild the answer from that transcript.
    if [ "${MOCK_AGY_MODE}" = "ttk_then_ok" ] && [ "$attempt_n" -ge 3 ]; then
      printf '{"conversation_id":"%s","status":"SUCCESS","response":"MOCK-FUSION-ANSWER: attempt 01 supplied the architecture, attempt 02 supplied the fix and the tests.","duration_seconds":1.0,"num_turns":1}\n' "$conv"
      exit 0
    fi
    if [ "${MOCK_AGY_MODE}" = "ttk_then_ok" ] && [ "$attempt_n" -eq 2 ]; then
      printf '{"conversation_id":"%s","status":"SUCCESS","response":"MOCK-ATTEMPT-02-ANSWER: found and fixed three integration problems, completed the test suite.","duration_seconds":1.0,"num_turns":1}\n' "$conv"
      exit 0
    fi
    if [ -n "${AGY_CLI_DIR:-}" ]; then
      tdir="$AGY_CLI_DIR/brain/$conv/.system_generated/logs"
      mkdir -p "$tdir" "$AGY_CLI_DIR/cache"
      printf '%s\n' \
        '{"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"the mission"}' \
        '{"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"MOCK-PARTIAL-WORK-1: surveyed the repository and drafted the component architecture."}' \
        '{"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"MOCK-PARTIAL-WORK-2: implemented the layout and the three leaf components."}' \
        > "$tdir/transcript.jsonl"
      ws="$PWD"
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
    fi
    printf '{"conversation_id":"","status":"ERROR","response":"","error":"timeout waiting for response"}\n'
    exit 1
    ;;

  auth_error)
    # Deterministic: needs the user to log in. Retrying cannot fix it and must not happen.
    printf '{"conversation_id":"","status":"ERROR","response":"","error":"You are not logged into Antigravity. Run agy login."}\n'
    exit 1
    ;;

  *)
    printf 'mock_agy: unknown MOCK_AGY_MODE=%s\n' "${MOCK_AGY_MODE:-}" >&2
    exit 9
    ;;
esac

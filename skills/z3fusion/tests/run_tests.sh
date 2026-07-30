#!/usr/bin/env bash
# run_tests.sh — z3Fusion reliability regression suite.
#
#   bash ~/.claude/skills/z3fusion/tests/run_tests.sh
#
# Covers the three reliability guarantees, with no network and no real model calls:
#   A/A2  Gemini model pin           — agy is always invoked with --model gemini-3.1-pro-high,
#                                      and an unavailable pin fails instead of substituting.
#   E/E2  agy native output          — structured json preferred, plain text as level 2.
#   F     agy windows fallback       — exit 0 + empty stdout recovers from THIS run's transcript.
#   G     stale transcript           — an old transcript is rejected, the run fails.
#   H     agy non-zero exit          — failure is never masked by a valid transcript.
#   B     Claude normal relay        — a real answer classifies as normal.
#   C     Claude Idle. recovery      — sentinel + completed task output => healthy panelist.
#   D     Claude true failure        — sentinel + nothing recoverable => clean failure.
#
# `agy` is replaced on PATH by tests/mock_agy.sh; the Claude tests build fake subagent
# transcripts in the exact on-disk layout Claude Code uses.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
PY="${FUSION_PY:-$(command -v python3 || command -v python || echo python3)}"

PASSED=0
FAILED=0
FAILURES=""

pass() { PASSED=$((PASSED + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() {
  FAILED=$((FAILED + 1))
  FAILURES="$FAILURES
  - $1"
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
}
check() { if [ "$1" = "0" ]; then pass "$2"; else fail "$2" "${3:-}"; fi; }

# assert_pinned <argv_file> <model> — a `--model <model>` pair must appear in a recorded argv.
assert_pinned() {
  grep -A1 -x -- '--model' "$1" 2>/dev/null | grep -qx -- "$2"
}

blank_file() {
  [ ! -s "$1" ] && return 0
  [ "$(LC_ALL=C tr -d '[:space:]' < "$1" | wc -c | tr -d ' ')" = "0" ]
}

# new_sandbox — fresh PATH shim + fake agy home for one gemini test. Sets SB/ARGV/OUT/BIN.
new_sandbox() {
  SB="$(mktemp -d "${TMPDIR:-/tmp}/z3ftest.XXXXXX")"
  BIN="$SB/bin"
  mkdir -p "$BIN" "$SB/agyhome"
  printf '#!/usr/bin/env bash\nexec bash "%s/mock_agy.sh" "$@"\n' "$TESTS_DIR" > "$BIN/agy"
  chmod +x "$BIN/agy"
  ARGV="$SB/argv.log"
  : > "$ARGV"
  OUT="$SB/gemini_out.md"
  printf 'What is the answer?\n' > "$SB/prompt.md"
}

# run_gemini <extra env assignments...> — invoke the runner inside the sandbox.
run_gemini() {
  env PATH="$BIN:$PATH" \
      MOCK_AGY_ARGV="$ARGV" \
      AGY_CLI_DIR="$SB/agyhome" \
      FUSION_TIMEOUT=20 \
      "$@" \
      bash "$SCRIPTS/run_gemini.sh" "$SB/prompt.md" "$OUT" \
      > "$SB/runner.out" 2> "$SB/runner.err"
}

prov() { "$PY" -c "
import json,sys
try:
    print(json.load(open(sys.argv[1],encoding='utf-8')).get(sys.argv[2]) or '')
except Exception:
    print('')
" "$OUT.provenance.json" "$1" 2>/dev/null; }

echo
echo "=== z3Fusion reliability suite ==============================================="
echo
echo "-- Issue 1: Gemini model pin ---------------------------------------------"

# ---------------------------------------------------------------- TEST A
new_sandbox
run_gemini MOCK_AGY_MODE=json_ok
rc=$?
if [ "$rc" -eq 0 ] && assert_pinned "$ARGV" "Gemini 3.1 Pro (High)"; then
  pass "A  default slot invokes agy with an explicit --model pinning Gemini 3.1 Pro (High)"
else
  fail "A  default slot invokes agy with an explicit --model pinning Gemini 3.1 Pro (High)" \
       "exit=$rc argv=$(tr '\n' ' ' < "$ARGV" | head -c 200)"
fi
if [ "$(prov model)" = "gemini-3.1-pro-high" ]; then
  pass "A  provenance reports the canonical model gemini-3.1-pro-high"
else
  fail "A  provenance reports the canonical model gemini-3.1-pro-high" "got=$(prov model)"
fi
if [ "$(prov routed_model_label)" = "Gemini 3.1 Pro (High)" ]; then
  pass "A  the model agy actually routed to is captured and matches the pin"
else
  fail "A  the model agy actually routed to is captured and matches the pin" \
       "got=$(prov routed_model_label)"
fi
if grep -qi 'flash' "$ARGV"; then
  fail "A  no Flash model ever appears in the invocation"
else
  pass "A  no Flash model ever appears in the invocation"
fi
if grep -qx -- '--model' "$ARGV"; then
  pass "A  --model is always passed (never agy's configured default)"
else
  fail "A  --model is always passed (never agy's configured default)"
fi

# logical alias must resolve to the same pinned model
new_sandbox
run_gemini MOCK_AGY_MODE=json_ok AGY_MODEL=gemini-3.1-pro
rc=$?
if [ "$rc" -eq 0 ] && assert_pinned "$ARGV" "Gemini 3.1 Pro (High)" \
   && [ "$(prov model)" = "gemini-3.1-pro-high" ]; then
  pass "A  logical 'gemini-3.1-pro' resolves to the pinned gemini-3.1-pro-high"
else
  fail "A  logical 'gemini-3.1-pro' resolves to the pinned gemini-3.1-pro-high" \
       "exit=$rc argv=$(tr '\n' ' ' < "$ARGV" | head -c 200)"
fi

# an explicitly requested non-default agy model still passes through untouched
new_sandbox
run_gemini MOCK_AGY_MODE=json_ok AGY_MODEL=gemini-3.6-flash-high
rc=$?
if assert_pinned "$ARGV" "gemini-3.6-flash-high"; then
  pass "A  an explicitly requested other agy model is not overridden"
else
  fail "A  an explicitly requested other agy model is not overridden" "exit=$rc"
fi

# ---------------------------------------------------------------- TEST A3
# agy accepts --model but resolves to a DIFFERENT backend model (the real agy 1.1.8
# not-logged-in downgrade). This must fail loudly, never answer as the wrong model.
new_sandbox
run_gemini MOCK_AGY_MODE=json_ok MOCK_AGY_LABEL="Gemini 3.6 Flash (High)"
rc=$?
if [ "$rc" -eq 1 ] && grep -q "required model unavailable: gemini-3.1-pro-high" "$SB/runner.err"; then
  pass "A3 a silent backend downgrade to Flash is detected and fails the panelist"
else
  fail "A3 a silent backend downgrade to Flash is detected and fails the panelist" \
       "exit=$rc err=$(tail -c 250 "$SB/runner.err")"
fi
if blank_file "$OUT"; then
  pass "A3 a wrong-model answer never reaches the panel result file"
else
  fail "A3 a wrong-model answer never reaches the panel result file" "$(head -c 120 "$OUT")"
fi

# ---------------------------------------------------------------- TEST A2
new_sandbox
run_gemini MOCK_AGY_MODE=json_ok MOCK_AGY_NO_PIN=1
rc=$?
if [ "$rc" -eq 1 ] && grep -q "required model unavailable: gemini-3.1-pro-high" "$SB/runner.err"; then
  pass "A2 unavailable pin fails with 'required model unavailable: gemini-3.1-pro-high'"
else
  fail "A2 unavailable pin fails with 'required model unavailable: gemini-3.1-pro-high'" \
       "exit=$rc err=$(tail -c 200 "$SB/runner.err")"
fi
if grep -qx -- '--print' "$ARGV"; then
  fail "A2 no model is run at all when the pin is unavailable (no silent fallback)"
else
  pass "A2 no model is run at all when the pin is unavailable (no silent fallback)"
fi

echo
echo "-- Issue 3: agy output transport -----------------------------------------"

# ---------------------------------------------------------------- TEST E
new_sandbox
run_gemini MOCK_AGY_MODE=json_ok
rc=$?
t="$(prov output_transport)"
if [ "$rc" -eq 0 ] && [ "$t" = "json" ] && grep -q 'MOCK-NATIVE-ANSWER' "$OUT"; then
  pass "E  native structured output is used (transport=json)"
else
  fail "E  native structured output is used (transport=json)" "exit=$rc transport=$t"
fi
if [ "$(grep -cx -- '--output-format' "$ARGV")" = "1" ]; then
  pass "E  no transcript scraping and no second agy call when json succeeds"
else
  fail "E  no transcript scraping and no second agy call when json succeeds" \
       "invocations=$(grep -cx -- '--output-format' "$ARGV")"
fi
if [ "$(prov model_pin_verified)" = "True" ] || [ "$(prov model_pin_verified)" = "true" ]; then
  pass "E  provenance records model_pin_verified"
else
  fail "E  provenance records model_pin_verified" "got=$(prov model_pin_verified)"
fi

# ---------------------------------------------------------------- TEST E2
new_sandbox
run_gemini MOCK_AGY_MODE=text_after_bad_json
rc=$?
t="$(prov output_transport)"
if [ "$rc" -eq 0 ] && [ "$t" = "stdout-text" ] && grep -q 'MOCK-TEXT-ANSWER' "$OUT"; then
  pass "E2 unusable structured output falls back to plain stdout (transport=stdout-text)"
else
  fail "E2 unusable structured output falls back to plain stdout (transport=stdout-text)" \
       "exit=$rc transport=$t"
fi

# ---------------------------------------------------------------- TEST F
new_sandbox
run_gemini MOCK_AGY_MODE=json_empty MOCK_AGY_CONV=conv-current-run
rc=$?
t="$(prov output_transport)"
if [ "$rc" -eq 0 ] && [ "$t" = "windows-transcript-fallback" ] && grep -q 'TRANSCRIPT-RECOVERED-ANSWER' "$OUT"; then
  pass "F  exit 0 + empty stdout recovers from this run's transcript (healthy)"
else
  fail "F  exit 0 + empty stdout recovers from this run's transcript (healthy)" \
       "exit=$rc transport=$t err=$(tail -c 200 "$SB/runner.err")"
fi

# ---------------------------------------------------------------- TEST G
new_sandbox
run_gemini MOCK_AGY_MODE=json_empty MOCK_AGY_CONV=conv-old-run MOCK_AGY_STALE=1
rc=$?
if [ "$rc" -eq 1 ] && blank_file "$OUT"; then
  pass "G  a stale transcript is rejected and the run fails (no stale answer accepted)"
else
  fail "G  a stale transcript is rejected and the run fails (no stale answer accepted)" \
       "exit=$rc out=$(head -c 120 "$OUT" 2>/dev/null)"
fi
if grep -q 'TRANSCRIPT-RECOVERED-ANSWER' "$OUT" 2>/dev/null; then
  fail "G  stale transcript content never reaches the output file"
else
  pass "G  stale transcript content never reaches the output file"
fi

# ---------------------------------------------------------------- TEST H
new_sandbox
run_gemini MOCK_AGY_MODE=nonzero MOCK_AGY_CONV=conv-nonzero
rc=$?
if [ "$rc" -eq 1 ] && blank_file "$OUT"; then
  pass "H  a non-zero agy exit fails the panelist"
else
  fail "H  a non-zero agy exit fails the panelist" "exit=$rc"
fi
if grep -q 'TRANSCRIPT-RECOVERED-ANSWER' "$OUT" 2>/dev/null; then
  fail "H  a valid transcript does not mask a non-zero exit"
else
  pass "H  a valid transcript does not mask a non-zero exit"
fi

echo
echo "-- Hardening -------------------------------------------------------------"

# Windows paths routinely contain spaces; every path must survive quoting end to end.
new_sandbox
mkdir -p "$SB/dir with spaces"
OUT="$SB/dir with spaces/gemini out.md"
printf 'Question?\n' > "$SB/prompt file.md"
env PATH="$BIN:$PATH" MOCK_AGY_ARGV="$ARGV" AGY_CLI_DIR="$SB/agyhome" FUSION_TIMEOUT=20 \
    MOCK_AGY_MODE=json_ok \
    bash "$SCRIPTS/run_gemini.sh" "$SB/prompt file.md" "$OUT" \
    > "$SB/runner.out" 2> "$SB/runner.err"
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'MOCK-NATIVE-ANSWER' "$OUT" && [ -f "$OUT.provenance.json" ]; then
  pass "P  prompt/output paths containing spaces work end to end"
else
  fail "P  prompt/output paths containing spaces work end to end" \
       "exit=$rc err=$(tail -c 200 "$SB/runner.err")"
fi

# Multiline / non-ASCII / quotes must round-trip byte-exact.
new_sandbox
run_gemini MOCK_AGY_MODE=json_unicode
rc=$?
if [ "$rc" -eq 0 ] \
   && grep -qF 'réponse — ≤ 5 ✓' "$OUT" \
   && grep -qF '日本語 ok' "$OUT" \
   && grep -qF '"guillemets" et \backslash' "$OUT" \
   && [ "$(grep -cF 'Ligne ' "$OUT")" -eq 3 ]; then
  pass "P  unicode, quotes, backslashes and multiline answers survive intact"
else
  fail "P  unicode, quotes, backslashes and multiline answers survive intact" \
       "exit=$rc got=$(head -c 200 "$OUT")"
fi

# A missing trailing newline would glue the answer onto the next block in the provenance file.
if [ -z "$(tail -c1 "$OUT")" ]; then
  pass "P  the answer file always ends with a newline"
else
  fail "P  the answer file always ends with a newline"
fi

# Two runs at once must not share scratch, workspace, or output.
new_sandbox
SB_A="$SB"; ARGV_A="$ARGV"; OUT_A="$OUT"; BIN_A="$BIN"
run_gemini MOCK_AGY_MODE=json_ok &
pid_a=$!
new_sandbox
run_gemini MOCK_AGY_MODE=json_ok &
pid_b=$!
wait $pid_a; rc_a=$?
wait $pid_b; rc_b=$?
if [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ] && [ "$SB_A" != "$SB" ] \
   && grep -q 'MOCK-NATIVE-ANSWER' "$OUT_A" && grep -q 'MOCK-NATIVE-ANSWER' "$OUT"; then
  pass "P  two concurrent runs do not collide"
else
  fail "P  two concurrent runs do not collide" "a=$rc_a b=$rc_b"
fi

# The runner must not leave its scratch dirs behind.
leaked="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'z3fusion-gemini.*' 2>/dev/null | wc -l | tr -d ' ')"
if [ "${leaked:-0}" -eq 0 ]; then
  pass "P  scratch directories are cleaned up"
else
  fail "P  scratch directories are cleaned up" "$leaked left behind"
fi

echo
echo "-- Issue 2: Claude panelist relay ----------------------------------------"

# Build a fake Claude Code subagent transcript tree.
# mk_agent <projects_dir> <agent_id> <json-encoded assistant texts...>
mk_agent() {
  local proj="$1" aid="$2"; shift 2
  local dir="$proj/C--fake-project/session-abc/subagents"
  mkdir -p "$dir"
  local f="$dir/agent-$aid.jsonl"
  : > "$f"
  printf '{"type":"user","message":{"role":"user","content":"the task"}}\n' >> "$f"
  for txt in "$@"; do
    TXT="$txt" "$PY" -c '
import json, os, sys
print(json.dumps({"type":"assistant","message":{"role":"assistant",
     "content":[{"type":"text","text":os.environ["TXT"]}]}}))
' >> "$f"
  done
}

REAL_ANSWER="Yes — the channel is live end to end. I ran a shell round-trip and it returned a timestamp, web search is reachable, and the working directory resolves correctly. Full self-contained answer follows with all the detail the task asked for."

# ---------------------------------------------------------------- TEST B
CB="$(mktemp -d "${TMPDIR:-/tmp}/z3ftestB.XXXXXX")"
"$PY" "$SCRIPTS/claude_relay.py" classify --text "$REAL_ANSWER" > "$CB/c.out" 2>&1
check "$?" "B  a normal Agent answer classifies as 'normal' (flows straight through)" \
      "$(cat "$CB/c.out")"
grep -qx 'normal' "$CB/c.out" && pass "B  classifier prints 'normal'" \
  || fail "B  classifier prints 'normal'" "$(cat "$CB/c.out")"

# ---------------------------------------------------------------- TEST C
CC="$(mktemp -d "${TMPDIR:-/tmp}/z3ftestC.XXXXXX")"
mk_agent "$CC/projects" "agentC123" \
  "$REAL_ANSWER" \
  "Still here. Nothing has changed on my end across the pings." \
  "Idle. Waiting on you." \
  "Idle."
"$PY" "$SCRIPTS/claude_relay.py" classify --text "Idle." > "$CC/cls.out" 2>&1
cls_rc=$?
"$PY" "$SCRIPTS/claude_relay.py" recover --agent-id agentC123 --agent-status completed \
  --out "$CC/panelist.md" --projects-dir "$CC/projects" > "$CC/rec.out" 2> "$CC/rec.err"
rec_rc=$?
if [ "$cls_rc" -eq 3 ] && grep -q 'idle-sentinel' "$CC/cls.out"; then
  pass "C  'Idle.' is detected as a suspicious relay"
else
  fail "C  'Idle.' is detected as a suspicious relay" "rc=$cls_rc $(cat "$CC/cls.out")"
fi
if [ "$rec_rc" -eq 0 ] && grep -q 'the channel is live end to end' "$CC/panelist.md"; then
  pass "C  the real completed answer is recovered into the canonical panel result"
else
  fail "C  the real completed answer is recovered into the canonical panel result" \
       "rc=$rec_rc $(tail -c 200 "$CC/rec.err")"
fi
if "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
sys.exit(0 if d.get('healthy') and d.get('result_transport')=='recovered-task-output'
            and d.get('relay_anomaly')=='idle-sentinel' else 1)
" "$CC/panelist.md.provenance.json"; then
  pass "C  provenance marks recovery (healthy, recovered-task-output, idle-sentinel)"
else
  fail "C  provenance marks recovery (healthy, recovered-task-output, idle-sentinel)" \
       "$(cat "$CC/panelist.md.provenance.json" 2>/dev/null)"
fi

# a still-running agent must not be scraped for partial output
"$PY" "$SCRIPTS/claude_relay.py" recover --agent-id agentC123 --agent-status running \
  --out "$CC/partial.md" --projects-dir "$CC/projects" > /dev/null 2>&1
if [ "$?" -ne 0 ] && [ ! -f "$CC/partial.md" ]; then
  pass "C  an incomplete agent is never recovered from (no partial output)"
else
  fail "C  an incomplete agent is never recovered from (no partial output)"
fi

# ---------------------------------------------------------------- TEST D
CD="$(mktemp -d "${TMPDIR:-/tmp}/z3ftestD.XXXXXX")"
mk_agent "$CD/projects" "agentD456" "Idle." "Idle." "   "
"$PY" "$SCRIPTS/claude_relay.py" recover --agent-id agentD456 --agent-status completed \
  --out "$CD/panelist.md" --projects-dir "$CD/projects" > "$CD/rec.out" 2> "$CD/rec.err"
rec_rc=$?
if [ "$rec_rc" -ne 0 ] && [ ! -s "$CD/panelist.md" ]; then
  pass "D  sentinel with nothing recoverable fails the panelist"
else
  fail "D  sentinel with nothing recoverable fails the panelist" "rc=$rec_rc"
fi
if grep -qi 'no substantive output' "$CD/rec.err"; then
  pass "D  the failure names a clear reason"
else
  fail "D  the failure names a clear reason" "$(tail -c 200 "$CD/rec.err")"
fi

# unknown agent id must fail cleanly, not hang or half-write
"$PY" "$SCRIPTS/claude_relay.py" recover --agent-id doesNotExist \
  --out "$CD/missing.md" --projects-dir "$CD/projects" > /dev/null 2> "$CD/missing.err"
if [ "$?" -ne 0 ] && grep -qi 'no transcript found' "$CD/missing.err"; then
  pass "D  an unknown agent id fails cleanly"
else
  fail "D  an unknown agent id fails cleanly" "$(tail -c 200 "$CD/missing.err")"
fi

echo
echo "=============================================================================="
printf 'passed: %d   failed: %d\n' "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
  printf 'failing:%s\n' "$FAILURES"
  exit 1
fi
echo "all green"

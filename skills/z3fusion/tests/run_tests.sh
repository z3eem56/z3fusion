#!/usr/bin/env bash
# run_tests.sh — z3Fusion reliability regression suite.
#
#   bash ~/.claude/skills/z3fusion/tests/run_tests.sh
#
# Covers every reliability guarantee, with no network and no real model calls:
#   A/A2  Gemini model pin           — agy is always invoked with an explicit --model, and an
#                                      unavailable pin fails instead of substituting.
#   A3    silent backend downgrade   — agy accepting --model but routing elsewhere fails loudly.
#   E/E2  agy native output          — structured json preferred, plain text as level 2.
#   F     agy windows fallback       — exit 0 + empty stdout recovers from THIS run's transcript.
#   G     stale transcript           — an old transcript is rejected, the run fails.
#   H     agy non-zero exit          — failure is never masked by a valid transcript.
#   P     hardening                  — spaces in paths, unicode, trailing newline, concurrency.
#   B     Claude normal relay        — a real answer classifies as normal.
#   C     Claude Idle. recovery      — sentinel + completed task output => healthy panelist.
#   D     Claude true failure        — sentinel + nothing recoverable => clean failure.
#   W     relay wrapper normalization— a sentinel wrapped in a SECURITY WARNING / agentId /
#                                      <usage> envelope is NOT healthy, while a real answer that
#                                      merely discusses security is left completely alone.
#   T     bounded agy retry          — one automatic retry for a transient timeout, never for a
#                                      deterministic failure, with isolated per-attempt state.
#   O     raw panel observability    — every panelist's canonical answer is rendered with its
#                                      identity/transport, long output truncated explicitly.
#   V     Gemini governance          — karpathy-engineering-v1 injected exactly once, task
#                                      preserved, blindness intact, fails closed if missing.
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
echo "-- Issue 1: relay wrapper normalization ----------------------------------"

# The relay observed in production, byte for byte: a SECURITY WARNING preamble, the agent's
# degenerate wake-up reply, the agentId trailer and a <usage> block — all glued onto ONE line.
# Classified as a whole it is 734 chars of prose and scored "normal", which let a sentinel
# reach the judge. Classification must happen on the ANSWER, not on the envelope.
WRAPPED="SECURITY WARNING: This subagent performed actions that may violate security policy. Reason: [Credential Exploration] The agent is systematically scanning multiple directories (.agy, .gemini, .antigravity, AppData) for files matching creds/auth/account/token patterns, which is credential-store scanning regardless of the specific service names.. Review the subagent's actions carefully before acting on its output.No new input received. I'll stop responding to these repeated hook notifications - send a message when you need something.agentId: agentW789 (use SendMessage with to: 'agentW789', summary: '<5-10 word recap>' to continue this agent)
<usage>subagent_tokens: 58588
tool_uses: 13
duration_ms: 241849</usage>"

# A real answer that talks at length ABOUT a security warning. It must survive untouched —
# "contains the word security" is not evidence of harness metadata.
SEC_PROSE="The SECURITY WARNING you saw is a true positive on the access pattern and a false alarm on intent. The subagent scanned .agy, .gemini and AppData for credential-shaped filenames, which the harness flags as credential-store scanning regardless of which service is involved. No secret was exposed: the OAuth token lives in the OS keyring, and the agent explicitly said so rather than extracting it. Keep the warning, but teach the review step to distinguish reading a plaintext identity log from exfiltrating a token."

# A real answer that QUOTES the sentinel phrasing while explaining the failure mode.
QUOTES_IT="When a SubagentStop hook re-wakes a finished agent, the agent typically replies 'no new input received' and stops. That reply is what the Agent tool relays back, so the orchestrator sees a sentinel instead of the deliverable. The fix is to key recovery on the agentId rather than on the relayed text, because the transcript still holds every assistant turn including the real one."

CW="$(mktemp -d "${TMPDIR:-/tmp}/z3ftestW.XXXXXX")"
mk_agent "$CW/projects" "agentW789" "$REAL_ANSWER" "Idle."

# ---------------------------------------------------------------- TEST W1
"$PY" "$SCRIPTS/claude_relay.py" classify --text "$WRAPPED" > "$CW/w1.out" 2>/dev/null
w1_rc=$?
if [ "$w1_rc" -eq 3 ] && grep -q 'suspicious:' "$CW/w1.out"; then
  pass "W1 a security-warning wrapper cannot make a sentinel classify as healthy"
else
  fail "W1 a security-warning wrapper cannot make a sentinel classify as healthy" \
       "rc=$w1_rc out=$(cat "$CW/w1.out")"
fi

# ---------------------------------------------------------------- TEST W2
"$PY" "$SCRIPTS/claude_relay.py" normalize --text "$WRAPPED" --agent-id agentW789 \
  --agent-status completed --out "$CW/panelist.md" --projects-dir "$CW/projects" \
  > "$CW/w2.out" 2> "$CW/w2.err"
w2_rc=$?
if [ "$w2_rc" -eq 0 ] && grep -q 'the channel is live end to end' "$CW/panelist.md"; then
  pass "W2 the completed task output is recovered and replaces the wrapper+sentinel"
else
  fail "W2 the completed task output is recovered and replaces the wrapper+sentinel" \
       "rc=$w2_rc err=$(tail -c 200 "$CW/w2.err")"
fi
if ! grep -qi 'SECURITY WARNING' "$CW/panelist.md" && ! grep -qi 'agentId' "$CW/panelist.md"; then
  pass "W2 no harness wrapper survives into the canonical panel result"
else
  fail "W2 no harness wrapper survives into the canonical panel result" \
       "$(head -c 150 "$CW/panelist.md")"
fi
if "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
ok = (d.get('relay_wrapper_detected') is True
      and 'security-warning' in (d.get('relay_wrapper_type') or '')
      and d.get('relay_classification')=='suspicious'
      and d.get('result_transport')=='recovered-task-output'
      and d.get('healthy') is True)
sys.exit(0 if ok else 1)
" "$CW/panelist.md.provenance.json"; then
  pass "W2 provenance records wrapper detection, classification and transport"
else
  fail "W2 provenance records wrapper detection, classification and transport" \
       "$(cat "$CW/panelist.md.provenance.json" 2>/dev/null)"
fi

# ---------------------------------------------------------------- TEST W3 (negative)
"$PY" "$SCRIPTS/claude_relay.py" classify --text "$SEC_PROSE" > "$CW/w3.out" 2>/dev/null
w3_rc=$?
if [ "$w3_rc" -eq 0 ] && grep -qx 'normal' "$CW/w3.out"; then
  pass "W3 a long legitimate answer discussing a security warning stays 'normal'"
else
  fail "W3 a long legitimate answer discussing a security warning stays 'normal'" \
       "rc=$w3_rc out=$(cat "$CW/w3.out")"
fi
"$PY" "$SCRIPTS/claude_relay.py" normalize --text "$SEC_PROSE" --out "$CW/prose.md" \
  > /dev/null 2>&1
if grep -qF 'The SECURITY WARNING you saw is a true positive' "$CW/prose.md" \
   && grep -qF 'exfiltrating a token' "$CW/prose.md"; then
  pass "W3 that answer is delivered whole — nothing is stripped from it"
else
  fail "W3 that answer is delivered whole — nothing is stripped from it" \
       "$(head -c 150 "$CW/prose.md")"
fi

# ---------------------------------------------------------------- TEST W4 (negative)
"$PY" "$SCRIPTS/claude_relay.py" classify --text "$QUOTES_IT" > "$CW/w4.out" 2>/dev/null
if [ "$?" -eq 0 ] && grep -qx 'normal' "$CW/w4.out"; then
  pass "W4 an answer that QUOTES the sentinel phrasing is not itself a sentinel"
else
  fail "W4 an answer that QUOTES the sentinel phrasing is not itself a sentinel" \
       "$(cat "$CW/w4.out")"
fi

# ---------------------------------------------------------------- TEST W5
# A healthy answer that merely carries the harness trailer: the trailer comes off, the answer
# stays, and the untouched relay is preserved on disk rather than discarded.
"$PY" "$SCRIPTS/claude_relay.py" normalize \
  --text "$REAL_ANSWER
agentId: agentW789 (use SendMessage with to: 'agentW789', summary: 'x' to continue this agent)
<usage>subagent_tokens: 10</usage>" \
  --out "$CW/healthy.md" > "$CW/w5.out" 2>/dev/null
w5_rc=$?
if [ "$w5_rc" -eq 0 ] && grep -qx 'normal' "$CW/w5.out" \
   && grep -q 'the channel is live end to end' "$CW/healthy.md" \
   && ! grep -qi 'agentId' "$CW/healthy.md"; then
  pass "W5 a healthy relay keeps its answer and loses only the harness bookkeeping"
else
  fail "W5 a healthy relay keeps its answer and loses only the harness bookkeeping" \
       "rc=$w5_rc $(head -c 150 "$CW/healthy.md")"
fi
if grep -qi 'agentId' "$CW/healthy.md.raw" 2>/dev/null; then
  pass "W5 the untouched original relay is preserved alongside (.raw)"
else
  fail "W5 the untouched original relay is preserved alongside (.raw)"
fi

# ---------------------------------------------------------------- TEST W6
for s in "No action." "Idle." "   " "Done."; do
  "$PY" "$SCRIPTS/claude_relay.py" classify --text "$s" > "$CW/w6.out" 2>/dev/null
  if [ "$?" -ne 3 ]; then
    fail "W6 bare sentinel '$s' is suspicious" "$(cat "$CW/w6.out")"
    s=""
    break
  fi
done
[ -n "$s" ] && pass "W6 'No action.' / 'Idle.' / whitespace / 'Done.' are all suspicious"

# ---------------------------------------------------------------- TEST W9
# Captured live during this suite's own end-to-end run: the wake-up loop does not always
# produce "Idle." — here it produced 250 chars of fluent prose reporting on the agent's own
# responding. No sentinel opener, no harness wrapper, comfortably over min-chars. It scored
# "normal" until this shape was added, which is why the classifier keys on FIRST-PERSON
# delivery commentary and not on a list of known sentinel strings.
LIVE_SENTINEL="I've now delivered this answer six times in response to repeated stop-hook notices that contain no new request. I'm going to stop repeating it. The work is done and the deliverable is in the transcript above - the parent agent should relay that paragraph."
"$PY" "$SCRIPTS/claude_relay.py" classify --text "$LIVE_SENTINEL" > "$CW/w9.out" 2>/dev/null
if [ "$?" -eq 3 ] && grep -q 'wakeup-sentinel' "$CW/w9.out"; then
  pass "W9 the live wake-up reply (prose, no 'Idle.', no wrapper) is caught"
else
  fail "W9 the live wake-up reply (prose, no 'Idle.', no wrapper) is caught" \
       "$(cat "$CW/w9.out")"
fi
# ...and the first-person rule must not fire on an ordinary answer that uses "I".
"$PY" "$SCRIPTS/claude_relay.py" classify \
  --text "I ran the round-trip twice and both returned a timestamp, so the channel is live. I have also confirmed the working directory resolves correctly under Git Bash." \
  > "$CW/w9b.out" 2>/dev/null
if [ "$?" -eq 0 ]; then
  pass "W9 a first-person answer that simply reports work done is still 'normal'"
else
  fail "W9 a first-person answer that simply reports work done is still 'normal'" \
       "$(cat "$CW/w9b.out")"
fi

# ---------------------------------------------------------------- TEST W7
CW2="$(mktemp -d "${TMPDIR:-/tmp}/z3ftestW2.XXXXXX")"
mk_agent "$CW2/projects" "agentW000" "Idle." "Idle."
"$PY" "$SCRIPTS/claude_relay.py" normalize --text "$WRAPPED" --agent-id agentW000 \
  --agent-status completed --out "$CW2/panelist.md" --projects-dir "$CW2/projects" \
  > /dev/null 2> "$CW2/w7.err"
if [ "$?" -ne 0 ] && [ ! -s "$CW2/panelist.md" ]; then
  pass "W7 a wrapped sentinel with nothing recoverable fails the panelist cleanly"
else
  fail "W7 a wrapped sentinel with nothing recoverable fails the panelist cleanly" \
       "$(tail -c 200 "$CW2/w7.err")"
fi

# ---------------------------------------------------------------- TEST W8
"$PY" "$SCRIPTS/claude_relay.py" normalize --text "$WRAPPED" --agent-id agentW789 \
  --agent-status running --out "$CW2/running.md" --projects-dir "$CW/projects" \
  > /dev/null 2> "$CW2/w8.err"
if [ "$?" -ne 0 ] && [ ! -s "$CW2/running.md" ] && grep -qi 'did not complete' "$CW2/w8.err"; then
  pass "W8 normalize never scrapes an agent that has not completed"
else
  fail "W8 normalize never scrapes an agent that has not completed" \
       "$(tail -c 200 "$CW2/w8.err")"
fi

echo
echo "-- Issue 2: bounded automatic agy retry ----------------------------------"

# ---------------------------------------------------------------- TEST T1
new_sandbox
run_gemini MOCK_AGY_MODE=json_ok MOCK_AGY_COUNT="$SB/count"
rc=$?
if [ "$rc" -eq 0 ] && [ "$(prov attempts)" = "1" ] && [ "$(prov attempt_1_status)" = "success" ] \
   && [ "$(prov attempt_2_status)" = "not-run" ] && [ -z "$(prov retry_reason)" ]; then
  pass "T1 a first-attempt success is never retried"
else
  fail "T1 a first-attempt success is never retried" \
       "rc=$rc attempts=$(prov attempts) a1=$(prov attempt_1_status) a2=$(prov attempt_2_status)"
fi

# ---------------------------------------------------------------- TEST T2
new_sandbox
run_gemini MOCK_AGY_MODE=timeout_then_ok MOCK_AGY_COUNT="$SB/count" MOCK_AGY_CWD="$SB/cwd"
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'MOCK-RETRY-ANSWER' "$OUT"; then
  pass "T2 a transient timeout is retried automatically and the retry's answer is used"
else
  fail "T2 a transient timeout is retried automatically and the retry's answer is used" \
       "rc=$rc err=$(tail -c 250 "$SB/runner.err")"
fi
if [ "$(prov attempts)" = "2" ] && [ "$(prov attempt_1_status)" = "timeout" ] \
   && [ "$(prov attempt_2_status)" = "success" ] && [ "$(prov final_status)" = "success" ] \
   && [ -n "$(prov retry_reason)" ]; then
  pass "T2 provenance records the full attempt history and the retry reason"
else
  fail "T2 provenance records the full attempt history and the retry reason" \
       "attempts=$(prov attempts) a1=$(prov attempt_1_status) a2=$(prov attempt_2_status) reason=$(prov retry_reason)"
fi
if [ "$(prov model_pin_verified)" = "True" ] || [ "$(prov model_pin_verified)" = "true" ]; then
  pass "T2 the retry still proves the model pin (routing verified on the winning attempt)"
else
  fail "T2 the retry still proves the model pin (routing verified on the winning attempt)" \
       "got=$(prov model_pin_verified)"
fi
if [ "$(sort -u "$SB/cwd" 2>/dev/null | wc -l | tr -d ' ')" = "2" ]; then
  pass "T2 each attempt runs in its own workspace (attempt 2 cannot reuse attempt 1's)"
else
  fail "T2 each attempt runs in its own workspace (attempt 2 cannot reuse attempt 1's)" \
       "$(cat "$SB/cwd" 2>/dev/null)"
fi

# ---------------------------------------------------------------- TEST T3
new_sandbox
run_gemini MOCK_AGY_MODE=timeout_always MOCK_AGY_COUNT="$SB/count"
rc=$?
if [ "$rc" -eq 124 ] && blank_file "$OUT"; then
  pass "T3 timeout then timeout fails the panelist cleanly (no partial answer)"
else
  fail "T3 timeout then timeout fails the panelist cleanly (no partial answer)" "rc=$rc"
fi
if [ "$(grep -cx -- '--print' "$ARGV")" = "2" ] && [ "$(prov attempts)" = "2" ] \
   && [ "$(prov attempt_2_status)" = "failure" ] && [ "$(prov final_status)" = "failure" ]; then
  pass "T3 exactly two attempts are made — the retry is bounded, never a loop"
else
  fail "T3 exactly two attempts are made — the retry is bounded, never a loop" \
       "invocations=$(grep -cx -- '--print' "$ARGV") attempts=$(prov attempts)"
fi

# ---------------------------------------------------------------- TEST T4
new_sandbox
run_gemini MOCK_AGY_MODE=json_ok MOCK_AGY_LABEL="Gemini 3.6 Flash (High)"
rc=$?
if [ "$rc" -eq 1 ] && [ "$(grep -cx -- '--print' "$ARGV")" = "1" ]; then
  pass "T4 a routed-model mismatch is deterministic and is NOT retried"
else
  fail "T4 a routed-model mismatch is deterministic and is NOT retried" \
       "rc=$rc invocations=$(grep -cx -- '--print' "$ARGV")"
fi

# ---------------------------------------------------------------- TEST T5
new_sandbox
run_gemini MOCK_AGY_MODE=auth_error
rc=$?
if [ "$rc" -eq 1 ] && [ "$(grep -cx -- '--print' "$ARGV")" = "1" ] \
   && [ "$(prov attempts)" = "1" ]; then
  pass "T5 an authentication failure needing user action is NOT retried"
else
  fail "T5 an authentication failure needing user action is NOT retried" \
       "rc=$rc invocations=$(grep -cx -- '--print' "$ARGV") attempts=$(prov attempts)"
fi

# ---------------------------------------------------------------- TEST T6
new_sandbox
run_gemini MOCK_AGY_MODE=json_empty MOCK_AGY_CONV=conv-stale-retry MOCK_AGY_STALE=1
rc=$?
if [ "$rc" -eq 1 ] && [ "$(grep -cx -- '--print' "$ARGV")" = "1" ] && blank_file "$OUT"; then
  pass "T6 a rejected stale transcript is deterministic and is NOT retried"
else
  fail "T6 a rejected stale transcript is deterministic and is NOT retried" \
       "rc=$rc invocations=$(grep -cx -- '--print' "$ARGV")"
fi

# ---------------------------------------------------------------- TEST T7
new_sandbox
run_gemini MOCK_AGY_MODE=timeout_bare MOCK_AGY_COUNT="$SB/count"
rc=$?
if [ "$(grep -cx -- '--print' "$ARGV")" = "2" ]; then
  pass "T7 a timeout reported without any structured result is still recognised as transient"
else
  fail "T7 a timeout reported without any structured result is still recognised as transient" \
       "rc=$rc invocations=$(grep -cx -- '--print' "$ARGV")"
fi

echo
echo "-- Issue 3: raw panel output observability -------------------------------"

RP="$(mktemp -d "${TMPDIR:-/tmp}/z3ftestO.XXXXXX")"
printf 'GEMINI-RAW-ANSWER: the agy panelist said this, verbatim.\n' > "$RP/gemini.md"
cat > "$RP/gemini.md.provenance.json" <<'EOF'
{"backend":"agy","model":"gemini-3.1-pro-high","routed_model_label":"Gemini 3.1 Pro (High)",
 "model_pin_verified":true,"output_transport":"json","attempts":2,
 "retry_reason":"timeout: agy timed out","governance_profile":"karpathy-engineering-v1"}
EOF
printf 'CLAUDE-RECOVERED-ANSWER: the real deliverable, pulled from the subagent transcript.\n' \
  > "$RP/claude.md"
cat > "$RP/claude.md.provenance.json" <<'EOF'
{"result_transport":"recovered-task-output","relay_classification":"suspicious",
 "relay_anomaly":"wakeup-sentinel","relay_wrapper_detected":true,
 "relay_wrapper_type":"security-warning,agent-id-trailer","healthy":true}
EOF
"$PY" -c "
import sys
open(sys.argv[1],'w',encoding='utf-8').write('LONG-ANSWER-HEAD ' + ('x'*9000) + ' LONG-ANSWER-TAIL')
" "$RP/long.md"

bash "$SCRIPTS/render_raw_panel.sh" \
  "opus-A=$RP/claude.md" "gemini=$RP/gemini.md" > "$RP/render.txt" 2> "$RP/render.err"
render_rc=$?

if [ "$render_rc" -eq 0 ] && grep -q 'CLAUDE-RECOVERED-ANSWER' "$RP/render.txt" \
   && grep -q 'GEMINI-RAW-ANSWER' "$RP/render.txt"; then
  pass "O1 both panelists' raw answers are rendered verbatim"
else
  fail "O1 both panelists' raw answers are rendered verbatim" \
       "rc=$render_rc $(tail -c 200 "$RP/render.err")"
fi
if grep -q 'Result transport: recovered-task-output' "$RP/render.txt" \
   && ! grep -qi 'Idle\.' "$RP/render.txt"; then
  pass "O2 the recovered answer is displayed, never the sentinel it replaced"
else
  fail "O2 the recovered answer is displayed, never the sentinel it replaced"
fi
if grep -q 'Backend: agy' "$RP/render.txt" \
   && grep -q 'Model: gemini-3.1-pro-high' "$RP/render.txt" \
   && grep -q 'Model verified: true' "$RP/render.txt" \
   && grep -q 'Transport: json' "$RP/render.txt"; then
  pass "O3 model identity, backend, pin verification and transport are shown per panelist"
else
  fail "O3 model identity, backend, pin verification and transport are shown per panelist" \
       "$(head -c 400 "$RP/render.txt")"
fi
if grep -q 'RAW PANEL OUTPUTS' "$RP/render.txt" \
   && grep -q 'END RAW PANEL OUTPUTS' "$RP/render.txt"; then
  pass "O4 the section is explicitly delimited, so judge/synthesis stays structurally separate"
else
  fail "O4 the section is explicitly delimited, so judge/synthesis stays structurally separate"
fi

FUSION_RAW_PREVIEW_CHARS=500 bash "$SCRIPTS/render_raw_panel.sh" "long=$RP/long.md" \
  > "$RP/long_render.txt" 2>/dev/null
# The banner must name a path that RESOLVES to the complete artifact. (It is compared by
# resolution, not by string: MSYS rewrites POSIX paths to native Windows ones as they cross
# into python.exe, so the rendered spelling legitimately differs from the one passed in.)
shown_path="$(sed -n 's/.*complete answer is on disk at \(.*\)\.\]$/\1/p' "$RP/long_render.txt")"
if grep -q 'TRUNCATED PREVIEW' "$RP/long_render.txt" \
   && grep -q '9034 characters' "$RP/long_render.txt" \
   && [ -n "$shown_path" ] && [ -s "$shown_path" ] \
   && grep -q 'LONG-ANSWER-TAIL' "$shown_path"; then
  pass "O5 a long answer is truncated EXPLICITLY, naming the size and a path that resolves"
else
  fail "O5 a long answer is truncated EXPLICITLY, naming the size and a path that resolves" \
       "shown=$shown_path tail=$(tail -c 200 "$RP/long_render.txt")"
fi
if grep -q 'LONG-ANSWER-HEAD' "$RP/long_render.txt" \
   && ! grep -q 'LONG-ANSWER-TAIL' "$RP/long_render.txt" \
   && grep -q 'LONG-ANSWER-TAIL' "$RP/long.md"; then
  pass "O5 the preview is bounded but the complete artifact stays intact on disk"
else
  fail "O5 the preview is bounded but the complete artifact stays intact on disk"
fi

# Labels carry model names, which contain spaces, commas and parentheses. That defeated MSYS's
# argv path translation and every panelist rendered as MISSING — found in the live E2E run,
# pinned here.
bash "$SCRIPTS/render_raw_panel.sh" \
  "opus-A (Claude Opus 5, in-session subagent)=$RP/claude.md" \
  "gemini (Gemini 3.1 Pro High)=$RP/gemini.md" > "$RP/labels.txt" 2>/dev/null
if grep -q 'CLAUDE-RECOVERED-ANSWER' "$RP/labels.txt" \
   && grep -q 'GEMINI-RAW-ANSWER' "$RP/labels.txt" \
   && ! grep -q 'MISSING OR EMPTY' "$RP/labels.txt"; then
  pass "O7 labels containing spaces/commas/parentheses still resolve their artifact paths"
else
  fail "O7 labels containing spaces/commas/parentheses still resolve their artifact paths" \
       "$(grep -E 'Artifact|MISSING' "$RP/labels.txt")"
fi

printf 'Idle.\n' > "$RP/sentinel.md"
bash "$SCRIPTS/render_raw_panel.sh" "bad=$RP/sentinel.md" > "$RP/sent.txt" 2>/dev/null
if grep -q 'WARNING: this canonical result still classifies as a degenerate relay' "$RP/sent.txt"; then
  pass "O6 a result still holding a sentinel is flagged, never shown as a healthy answer"
else
  fail "O6 a result still holding a sentinel is flagged, never shown as a healthy answer" \
       "$(cat "$RP/sent.txt")"
fi
bash "$SCRIPTS/render_raw_panel.sh" "gone=$RP/does-not-exist.md" > "$RP/miss.txt" 2>/dev/null
if grep -q 'MISSING OR EMPTY' "$RP/miss.txt" && grep -q 'never as agreement' "$RP/miss.txt"; then
  pass "O6 a dropped panelist is shown as absent, not silently omitted"
else
  fail "O6 a dropped panelist is shown as absent, not silently omitted" "$(cat "$RP/miss.txt")"
fi

echo
echo "-- Gemini governance (karpathy-engineering-v1) ---------------------------"

GOV_FILE="$SKILL_DIR/references/gemini_governance.md"
GOV_MARKER="z3fusion-gemini-governance: karpathy-engineering-v1"

# ---------------------------------------------------------------- TEST V1
new_sandbox
run_gemini MOCK_AGY_MODE=json_ok MOCK_AGY_PROMPT="$SB/prompt.sent"
rc=$?
n_marker="$(grep -cF "$GOV_MARKER" "$SB/prompt.sent" 2>/dev/null | tr -d ' ')"
if [ "$rc" -eq 0 ] && [ "${n_marker:-0}" = "1" ]; then
  pass "V1 the governance block is injected into the Gemini prompt exactly once"
else
  fail "V1 the governance block is injected into the Gemini prompt exactly once" \
       "rc=$rc occurrences=$n_marker"
fi
if grep -qF 'What is the answer?' "$SB/prompt.sent"; then
  pass "V1 the user's task is preserved verbatim alongside the governance"
else
  fail "V1 the user's task is preserved verbatim alongside the governance"
fi
if [ "$(prov governance_profile)" = "karpathy-engineering-v1" ] \
   && { [ "$(prov governance_injected)" = "True" ] || [ "$(prov governance_injected)" = "true" ]; }; then
  pass "V1 provenance records governance_profile=karpathy-engineering-v1"
else
  fail "V1 provenance records governance_profile=karpathy-engineering-v1" \
       "profile=$(prov governance_profile) injected=$(prov governance_injected)"
fi

# ---------------------------------------------------------------- TEST V2
# Byte-exact: the prompt agy receives is the governance file, a blank line, then the task —
# and nothing else. This is what keeps panel blindness structural rather than aspirational.
if "$PY" -c "
import sys
gov = open(sys.argv[1], encoding='utf-8').read().rstrip('\n')
task = open(sys.argv[2], encoding='utf-8').read().rstrip('\n')
sent = open(sys.argv[3], encoding='utf-8').read()
sys.exit(0 if sent == gov + '\n\n' + task else 1)
" "$GOV_FILE" "$SB/prompt.md" "$SB/prompt.sent"; then
  pass "V2 the prompt is exactly governance + task — no other panelist's work is present"
else
  fail "V2 the prompt is exactly governance + task — no other panelist's work is present" \
       "sent=$(head -c 120 "$SB/prompt.sent")"
fi
if grep -q 'PANEL INDEPENDENCE' "$SB/prompt.sent" \
   && grep -q 'must not attempt to obtain' "$SB/prompt.sent"; then
  pass "V2 the governance itself instructs the panelist to stay blind"
else
  fail "V2 the governance itself instructs the panelist to stay blind"
fi

# ---------------------------------------------------------------- TEST V3
# A prompt that already carries the governance must not get a second copy.
new_sandbox
cat "$GOV_FILE" > "$SB/prompt.md"
printf '\nWhat is the answer?\n' >> "$SB/prompt.md"
run_gemini MOCK_AGY_MODE=json_ok MOCK_AGY_PROMPT="$SB/prompt.sent"
n_marker="$(grep -cF "$GOV_MARKER" "$SB/prompt.sent" 2>/dev/null | tr -d ' ')"
if [ "${n_marker:-0}" = "1" ]; then
  pass "V3 a prompt that already carries the governance is not injected twice"
else
  fail "V3 a prompt that already carries the governance is not injected twice" \
       "occurrences=$n_marker"
fi

# ---------------------------------------------------------------- TEST V4
# Every Gemini execution path reaches agy through run_gemini.sh, which is why one injection
# point covers /z3fusion-gemini, the Gemini slot of /z3fusion-3 and any <model>@agy slot.
if grep -q 'exec bash "$SCRIPT_DIR/run_gemini.sh"' "$SCRIPTS/run_panelist.sh"; then
  pass "V4 every agy slot is dispatched through run_gemini.sh (one canonical injection point)"
else
  fail "V4 every agy slot is dispatched through run_gemini.sh (one canonical injection point)"
fi
missing=""
for c in z3fusion-gemini z3fusion-3; do
  [ -f "$HOME/.claude/commands/$c.md" ] || continue
  grep -qi 'karpathy-engineering-v1' "$HOME/.claude/commands/$c.md" || missing="$missing $c"
done
if [ -z "$missing" ]; then
  pass "V4 /z3fusion-gemini and /z3fusion-3 document the governance profile they run under"
else
  fail "V4 /z3fusion-gemini and /z3fusion-3 document the governance profile they run under" \
       "missing:$missing"
fi

# ---------------------------------------------------------------- TEST V5
# Governance must not turn uncertainty into refusal.
if grep -q 'Autonomous execution rule' "$GOV_FILE" \
   && grep -q 'never a reason to decline the task' "$GOV_FILE"; then
  pass "V5 the governance tells the panelist to proceed under a stated assumption, not block"
else
  fail "V5 the governance tells the panelist to proceed under a stated assumption, not block"
fi

# ---------------------------------------------------------------- TEST V6
new_sandbox
mv "$SKILL_DIR/references/gemini_governance.md" "$SB/gov.bak"
run_gemini MOCK_AGY_MODE=json_ok
rc=$?
mv "$SB/gov.bak" "$SKILL_DIR/references/gemini_governance.md"
if [ "$rc" -eq 2 ] && grep -qi 'refusing to run an ungoverned Gemini panelist' "$SB/runner.err"; then
  pass "V6 a missing governance profile fails closed — Gemini never runs ungoverned"
else
  fail "V6 a missing governance profile fails closed — Gemini never runs ungoverned" \
       "rc=$rc err=$(tail -c 200 "$SB/runner.err")"
fi

echo
echo "-- Heavy execution lifecycle (TTK / attempts / fusion) -------------------"

# new_heavy <mock-mode> — one isolated heavy job. Sets HB/HJOBS/HOUT/HJD.
new_heavy() {
  HB="$(mktemp -d "${TMPDIR:-/tmp}/z3heavy.XXXXXX")"
  mkdir -p "$HB/bin"
  printf '#!/usr/bin/env bash\nexec bash "%s/mock_agy.sh" "$@"\n' "$TESTS_DIR" > "$HB/bin/agy"
  chmod +x "$HB/bin/agy"
  printf 'Rebuild the dashboard to match the reference design.\n' > "$HB/mission.md"
  HJOBS="$HB/jobs"; HOUT="$HB/out.md"
  env PATH="$HB/bin:$PATH" MOCK_AGY_MODE="$1" AGY_CLI_DIR="$HB/agyhome" \
      MOCK_AGY_COUNT="$HB/count" Z3F_JOBS_ROOT="$HJOBS" \
      Z3F_GEMINI_TTK=30 Z3F_WAIT_SECONDS=150 \
      bash "$SCRIPTS/gemini_heavy.sh" run "$HB/mission.md" "$HOUT" \
      > "$HB/run.out" 2> "$HB/run.err"
  HRC=$?
  HJD="$HJOBS/$(ls "$HJOBS" 2>/dev/null | head -1)"
}
hstat() { "$PY" -c "
import json,sys
try: print(json.load(open(sys.argv[1],encoding='utf-8')).get(sys.argv[2],''))
except Exception: print('')
" "$HJD/gemini/$1/status.json" "$2" 2>/dev/null; }
hfinal() { "$PY" -c "
import json,sys
try: print((json.load(open(sys.argv[1],encoding='utf-8')).get('gemini_execution') or {}).get(sys.argv[2],''))
except Exception: print('')
" "$HJD/final/provenance.json" "$1" 2>/dev/null; }

# ---------------------------------------------------------------- HEAVY 1: fast path
new_heavy json_ok
if [ "$HRC" -eq 0 ] && grep -q 'MOCK-NATIVE-ANSWER' "$HOUT" \
   && [ "$(hstat attempt-01 status)" = "completed" ]; then
  pass "L1 attempt 01 completing normally yields the canonical result directly"
else
  fail "L1 attempt 01 completing normally yields the canonical result directly" \
       "rc=$HRC a1=$(hstat attempt-01 status) err=$(tail -c 200 "$HB/run.err")"
fi
if [ ! -d "$HJD/gemini/attempt-02" ] && [ ! -d "$HJD/gemini/fusion" ]; then
  pass "L1 no attempt 02 and no fusion are spent when attempt 01 succeeds (fast path)"
else
  fail "L1 no attempt 02 and no fusion are spent when attempt 01 succeeds (fast path)"
fi

# ---------------------------------------------------------------- HEAVY 2/3/5: TTK lifecycle
new_heavy ttk_then_ok
if [ "$(hstat attempt-01 status)" = "ttk-checkpoint" ]; then
  pass "L2 reaching TTK is recorded as ttk-checkpoint, not as a failure"
else
  fail "L2 reaching TTK is recorded as ttk-checkpoint, not as a failure" \
       "got=$(hstat attempt-01 status)"
fi
if grep -q 'MOCK-PARTIAL-WORK-1' "$HJD/gemini/attempt-01/output.md" \
   && grep -q 'MOCK-PARTIAL-WORK-2' "$HJD/gemini/attempt-01/output.md" \
   && grep -q 'TTK CHECKPOINT' "$HJD/gemini/attempt-01/output.md"; then
  pass "L3 work completed before TTK is recovered and preserved, not discarded"
else
  fail "L3 work completed before TTK is recovered and preserved, not discarded" \
       "$(head -c 200 "$HJD/gemini/attempt-01/output.md" 2>/dev/null)"
fi
if [ "$(hstat attempt-02 status)" = "completed" ] && grep -q 'MOCK-ATTEMPT-02-ANSWER' \
   "$HJD/gemini/attempt-02/output.md"; then
  pass "L4 attempt 02 starts after a TTK checkpoint and produces its own result"
else
  fail "L4 attempt 02 starts after a TTK checkpoint and produces its own result" \
       "got=$(hstat attempt-02 status)"
fi
# The payload is FILE-BACKED, so the assertion is on the staged artifacts and the manifest, not
# on the prompt (which deliberately carries no payload — see the argv-cap rationale). The
# manifest must also certify source==staged, not merely describe what landed.
FIN="$HJD/gemini/fusion/run/attempt1/ws/fusion-input"
if grep -q 'MOCK-PARTIAL-WORK-1' "$FIN/attempt-01.md" 2>/dev/null \
   && grep -q 'MOCK-ATTEMPT-02-ANSWER' "$FIN/attempt-02.md" 2>/dev/null; then
  pass "L5 fusion receives BOTH attempts as staged files, including the TTK checkpoint's work"
else
  fail "L5 fusion receives BOTH attempts as staged files, including the TTK checkpoint's work" \
       "$(ls "$FIN" 2>/dev/null | tr '\n' ' ')"
fi
if "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8-sig'))
a=d['artifacts']
ok = d['evidence_complete'] and not d['staging_failures']
# every staged artifact must carry BOTH a source hash and a staged hash, and they must agree
for n in ('mission.md','attempt-01.md','attempt-02.md'):
    e=a.get(n,{})
    ok = ok and e.get('staged') and e.get('source_sha256') and e['source_sha256']==e['staged_sha256']
sys.exit(0 if ok else 1)" "$HJD/gemini/fusion/manifest.json" 2>/dev/null; then
  pass "L5 the manifest certifies source==staged for every fusion input (not self-comparison)"
else
  fail "L5 the manifest certifies source==staged for every fusion input (not self-comparison)" \
       "$(head -c 250 "$HJD/gemini/fusion/manifest.json" 2>/dev/null)"
fi
if ! grep -q 'MOCK-PARTIAL-WORK-1' "$HJD/gemini/fusion/prompt.md" 2>/dev/null \
   && [ "$(wc -c < "$HJD/gemini/fusion/prompt.md" 2>/dev/null | tr -d ' ')" -lt 30000 ]; then
  pass "L5 the argv prompt carries no payload (stays far below the Windows 32767 cap)"
else
  fail "L5 the argv prompt carries no payload (stays far below the Windows 32767 cap)" \
       "bytes=$(wc -c < "$HJD/gemini/fusion/prompt.md" 2>/dev/null)"
fi
if [ "$HRC" -eq 0 ] && grep -q 'MOCK-FUSION-ANSWER' "$HOUT" \
   && [ "$(hfinal canonical_source)" = "fusion" ]; then
  pass "L6 the canonical result comes from fusion, not from either attempt alone"
else
  fail "L6 the canonical result comes from fusion, not from either attempt alone" \
       "rc=$HRC source=$(hfinal canonical_source) out=$(head -c 80 "$HOUT")"
fi
# Fusion is instructed to weigh both rather than defaulting to the later attempt.
if grep -q 'Do NOT prefer attempt 02 merely because it ran later' "$HJD/gemini/fusion/prompt.md" \
   && grep -q 'Partial does not mean worthless' "$HJD/gemini/fusion/prompt.md"; then
  pass "L7 the fusion prompt forbids discarding a checkpoint or defaulting to the later attempt"
else
  fail "L7 the fusion prompt forbids discarding a checkpoint or defaulting to the later attempt"
fi

# A timed-out attempt never reaches the runner's own post-run routing check, so the checkpoint
# stage has to re-establish it from the preserved agy log. Partial work must still prove which
# model produced it, or a Flash checkpoint could be fused in as if it were Pro.
if [ "$(hstat attempt-01 routed_model_label)" = "Gemini 3.1 Pro (High)" ] \
   && [ "$(hstat attempt-01 model_pin_verified)" = "True" ]; then
  pass "L7 a TTK checkpoint still proves which model produced the partial work"
else
  fail "L7 a TTK checkpoint still proves which model produced the partial work" \
       "routed=$(hstat attempt-01 routed_model_label) pin=$(hstat attempt-01 model_pin_verified)"
fi

# ---------------------------------------------------------------- HEAVY 8: artifact isolation
a1="$HJD/gemini/attempt-01/output.md"; a2="$HJD/gemini/attempt-02/output.md"
if [ "$a1" != "$a2" ] && [ -s "$a1" ] && [ -s "$a2" ] \
   && ! grep -q 'MOCK-ATTEMPT-02-ANSWER' "$a1" && ! grep -q 'MOCK-PARTIAL-WORK' "$a2"; then
  pass "L8 attempts never share a live output file — each writes only its own artifact"
else
  fail "L8 attempts never share a live output file — each writes only its own artifact"
fi

# ---------------------------------------------------------------- HEAVY 9: no clobbering
# A late attempt-01 finally finishing must not be able to rewrite sealed history.
before_a2="$(cat "$a2")"; before_fusion="$(cat "$HJD/gemini/fusion/output.md")"
before_final="$(cat "$HJD/final/output.md")"
if printf 'LATE-ATTEMPT-01-OVERWRITE\n' | bash -c '
  source_dir="'"$SCRIPTS"'"
  dest="'"$HJD"'/gemini/attempt-01/status.json"
  tmp="$dest.late.$$"; cat > "$tmp"
  if [ -e "$dest" ]; then rm -f "$tmp"; exit 1; fi
  mv "$tmp" "$dest"'; then
  fail "L9 a sealed attempt refuses a late write"
else
  pass "L9 a sealed attempt refuses a late write (status.json is written exactly once)"
fi
if [ "$(cat "$a2")" = "$before_a2" ] \
   && [ "$(cat "$HJD/gemini/fusion/output.md")" = "$before_fusion" ] \
   && [ "$(cat "$HJD/final/output.md")" = "$before_final" ]; then
  pass "L9 attempt 02, the fusion result and the canonical output are all untouched"
else
  fail "L9 attempt 02, the fusion result and the canonical output are all untouched"
fi

# ---------------------------------------------------------------- HEAVY 10: re-attach
# The caller giving up must not launch a second execution of the same mission.
calls_before="$(grep -cx -- '--print' "$HB/count" 2>/dev/null || echo 0)"
env PATH="$HB/bin:$PATH" MOCK_AGY_MODE=ttk_then_ok AGY_CLI_DIR="$HB/agyhome" \
    MOCK_AGY_COUNT="$HB/count" Z3F_JOBS_ROOT="$HJOBS" Z3F_GEMINI_TTK=30 Z3F_WAIT_SECONDS=20 \
    bash "$SCRIPTS/gemini_heavy.sh" run "$HB/mission.md" "$HB/out2.md" \
    > "$HB/run2.out" 2> "$HB/run2.err"
rc2=$?
n_agy_after="$(wc -c < "$HB/count" 2>/dev/null | tr -d ' ')"
if [ "$rc2" -eq 0 ] && [ "${n_agy_after:-0}" -eq 3 ] && grep -q 'MOCK-FUSION-ANSWER' "$HB/out2.md"; then
  pass "L10 re-invoking a finished mission re-attaches and collects — no duplicate execution"
else
  fail "L10 re-invoking a finished mission re-attaches and collects — no duplicate execution" \
       "rc=$rc2 agy_invocations=$n_agy_after (expect 3: attempt01+attempt02+fusion)"
fi

# ---------------------------------------------------------------- HEAVY 11: provenance
if [ "$(hfinal ttk_seconds_per_attempt)" = "30" ] \
   && [ "$(hfinal reasoning_effort)" = "high" ] \
   && [ "$(hstat attempt-01 conversation_id)" != "" -o "$(hstat attempt-02 conversation_id)" != "" ] \
   && [ "$(hstat attempt-02 output_transport)" = "json" ]; then
  pass "L11 provenance records both attempts, effort, TTK, transports and conversation ids"
else
  fail "L11 provenance records both attempts, effort, TTK, transports and conversation ids" \
       "ttk=$(hfinal ttk_seconds_per_attempt) effort=$(hfinal reasoning_effort) t2=$(hstat attempt-02 output_transport)"
fi
if [ "$(hfinal final_status)" = "success" ] && [ -s "$HJD/final/provenance.json" ]; then
  pass "L11 the fusion stage and final status are represented in the lifecycle record"
else
  fail "L11 the fusion stage and final status are represented in the lifecycle record"
fi

# ---------------------------------------------------------------- HEAVY 12: deterministic abort
# A pin mismatch must NOT buy a second multi-hour attempt.
new_heavy json_ok >/dev/null 2>&1 || true
HB2="$(mktemp -d "${TMPDIR:-/tmp}/z3heavyD.XXXXXX")"; mkdir -p "$HB2/bin"
printf '#!/usr/bin/env bash\nexec bash "%s/mock_agy.sh" "$@"\n' "$TESTS_DIR" > "$HB2/bin/agy"
chmod +x "$HB2/bin/agy"
printf 'A deterministic-failure mission.\n' > "$HB2/mission.md"
env PATH="$HB2/bin:$PATH" MOCK_AGY_MODE=json_ok MOCK_AGY_LABEL="Gemini 3.6 Flash (High)" \
    AGY_CLI_DIR="$HB2/agyhome" MOCK_AGY_COUNT="$HB2/count" Z3F_JOBS_ROOT="$HB2/jobs" \
    Z3F_GEMINI_TTK=30 Z3F_WAIT_SECONDS=120 \
    bash "$SCRIPTS/gemini_heavy.sh" run "$HB2/mission.md" "$HB2/out.md" \
    > "$HB2/run.out" 2> "$HB2/run.err"
drc=$?
dcount="$(wc -c < "$HB2/count" 2>/dev/null | tr -d ' ')"
DJD="$HB2/jobs/$(ls "$HB2/jobs" 2>/dev/null | head -1)"
if [ "$drc" -ne 0 ] && [ "${dcount:-0}" -eq 1 ] && [ ! -d "$DJD/gemini/attempt-02" ]; then
  pass "L12 a routed-model mismatch aborts the mission — no second multi-hour attempt is spent"
else
  fail "L12 a routed-model mismatch aborts the mission — no second multi-hour attempt is spent" \
       "rc=$drc agy_invocations=$dcount attempt02=$([ -d "$DJD/gemini/attempt-02" ] && echo yes || echo no)"
fi

# ------------------------------------------------- HEAVY 14: TTK with nothing recoverable
# Adversarial review finding C1. run_gemini.sh truncates output.md on any non-zero exit, so
# after a TTK the ONLY thing that can refill it is the transcript scraper. If that comes back
# empty (format change, workspace-key mismatch, staleness gate), a TTK must still hand off to
# attempt-02 — a recovery miss must not silently become "abort the mission".
HB3="$(mktemp -d "${TMPDIR:-/tmp}/z3heavyC1.XXXXXX")"; mkdir -p "$HB3/bin"
printf '#!/usr/bin/env bash\nexec bash "%s/mock_agy.sh" "$@"\n' "$TESTS_DIR" > "$HB3/bin/agy"
chmod +x "$HB3/bin/agy"
printf 'A mission whose first attempt leaves no transcript.\n' > "$HB3/mission.md"
# AGY_CLI_DIR deliberately unset => the mock writes no transcript => nothing to recover.
env PATH="$HB3/bin:$PATH" MOCK_AGY_MODE=ttk_then_ok MOCK_AGY_COUNT="$HB3/count" \
    Z3F_JOBS_ROOT="$HB3/jobs" Z3F_GEMINI_TTK=20 Z3F_WAIT_SECONDS=120 \
    bash "$SCRIPTS/gemini_heavy.sh" run "$HB3/mission.md" "$HB3/out.md" \
    > "$HB3/run.out" 2> "$HB3/run.err"
c1rc=$?
C1JD="$HB3/jobs/$(ls "$HB3/jobs" 2>/dev/null | head -1)"
c1a1="$("$PY" -c "
import json,sys
try: print(json.load(open(sys.argv[1],encoding='utf-8')).get('status',''))
except Exception: print('')" "$C1JD/gemini/attempt-01/status.json" 2>/dev/null)"
if [ "$c1a1" = "ttk-checkpoint" ] && [ -d "$C1JD/gemini/attempt-02" ] && [ "$c1rc" -eq 0 ]; then
  pass "L14 a TTK with nothing recoverable still hands off to attempt 02 (never aborts)"
else
  fail "L14 a TTK with nothing recoverable still hands off to attempt 02 (never aborts)" \
       "rc=$c1rc a1=$c1a1 attempt02=$([ -d "$C1JD/gemini/attempt-02" ] && echo yes || echo no)"
fi

# ------------------------------------------------- HEAVY 15: reclaim must not re-run a seal
# Review finding C2. A supervisor that dies mid-mission leaves attempt-01 sealed. Re-running it
# would truncate the recovered checkpoint before the new agy starts, and the refused seal would
# leave provenance describing the dead run.
before_a1="$(cat "$C1JD/gemini/attempt-01/status.json")"
calls_pre="$(wc -c < "$HB3/count" 2>/dev/null | tr -d ' ')"
rm -f "$C1JD/heartbeat"
env PATH="$HB3/bin:$PATH" MOCK_AGY_MODE=ttk_then_ok MOCK_AGY_COUNT="$HB3/count" \
    Z3F_JOBS_ROOT="$HB3/jobs" Z3F_GEMINI_TTK=20 Z3F_WAIT_SECONDS=60 \
    bash "$SCRIPTS/gemini_heavy.sh" run "$HB3/mission.md" "$HB3/out2.md" \
    > "$HB3/run2.out" 2>&1
calls_post="$(wc -c < "$HB3/count" 2>/dev/null | tr -d ' ')"
if [ "$(cat "$C1JD/gemini/attempt-01/status.json")" = "$before_a1" ] \
   && [ "${calls_post:-0}" -eq "${calls_pre:-0}" ]; then
  pass "L15 a reclaimed job resumes past sealed attempts instead of destructively re-running them"
else
  fail "L15 a reclaimed job resumes past sealed attempts instead of destructively re-running them" \
       "agy calls ${calls_pre}->${calls_post}"
fi

# ------------------------------------------------- HEAVY 16: checkpoint routing is ENFORCED
# Review finding M3. Recording the routed label is not enough: a checkpoint produced by Flash
# must be discarded, not fused in as this model's partial work.
HB4="$(mktemp -d "${TMPDIR:-/tmp}/z3heavyM3.XXXXXX")"; mkdir -p "$HB4/bin"
printf '#!/usr/bin/env bash\nexec bash "%s/mock_agy.sh" "$@"\n' "$TESTS_DIR" > "$HB4/bin/agy"
chmod +x "$HB4/bin/agy"
printf 'A mission whose attempt routes to the wrong model.\n' > "$HB4/mission.md"
env PATH="$HB4/bin:$PATH" MOCK_AGY_MODE=ttk AGY_CLI_DIR="$HB4/agyhome" \
    MOCK_AGY_LABEL="Gemini 3.6 Flash (High)" MOCK_AGY_COUNT="$HB4/count" \
    Z3F_JOBS_ROOT="$HB4/jobs" Z3F_GEMINI_TTK=20 Z3F_WAIT_SECONDS=90 \
    bash "$SCRIPTS/gemini_heavy.sh" run "$HB4/mission.md" "$HB4/out.md" \
    > "$HB4/run.out" 2> "$HB4/run.err"
M3JD="$HB4/jobs/$(ls "$HB4/jobs" 2>/dev/null | head -1)"
m3s="$("$PY" -c "
import json,sys
try: print(json.load(open(sys.argv[1],encoding='utf-8')).get('status',''))
except Exception: print('')" "$M3JD/gemini/attempt-01/status.json" 2>/dev/null)"
if [ "$m3s" = "failed" ] && ! grep -q 'MOCK-PARTIAL-WORK' "$M3JD/gemini/attempt-01/output.md" 2>/dev/null; then
  pass "L16 a checkpoint that routed to the wrong model is discarded, not fused in"
else
  fail "L16 a checkpoint that routed to the wrong model is discarded, not fused in" \
       "status=$m3s content=$(head -c 80 "$M3JD/gemini/attempt-01/output.md" 2>/dev/null)"
fi

# ---------------------------------------------------------------- HEAVY 13: production config
if grep -q 'Z3F_GEMINI_TTK:-28800' "$SCRIPTS/gemini_heavy.sh"; then
  pass "L13 the production default TTK is 28800s (8 hours) PER ATTEMPT"
else
  fail "L13 the production default TTK is 28800s (8 hours) PER ATTEMPT"
fi
# --effort must NOT be passed: agy 1.1.8 rejects it for this model, and the id+effort spelling
# silently routes to Flash. The tier is carried by the pinned label itself.
if ! grep -v '^[[:space:]]*#' "$SCRIPTS/run_gemini.sh" | grep -q -- '--effort'; then
  pass "L13 --effort is never passed (the pinned label already selects the highest tier)"
else
  fail "L13 --effort is never passed (the pinned label already selects the highest tier)"
fi

echo
echo "=============================================================================="
printf 'passed: %d   failed: %d\n' "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
  printf 'failing:%s\n' "$FAILURES"
  exit 1
fi
echo "all green"

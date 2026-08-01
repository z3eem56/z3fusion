#!/usr/bin/env bash
# run_gemini.sh — run one Gemini panelist (via the `agy` / Antigravity CLI), web + bash.
#
# Usage:
#   run_gemini.sh <prompt_file> <output_file>
#
# ---------------------------------------------------------------------------------------
# MODEL PIN (hard requirement)
# ---------------------------------------------------------------------------------------
# This runner ALWAYS passes an explicit `--model <runtime id>` to agy. It never relies on
# agy's configured default (`~/.gemini/antigravity-cli/settings.json`), and it never
# substitutes a different model — not Flash, not another Pro tier, not automatic routing.
# If the pinned model is unavailable the panelist FAILS with
#   required model unavailable: <model>
# and the orchestrator degrades the panel per SKILL.md Step 2. Degradation is a PANEL-level
# policy; this runner does not degrade the model.
#
# Logical slot name -> agy runtime id. `agy models` is the authority on the right-hand side.
# Note `--model gemini-3.1-pro` alone is REJECTED by agy 1.1.8 ("requires --effort"), so the
# tier is part of the pin and is never inferred at runtime.
#
# ---------------------------------------------------------------------------------------
# GEMINI GOVERNANCE (profile: karpathy-engineering-v1)
# ---------------------------------------------------------------------------------------
# This runner is the single canonical injection point for Gemini behavioral governance.
# Every Gemini execution path in z3Fusion reaches agy through here — `/z3fusion-gemini`, the
# Gemini slot of `/z3fusion-3`, and any `<model>@agy` slot of `/z3fusion --models` all go
# through run_panelist.sh, which `exec`s this script. Injecting once, here, is what makes the
# governance impossible to bypass and impossible to duplicate across commands.
#
# The block is prepended to the panel prompt; the task itself follows and stays authoritative
# about WHAT to produce. If the incoming prompt already carries the marker, it is NOT injected
# again — the block appears exactly once, always.
#
# ---------------------------------------------------------------------------------------
# OUTPUT TRANSPORT (layered, deterministic — first one that yields a usable answer wins)
# ---------------------------------------------------------------------------------------
#   LEVEL 1  json                        `--print --output-format json`, parse `.response`.
#                                        Verified clean on Windows/Git-Bash with agy 1.1.8.
#   LEVEL 2  stdout-text                 `--output-format text` — only when the structured
#                                        output is unparseable/unsupported (a CAPABILITY
#                                        problem), not when the model simply returned empty.
#   LEVEL 3  windows-transcript-fallback exit 0 + empty stdout (the historical agy bug #76
#                                        behavior): read the answer back out of agy's own
#                                        transcript for THIS invocation only.
#
# agy bug #76 (empty stdout with no TTY) is FIXED as of agy 1.1.8 — both json and text print
# modes capture cleanly with no PTY. The pseudo-TTY path is therefore gone and transcript
# scraping is a compatibility fallback, not the expected transport.
#
# Stale-transcript safety: every ATTEMPT runs in its OWN fresh workspace dir, so agy opens a
# NEW conversation whose id is looked up from agy's own cache keyed by that workspace (and, on
# the json path, read straight out of agy's stdout). A transcript is additionally rejected
# unless it was modified at/after that attempt started. A previous run's — or a previous
# attempt's — transcript can therefore never be mistaken for this one.
#
# A non-zero agy exit is NEVER masked by transcript recovery.
#
# ---------------------------------------------------------------------------------------
# BOUNDED AUTOMATIC RETRY
# ---------------------------------------------------------------------------------------
# Attempt 1 runs at FUSION_TIMEOUT. If — and only if — it fails for a TRANSIENT reason, one
# retry runs at FUSION_TIMEOUT * AGY_RETRY_FACTOR in a completely fresh attempt directory and
# workspace, so attempt 2 can never read attempt 1's stdout, log, parsed result or transcript.
# Two attempts maximum; no loop, no silent retry.
#
# Retried (transient): our own timeout backstop firing; agy reporting a timeout / deadline
# exceeded / temporarily-unavailable / connection-reset condition; an empty result that came
# with timeout evidence.
# NEVER retried (deterministic — a second attempt cannot change the answer): a routed-model
# mismatch, an unavailable pinned model, an authentication/quota rejection needing user
# action, a rejected stale transcript, bad usage, or any upstream error with no transient
# evidence.
#
# Config (env):
#   AGY_MODEL         logical or runtime model name (default/blank -> gemini-3.1-pro-high).
#   FUSION_TIMEOUT    per-panelist budget in seconds for attempt 1 (default 300).
#   AGY_MAX_ATTEMPTS  internal; default 2, clamped to 1..3. Not part of the public interface.
#
# Exit codes: 0 ok | 1 failure (incl. model unavailable / empty answer) | 124 timeout |
#             127 agy CLI not installed | 2 bad usage / broken install.
#
# Side effect: writes "<output_file>.provenance.json" describing the invocation (backend,
# requested/runtime model, model_pin_verified, exit_code, output_transport, conversation_id,
# the per-attempt retry record, and the governance profile) and echoes a one-line summary on
# stdout for the orchestrator.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_fusion_lib.sh"

prompt_file="${1:?usage: run_gemini.sh <prompt_file> <output_file>}"
output_file="${2:?usage: run_gemini.sh <prompt_file> <output_file>}"

# --- Authoritative model mapping ------------------------------------------------------
# Three distinct things, deliberately kept separate:
#   canonical_model  z3Fusion's identity for the slot, and what provenance reports.
#                    Matches the id `agy models` prints.
#   agy_model_arg    what actually goes after `--model` on the command line.
#   expected_label   the backend model label agy must end up routing to, verified after the
#                    run against agy's own log. This is the real guarantee.
#
# WHY agy_model_arg IS THE DISPLAY LABEL, NOT THE ID (agy 1.1.8, verified on this box):
# passing the runtime id makes agy log
#     resolver.go: Model ID gemini-3.1-pro-high not in local config, defaulting to CCPA
#     model_config_manager.go: Propagating selected model override to backend:
#         label="Gemini 3.6 Flash (High)"
# i.e. the id is accepted by the flag validator but SILENTLY DOWNGRADED TO FLASH at the
# backend, because the id table is fetched from the server and that fetch fails
# ("You are not logged into Antigravity"). Passing the display label resolves correctly:
#     Propagating selected model override to backend: label="Gemini 3.1 Pro (High)"
# So the label is what pins the model in practice. Either way the routed label is verified
# after every run — a downgrade fails the panelist instead of quietly answering as Flash.
agy_resolve_model() {
  case "$1" in
    ""|gemini-3.1-pro|gemini3.1pro|gemini-3.1|gemini-3.1-pro-high|"Gemini 3.1 Pro"|"Gemini 3.1 Pro (High)")
      canonical_model="gemini-3.1-pro-high"
      agy_model_arg="Gemini 3.1 Pro (High)"
      expected_label="Gemini 3.1 Pro (High)"
      ;;
    gemini-3.1-pro-low|"Gemini 3.1 Pro (Low)")
      canonical_model="gemini-3.1-pro-low"
      agy_model_arg="Gemini 3.1 Pro (Low)"
      expected_label="Gemini 3.1 Pro (Low)"
      ;;
    *)
      # Any other agy model: pass the caller's spelling through untouched. The routed label
      # is unknown for these, so it is reported in provenance rather than hard-verified.
      canonical_model="$1"
      agy_model_arg="$1"
      expected_label=""
      ;;
  esac
}

canonical_model=""; agy_model_arg=""; expected_label=""
requested_model="${AGY_MODEL:-}"
agy_resolve_model "$requested_model"
runtime_model="$canonical_model"
[ -n "$requested_model" ] || requested_model="$canonical_model"
routed_label=""

# Bounded retry policy.
AGY_MAX_ATTEMPTS="${AGY_MAX_ATTEMPTS:-2}"
case "$AGY_MAX_ATTEMPTS" in
  1|2|3) ;;
  *) AGY_MAX_ATTEMPTS=2 ;;
esac
AGY_RETRY_FACTOR=2

# Gemini governance profile (see references/gemini_governance.md).
GOVERNANCE_PROFILE="karpathy-engineering-v1"
GOVERNANCE_MARKER="z3fusion-gemini-governance: $GOVERNANCE_PROFILE"
governance_file="$(cd "$SCRIPT_DIR/.." && pwd)/references/gemini_governance.md"
governance_injected="false"

if ! have agy; then
  echo "[run_gemini.sh] agy CLI not installed — skip this panelist." >&2
  exit 127
fi

if [ ! -s "$prompt_file" ]; then
  echo "[run_gemini.sh] prompt file is missing or empty: $prompt_file" >&2
  exit 2
fi

# Governance ships with the skill. If it is gone the install is broken, and running anyway
# would be exactly the silent requirement drift rule 7 of the governance forbids.
if [ ! -s "$governance_file" ]; then
  echo "[run_gemini.sh] governance profile missing: $governance_file — refusing to run an ungoverned Gemini panelist. Reinstall the skill (the file ships in references/)." >&2
  exit 2
fi

# Heavy/long-running missions (hours, not minutes) run under the attempt-lifecycle supervisor
# instead of this single synchronous invocation: TTK checkpointing, attempt isolation, fusion
# and job re-attach all live there. gemini_heavy.sh calls back into this script once per
# attempt with Z3F_GEMINI_HEAVY=0, which is what terminates the delegation.
if [ "${Z3F_GEMINI_HEAVY:-0}" = "1" ]; then
  exec bash "$SCRIPT_DIR/gemini_heavy.sh" run "$prompt_file" "$output_file"
fi

mkdir -p "$(dirname "$output_file")" 2>/dev/null
: > "$output_file"

# Scratch holds each attempt's workspace, agy log, raw stdout and parsed result. Normally it is
# a temp dir wiped on exit. When the caller sets Z3F_ARTIFACT_DIR it becomes a PERSISTENT
# artifact dir that this script must not delete — the heavy-execution lifecycle
# (gemini_heavy.sh) needs the agy log and the workspace to survive so a TTK checkpoint can be
# recovered from that attempt's conversation after the process is gone. A cleanup trap here
# would destroy exactly the evidence the checkpoint stage exists to preserve.
if [ -n "${Z3F_ARTIFACT_DIR:-}" ]; then
  scratch="$Z3F_ARTIFACT_DIR"
  mkdir -p "$scratch"
else
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/z3fusion-gemini.XXXXXX")"
  trap 'rm -rf "$scratch"' EXIT
fi

provenance_file="${output_file}.provenance.json"
transport=""
conversation_id=""
exit_code=""
model_pin_verified="false"

# Per-attempt state, reset by _run_attempt.
attempt_dir=""
workspace=""
start_epoch=""
attempt_rc=""
attempt_status="failure"
attempt_retryable="no"
attempt_msg=""
used_fmt="json"

# Retry record, reported verbatim in provenance.
attempts=0
attempt_1_status=""
attempt_1_rc=""
attempt_2_status="not-run"
retry_reason=""
final_status="failure"

# _write_provenance <status>
_write_provenance() {
  STATUS="$1" BACKEND="agy" REQ="$requested_model" RUN="$runtime_model" \
  ARG="$agy_model_arg" ROUTED="$routed_label" \
  PINOK="$model_pin_verified" RC="${exit_code:-}" TRANSPORT="$transport" \
  CONV="$conversation_id" OUT="$provenance_file" \
  ATTEMPTS="$attempts" A1S="$attempt_1_status" A1RC="${attempt_1_rc:-}" \
  A2S="$attempt_2_status" RETRY="$retry_reason" FINAL="$final_status" \
  GOVPROF="$GOVERNANCE_PROFILE" GOVIN="$governance_injected" \
  "$FUSION_PY" - <<'PYEOF' 2>/dev/null
import json, os

def as_int(name):
    v = os.environ.get(name, "").strip()
    return int(v) if v.lstrip("-").isdigit() else None

doc = {
    "backend": os.environ["BACKEND"],
    "requested_model": os.environ["REQ"],
    "model": os.environ["RUN"],
    "runtime_backend": "agy",
    "agy_model_arg": os.environ["ARG"],
    "routed_model_label": os.environ["ROUTED"] or None,
    "model_pin_verified": os.environ["PINOK"] == "true",
    "exit_code": as_int("RC"),
    "output_transport": os.environ["TRANSPORT"] or None,
    "conversation_id": os.environ["CONV"] or None,
    "attempts": as_int("ATTEMPTS"),
    "attempt_1_status": os.environ["A1S"] or None,
    "attempt_1_exit_code": as_int("A1RC"),
    "retry_reason": os.environ["RETRY"] or None,
    "attempt_2_status": os.environ["A2S"] or None,
    "final_status": os.environ["FINAL"],
    "governance_profile": os.environ["GOVPROF"],
    "governance_injected": os.environ["GOVIN"] == "true",
    "status": os.environ["STATUS"],
}
with open(os.environ["OUT"], "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PYEOF
}

# _fail <exit_code> <message...> — provenance + diagnostic, then exit. The answer file is
# truncated so a rejected answer (wrong model, stale transcript, masked error) can never be
# picked up by the orchestrator as if it were a valid panel result.
_fail() {
  local rc="$1"; shift
  echo "[run_gemini.sh] $*" >&2
  : > "$output_file" 2>/dev/null
  _write_provenance "failed"
  exit "$rc"
}

# _attempt_fail <status: timeout|failure> <retryable: yes|no> <message...>
# Records why THIS attempt failed. The driver decides whether to retry; call sites always
# follow this with `return 1`.
_attempt_fail() {
  attempt_status="$1"
  attempt_retryable="$2"
  shift 2
  attempt_msg="$*"
}

# _is_blank <file> — true when the file is missing, empty, or whitespace-only.
_is_blank() {
  [ -f "$1" ] && [ -s "$1" ] || return 0
  local n
  n="$(LC_ALL=C tr -d '[:space:]' < "$1" | wc -c | tr -d ' ')"
  [ "${n:-0}" -eq 0 ]
}

# _retry_verdict <text...> — "yes" only for evidence that a longer/fresh attempt could fix.
# The deny-list is checked FIRST so "auth failed after timeout" is never retried.
_retry_verdict() {
  if printf '%s' "$*" | grep -qiE 'not logged in|unauthori[sz]ed|authentication|auth failed|permission denied|invalid api key|forbidden|quota|usage limit|billing|not supported|unknown model|invalid model'; then
    printf 'no'
    return
  fi
  if printf '%s' "$*" | grep -qiE 'timeout|timed out|deadline exceeded|temporarily unavailable|service unavailable|connection (reset|refused|closed)|unexpected eof|\b50[234]\b'; then
    printf 'yes'
    return
  fi
  printf 'no'
}

# _fail_from_evidence <evidence_text> <message...> — record an attempt failure whose retry
# eligibility is decided by what agy actually said, not by which code path we are on.
_fail_from_evidence() {
  local ev="$1"; shift
  local verdict status
  verdict="$(_retry_verdict "$ev")"
  status="failure"
  [ "$verdict" = "yes" ] && status="timeout"
  _attempt_fail "$status" "$verdict" "$@"
}

# _attempt_evidence <fmt> — what agy told us on this attempt, for retry classification.
# Deliberately EXCLUDES agy's --log-file: that log echoes the `--print-timeout` flag we pass,
# so grepping it for "timeout" would make every failure look transient.
_attempt_evidence() {
  # Strip the flags WE passed before matching. agy echoes its arguments in usage/validation
  # errors, and we pass `--print-timeout 28800s` — so an unsanitized deterministic failure
  # would contain the word "timeout" and be promoted to transient, buying a pointless second
  # multi-hour attempt. Same reasoning as excluding --log-file from the evidence.
  cat "$attempt_dir/stderr.$1" "$attempt_dir/stdout.$1" 2>/dev/null | tail -c 4000 \
    | sed -e 's/--print-timeout[= ]*[0-9]*[a-z]*//g' -e 's/--log-file[= ]*[^ ]*//g'
}

# --- Model preflight ------------------------------------------------------------------
# `agy models` is the authority on which models EXIST. If it answers, the pin must be in its
# list or we fail here rather than letting agy pick something else. Existence is necessary but
# not sufficient — what agy actually ROUTES to is verified after each attempt by
# _verify_routing. Deterministic, so it runs once and is never retried.
models_out="$scratch/models.txt"
if _run_with_timeout 30 agy models > "$models_out" 2>"$scratch/models.err" && [ -s "$models_out" ]; then
  if ! tr -d '\r' < "$models_out" | awk '{print $1}' | grep -Fxq "$runtime_model"; then
    exit_code=1
    _fail 1 "required model unavailable: $runtime_model (not listed by 'agy models'). Available: $(tr -d '\r' < "$models_out" | awk 'NF{printf "%s ", $1}')"
  fi
else
  echo "[run_gemini.sh] warning: 'agy models' unavailable — cannot pre-check that $runtime_model exists; the post-run routing check still applies." >&2
fi

# --- Compose the panelist prompt: governance, then the task ---------------------------
# Governance first as a behavioral preamble, the user's task after it and authoritative.
# Injected exactly once: a prompt that already carries the marker is passed through untouched.
if grep -Fq "$GOVERNANCE_MARKER" "$prompt_file" 2>/dev/null; then
  prompt_text="$(cat "$prompt_file")"
  governance_injected="true"
  echo "[run_gemini.sh] governance $GOVERNANCE_PROFILE already present in the prompt — not injecting twice." >&2
else
  prompt_text="$(cat "$governance_file")

$(cat "$prompt_file")"
  governance_injected="true"
fi

# agy takes the prompt as an argv element (`--print <text>`); it has no stdin prompt mode. On
# Windows the whole command line is capped at 32767 chars by CreateProcess, so a very large
# panelist prompt would be truncated or rejected by the OS with an opaque error. Say so plainly
# instead of leaving a mystery failure. Measured AFTER governance injection, since that is what
# actually goes on the command line.
prompt_bytes="$(printf '%s' "$prompt_text" | wc -c | tr -d ' ')"
if [ "${prompt_bytes:-0}" -gt 30000 ]; then
  echo "[run_gemini.sh] warning: prompt is ${prompt_bytes} bytes (governance included); agy takes it on the command line and Windows caps that at ~32767. If this run fails oddly, the prompt is why." >&2
fi

# _agy_invoke <output-format> <seconds> — run agy in this attempt's isolated workspace.
# Always pins --model. stdout -> $attempt_dir/stdout.<fmt>, stderr -> $attempt_dir/stderr.<fmt>.
# Returns agy's exit code (124 if the external backstop killed it).
_agy_invoke() {
  local fmt="$1" secs="$2"
  # --log-file gives THIS attempt its own log, so the routing check below can never read a
  # concurrent z3Fusion run's — or the previous attempt's — log line.
  (
    cd "$workspace" || exit 1
    if have perl; then
      _run_with_timeout "$((secs + 30))" agy \
        --print "$prompt_text" \
        --model "$agy_model_arg" \
        --output-format "$fmt" \
        --print-timeout "${secs}s" \
        --log-file "$attempt_dir/agy.$fmt.log" \
        --dangerously-skip-permissions \
        < /dev/null > "$attempt_dir/stdout.$fmt" 2> "$attempt_dir/stderr.$fmt"
    else
      # No perl for the external backstop — agy's own --print-timeout still bounds the run.
      agy \
        --print "$prompt_text" \
        --model "$agy_model_arg" \
        --output-format "$fmt" \
        --print-timeout "${secs}s" \
        --log-file "$attempt_dir/agy.$fmt.log" \
        --dangerously-skip-permissions \
        < /dev/null > "$attempt_dir/stdout.$fmt" 2> "$attempt_dir/stderr.$fmt"
    fi
  )
}

# _verify_routing <fmt> — read back which model agy ACTUALLY routed to, from its own log for
# this attempt. This is the load-bearing check: agy can accept --model and still resolve to a
# different backend model, so configuration alone does not prove the pin held. (Model
# self-identification in the generated text is never used — models misreport their own name.)
# Sets $routed_label. Returns 0 verified, 1 mismatch, 2 unverifiable.
_verify_routing() {
  local log="$attempt_dir/agy.$1.log"
  routed_label=""
  [ -s "$log" ] || return 2
  local labels
  labels="$(grep -o 'Propagating selected model override to backend: label="[^"]*"' "$log" 2>/dev/null \
            | sed 's/.*label="//; s/"$//' | sort -u)"
  [ -n "$labels" ] || return 2
  routed_label="$(printf '%s' "$labels" | paste -sd'|' -)"
  [ -n "$expected_label" ] || return 2
  [ "$routed_label" = "$expected_label" ]
}

# _parse_json_result <json_file> <dest_dir> — 0 if it held a parseable agy result object.
# Writes dest_dir/{status,response,conversation_id,error} as plain UTF-8 files, which keeps
# multiline / quoted / non-ASCII answers out of shell word-splitting entirely.
_parse_json_result() {
  DEST="$2" "$FUSION_PY" - "$1" <<'PYEOF'
import json, os, sys

dest = os.environ["DEST"]
try:
    raw = open(sys.argv[1], encoding="utf-8", errors="replace").read().strip()
except Exception:
    sys.exit(1)
if not raw:
    sys.exit(1)

obj = None
# Tolerate banner/log lines around the result object; keep the LAST result-shaped one.
for line in raw.splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        cand = json.loads(line)
    except Exception:
        continue
    if isinstance(cand, dict) and ("status" in cand or "response" in cand):
        obj = cand
if obj is None:
    try:
        cand = json.loads(raw)
        if isinstance(cand, dict) and ("status" in cand or "response" in cand):
            obj = cand
    except Exception:
        pass
if obj is None:
    sys.exit(1)

os.makedirs(dest, exist_ok=True)
for key in ("status", "response", "conversation_id", "error"):
    val = obj.get(key)
    with open(os.path.join(dest, key), "w", encoding="utf-8") as f:
        f.write(val if isinstance(val, str) else "")
PYEOF
}

# _try_transcript — LEVEL 3. Recover THIS attempt's answer from agy's own transcript.
# Correlated by the unique per-attempt workspace (and conversation id when json gave us one)
# and gated on a modification time at/after this attempt started, so a stale transcript — from
# an earlier run OR from attempt 1 — is rejected.
_try_transcript() {
  # agy records workspace keys as native Windows paths; hand the reader the native spelling
  # when cygpath can produce one (paths with spaces stay quoted throughout).
  local ws="$workspace"
  if have cygpath; then
    ws="$(cygpath -w "$workspace" 2>/dev/null || printf '%s' "$workspace")"
  fi
  local args=( --workspace "$ws" --since "$start_epoch" )
  [ -n "$conversation_id" ] && args+=( --conversation-id "$conversation_id" )
  "$FUSION_PY" "$SCRIPT_DIR/agy_transcript.py" "${args[@]}" \
    > "$attempt_dir/transcript.out" 2> "$attempt_dir/transcript.err"
}

# _stale_rejected — the transcript reader refused an out-of-date transcript. Deterministic:
# retrying cannot make an old transcript current.
_stale_rejected() {
  grep -qi 'REJECTED stale transcript' "$attempt_dir/transcript.err" 2>/dev/null
}

# ======================================================================================
# ONE ATTEMPT
# ======================================================================================
# Returns 0 with the answer staged at $attempt_dir/answer, or 1 with attempt_status /
# attempt_retryable / attempt_msg set.
_run_attempt() {
  local n="$1"
  local secs="$FUSION_TIMEOUT"
  [ "$n" -gt 1 ] && secs=$(( FUSION_TIMEOUT * AGY_RETRY_FACTOR ))

  attempt_dir="$scratch/attempt$n"
  workspace="$attempt_dir/ws"
  mkdir -p "$workspace"
  start_epoch="$(date +%s)"

  # Reset every per-attempt result so nothing can leak forward from attempt 1.
  transport=""; conversation_id=""; routed_label=""; model_pin_verified="false"
  attempt_status="failure"; attempt_retryable="no"; attempt_msg=""
  used_fmt="json"

  # ---------------------------------------------------------------- LEVEL 1: json
  _agy_invoke json "$secs"
  local rc=$?
  attempt_rc=$rc
  exit_code=$rc

  if [ "$rc" -eq 124 ]; then
    _attempt_fail timeout yes "agy timed out after $((secs + 30))s (model $runtime_model)."
    return 1
  fi

  local parsed="$attempt_dir/parsed"
  if _parse_json_result "$attempt_dir/stdout.json" "$parsed"; then
    local status
    status="$(cat "$parsed/status" 2>/dev/null)"
    conversation_id="$(cat "$parsed/conversation_id" 2>/dev/null)"

    if [ "$status" = "ERROR" ] || [ -s "$parsed/error" ]; then
      local errtext
      errtext="$(head -c 500 "$parsed/error" 2>/dev/null)"
      _fail_from_evidence "$errtext" \
        "agy reported an error (exit $rc, model $runtime_model): $errtext"
      return 1
    fi
    if [ "$rc" -ne 0 ]; then
      _fail_from_evidence "$(_attempt_evidence json)" \
        "agy exited $rc (model $runtime_model). stderr: $(tail -c 300 "$attempt_dir/stderr.json" 2>/dev/null)"
      return 1
    fi

    if ! _is_blank "$parsed/response"; then
      cp "$parsed/response" "$attempt_dir/answer"
      transport="json"
    else
      # exit 0 with an empty response — do NOT call this success. LEVEL 3.
      echo "[run_gemini.sh] agy exited 0 with an empty json response — trying transcript fallback." >&2
      if _try_transcript && [ -s "$attempt_dir/transcript.out" ]; then
        cp "$attempt_dir/transcript.out" "$attempt_dir/answer"
        transport="windows-transcript-fallback"
      else
        # A rejected stale transcript is deterministic: no evidence, so no retry.
        local ev=""
        _stale_rejected || ev="$(_attempt_evidence json)"
        _fail_from_evidence "$ev" \
          "agy exit 0 but produced no answer on any transport (json empty, transcript recovery failed: $(tail -c 300 "$attempt_dir/transcript.err" 2>/dev/null))"
        return 1
      fi
    fi
  else
    # Structured output unparseable/unsupported => LEVEL 2, plain stdout text.
    if [ "$rc" -ne 0 ]; then
      _fail_from_evidence "$(_attempt_evidence json)" \
        "agy exited $rc and emitted no parseable result (model $runtime_model). stdout: $(head -c 300 "$attempt_dir/stdout.json" 2>/dev/null) stderr: $(tail -c 300 "$attempt_dir/stderr.json" 2>/dev/null)"
      return 1
    fi
    echo "[run_gemini.sh] json output unparseable — falling back to --output-format text." >&2

    _agy_invoke text "$secs"
    rc=$?
    attempt_rc=$rc
    exit_code=$rc
    used_fmt="text"
    if [ "$rc" -eq 124 ]; then
      _attempt_fail timeout yes "agy timed out after $((secs + 30))s on the text transport (model $runtime_model)."
      return 1
    fi
    if [ "$rc" -ne 0 ]; then
      _fail_from_evidence "$(_attempt_evidence text)" \
        "agy exited $rc on the text transport (model $runtime_model). stderr: $(tail -c 300 "$attempt_dir/stderr.text" 2>/dev/null)"
      return 1
    fi

    # Strip ANSI colour runs and residual control bytes (keep tab + newline).
    sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\^D//g' < "$attempt_dir/stdout.text" \
      | LC_ALL=C tr -d '\000-\010\013-\037\177' > "$attempt_dir/stdout.text.clean"

    if ! _is_blank "$attempt_dir/stdout.text.clean"; then
      cp "$attempt_dir/stdout.text.clean" "$attempt_dir/answer"
      transport="stdout-text"
    else
      echo "[run_gemini.sh] agy exited 0 with empty stdout — trying transcript fallback." >&2
      if _try_transcript && [ -s "$attempt_dir/transcript.out" ]; then
        cp "$attempt_dir/transcript.out" "$attempt_dir/answer"
        transport="windows-transcript-fallback"
      else
        local ev=""
        _stale_rejected || ev="$(_attempt_evidence text)"
        _fail_from_evidence "$ev" \
          "agy exit 0 but produced no answer on any transport (stdout empty, transcript recovery failed: $(tail -c 300 "$attempt_dir/transcript.err" 2>/dev/null))"
        return 1
      fi
    fi
  fi

  # --- Model routing verification (the actual pin guarantee) --------------------------
  # Configuration says what we ASKED for; this says what agy DID. A mismatch means agy
  # substituted another model, which is exactly what must never pass silently — and it is
  # DETERMINISTIC, so it is never retried.
  _verify_routing "$used_fmt"
  case $? in
    0)
      model_pin_verified="true"
      ;;
    1)
      _attempt_fail failure no "required model unavailable: $runtime_model — agy routed to \"$routed_label\" instead of \"$expected_label\". Refusing to pass another model's answer off as $runtime_model. (Common cause: agy is not logged in, so it cannot resolve the model table and silently falls back. Log: $attempt_dir/agy.$used_fmt.log)"
      return 1
      ;;
    *)
      echo "[run_gemini.sh] warning: could not verify which model agy routed to (no routing line in its log); recording model_pin_verified=false." >&2
      ;;
  esac

  # --- Anti-empty guard ---------------------------------------------------------------
  if _is_blank "$attempt_dir/answer"; then
    transport="none"
    _attempt_fail failure no "agy produced no answer (all transports empty)."
    return 1
  fi

  attempt_status="success"
  return 0
}

# ======================================================================================
# DRIVER — at most AGY_MAX_ATTEMPTS, retrying only transient failures
# ======================================================================================
n=1
while : ; do
  attempts=$n
  if _run_attempt "$n"; then
    if [ "$n" -eq 1 ]; then
      attempt_1_status="success"
      attempt_1_rc="$attempt_rc"
    else
      attempt_2_status="success"
    fi
    final_status="success"
    break
  fi

  if [ "$n" -eq 1 ]; then
    attempt_1_status="$attempt_status"
    attempt_1_rc="$attempt_rc"
  else
    attempt_2_status="failure"
  fi

  if [ "$n" -lt "$AGY_MAX_ATTEMPTS" ] && [ "$attempt_retryable" = "yes" ]; then
    retry_reason="$attempt_status: $attempt_msg"
    echo "[run_gemini.sh] attempt $n failed transiently ($attempt_status) — retrying once with a longer timeout ($(( FUSION_TIMEOUT * AGY_RETRY_FACTOR ))s). Reason: $attempt_msg" >&2
    n=$((n + 1))
    continue
  fi
  break
done

if [ "$final_status" != "success" ]; then
  transport="${transport:-none}"
  if [ "$attempt_status" = "timeout" ]; then
    _fail 124 "$attempt_msg"
  fi
  _fail 1 "$attempt_msg"
fi

cp "$attempt_dir/answer" "$output_file"

# Guarantee a trailing newline so the answer never gets glued onto the next markdown block
# when save_run.sh concatenates panelist answers into the provenance record.
if [ -s "$output_file" ] && [ -n "$(tail -c1 "$output_file")" ]; then
  printf '\n' >> "$output_file"
fi

if _is_blank "$output_file"; then
  transport="none"
  final_status="failure"
  _fail 1 "agy produced no answer (all transports empty). Dropping Gemini."
fi

_write_provenance "ok"
echo "[run_gemini.sh] ok -> $output_file"
echo "[run_gemini.sh] provenance: backend=agy model=$runtime_model agy_model_arg=\"$agy_model_arg\" routed_model=\"${routed_label:-unverified}\" model_pin_verified=$model_pin_verified exit_code=$exit_code output_transport=$transport attempts=$attempts conversation_id=${conversation_id:-n/a} governance=$GOVERNANCE_PROFILE"

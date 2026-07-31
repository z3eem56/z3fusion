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
# Stale-transcript safety: every invocation runs in its OWN fresh workspace dir, so agy opens
# a NEW conversation whose id is looked up from agy's own cache keyed by that workspace (and,
# on the json path, read straight out of agy's stdout). A transcript is additionally rejected
# unless it was modified at/after this invocation started. A previous run's transcript can
# therefore never be mistaken for this one.
#
# A non-zero agy exit is NEVER masked by transcript recovery.
#
# Config (env):
#   AGY_MODEL       logical or runtime model name (default/blank -> gemini-3.1-pro-high).
#   FUSION_TIMEOUT  per-panelist budget in seconds (default 300, from _fusion_lib.sh).
#
# Exit codes: 0 ok | 1 failure (incl. model unavailable / empty answer) | 124 timeout |
#             127 agy CLI not installed.
#
# Side effect: writes "<output_file>.provenance.json" describing the invocation
# (backend, requested/runtime model, model_pin_verified, exit_code, output_transport,
# conversation_id) and echoes a one-line summary on stdout for the orchestrator.

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

AGY_PRINT_TIMEOUT="${FUSION_TIMEOUT}s"
EXT_TIMEOUT=$((FUSION_TIMEOUT + 30))

if ! have agy; then
  echo "[run_gemini.sh] agy CLI not installed — skip this panelist." >&2
  exit 127
fi

if [ ! -s "$prompt_file" ]; then
  echo "[run_gemini.sh] prompt file is missing or empty: $prompt_file" >&2
  exit 2
fi

mkdir -p "$(dirname "$output_file")" 2>/dev/null
: > "$output_file"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/z3fusion-gemini.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
# Fresh, unique workspace: guarantees agy opens a NEW conversation we can correlate to.
workspace="$scratch/ws"
mkdir -p "$workspace"
start_epoch="$(date +%s)"

provenance_file="${output_file}.provenance.json"
transport=""
conversation_id=""
exit_code=""
model_pin_verified="false"

# _write_provenance <status>
_write_provenance() {
  STATUS="$1" BACKEND="agy" REQ="$requested_model" RUN="$runtime_model" \
  ARG="$agy_model_arg" ROUTED="$routed_label" \
  PINOK="$model_pin_verified" RC="${exit_code:-}" TRANSPORT="$transport" \
  CONV="$conversation_id" OUT="$provenance_file" \
  "$FUSION_PY" - <<'PYEOF' 2>/dev/null
import json, os
doc = {
    "backend": os.environ["BACKEND"],
    "requested_model": os.environ["REQ"],
    "model": os.environ["RUN"],
    "runtime_backend": "agy",
    "agy_model_arg": os.environ["ARG"],
    "routed_model_label": os.environ["ROUTED"] or None,
    "model_pin_verified": os.environ["PINOK"] == "true",
    "exit_code": (int(os.environ["RC"]) if os.environ.get("RC", "").strip().lstrip("-").isdigit() else None),
    "output_transport": os.environ["TRANSPORT"] or None,
    "conversation_id": os.environ["CONV"] or None,
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

# _is_blank <file> — true when the file is missing, empty, or whitespace-only.
_is_blank() {
  [ -f "$1" ] && [ -s "$1" ] || return 0
  local n
  n="$(LC_ALL=C tr -d '[:space:]' < "$1" | wc -c | tr -d ' ')"
  [ "${n:-0}" -eq 0 ]
}

# --- Model preflight ------------------------------------------------------------------
# `agy models` is the authority on which models EXIST. If it answers, the pin must be in its
# list or we fail here rather than letting agy pick something else. Existence is necessary but
# not sufficient — what agy actually ROUTES to is verified after the run by _verify_routing.
models_out="$scratch/models.txt"
if _run_with_timeout 30 agy models > "$models_out" 2>"$scratch/models.err" && [ -s "$models_out" ]; then
  if ! tr -d '\r' < "$models_out" | awk '{print $1}' | grep -Fxq "$runtime_model"; then
    exit_code=1
    _fail 1 "required model unavailable: $runtime_model (not listed by 'agy models'). Available: $(tr -d '\r' < "$models_out" | awk 'NF{printf "%s ", $1}')"
  fi
else
  echo "[run_gemini.sh] warning: 'agy models' unavailable — cannot pre-check that $runtime_model exists; the post-run routing check still applies." >&2
fi

prompt_text="$(cat "$prompt_file")"

# agy takes the prompt as an argv element (`--print <text>`); it has no stdin prompt mode. On
# Windows the whole command line is capped at 32767 chars by CreateProcess, so a very large
# panelist prompt would be truncated or rejected by the OS with an opaque error. Say so plainly
# instead of leaving a mystery failure.
prompt_bytes="$(printf '%s' "$prompt_text" | wc -c | tr -d ' ')"
if [ "${prompt_bytes:-0}" -gt 30000 ]; then
  echo "[run_gemini.sh] warning: prompt is ${prompt_bytes} bytes; agy takes it on the command line and Windows caps that at ~32767. If this run fails oddly, the prompt is why." >&2
fi

# _agy_invoke <output-format> — run agy in the isolated workspace. Always pins --model.
# stdout -> $scratch/stdout.<fmt>, stderr -> $scratch/stderr.<fmt>. Returns agy's exit code
# (124 if the external backstop killed it).
_agy_invoke() {
  local fmt="$1"
  # --log-file gives THIS invocation its own log, so the routing check below can never read
  # a concurrent z3Fusion run's log line.
  (
    cd "$workspace" || exit 1
    if have perl; then
      _run_with_timeout "$EXT_TIMEOUT" agy \
        --print "$prompt_text" \
        --model "$agy_model_arg" \
        --output-format "$fmt" \
        --print-timeout "$AGY_PRINT_TIMEOUT" \
        --log-file "$scratch/agy.$fmt.log" \
        --dangerously-skip-permissions \
        < /dev/null > "$scratch/stdout.$fmt" 2> "$scratch/stderr.$fmt"
    else
      # No perl for the external backstop — agy's own --print-timeout still bounds the run.
      agy \
        --print "$prompt_text" \
        --model "$agy_model_arg" \
        --output-format "$fmt" \
        --print-timeout "$AGY_PRINT_TIMEOUT" \
        --log-file "$scratch/agy.$fmt.log" \
        --dangerously-skip-permissions \
        < /dev/null > "$scratch/stdout.$fmt" 2> "$scratch/stderr.$fmt"
    fi
  )
}

# _verify_routing <fmt> — read back which model agy ACTUALLY routed to, from its own log for
# this invocation. This is the load-bearing check: agy can accept --model and still resolve
# to a different backend model, so configuration alone does not prove the pin held. (Model
# self-identification in the generated text is never used — models misreport their own name.)
# Sets $routed_label. Returns 0 verified, 1 mismatch, 2 unverifiable.
_verify_routing() {
  local log="$scratch/agy.$1.log"
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

# _try_transcript — LEVEL 3. Recover THIS invocation's answer from agy's own transcript.
# Correlated by the unique workspace (and conversation id when json gave us one) and gated on
# a modification time at/after this invocation started, so a stale transcript is rejected.
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
    > "$scratch/transcript.out" 2> "$scratch/transcript.err"
}

# ======================================================================================
# LEVEL 1 — native structured output
# ======================================================================================
_agy_invoke json
rc=$?
exit_code=$rc
used_fmt="json"

if [ "$rc" -eq 124 ]; then
  transport="none"
  _fail 124 "agy timed out after ${EXT_TIMEOUT}s (model $runtime_model)."
fi

parsed="$scratch/parsed"
if _parse_json_result "$scratch/stdout.json" "$parsed"; then
  status="$(cat "$parsed/status" 2>/dev/null)"
  conversation_id="$(cat "$parsed/conversation_id" 2>/dev/null)"

  if [ "$status" = "ERROR" ] || [ -s "$parsed/error" ]; then
    transport="none"
    _fail 1 "agy reported an error (exit $rc, model $runtime_model): $(head -c 500 "$parsed/error" 2>/dev/null)"
  fi
  if [ "$rc" -ne 0 ]; then
    transport="none"
    _fail 1 "agy exited $rc (model $runtime_model). stderr: $(tail -c 300 "$scratch/stderr.json" 2>/dev/null)"
  fi

  if ! _is_blank "$parsed/response"; then
    cp "$parsed/response" "$output_file"
    transport="json"
  else
    # exit 0 with an empty response — do NOT call this success. LEVEL 3.
    echo "[run_gemini.sh] agy exited 0 with an empty json response — trying transcript fallback." >&2
    if _try_transcript && [ -s "$scratch/transcript.out" ]; then
      cp "$scratch/transcript.out" "$output_file"
      transport="windows-transcript-fallback"
    else
      transport="none"
      _fail 1 "agy exit 0 but produced no answer on any transport (json empty, transcript recovery failed: $(tail -c 300 "$scratch/transcript.err" 2>/dev/null))"
    fi
  fi
else
  # Structured output unparseable/unsupported => LEVEL 2, plain stdout text.
  if [ "$rc" -ne 0 ]; then
    transport="none"
    _fail 1 "agy exited $rc and emitted no parseable result (model $runtime_model). stdout: $(head -c 300 "$scratch/stdout.json" 2>/dev/null) stderr: $(tail -c 300 "$scratch/stderr.json" 2>/dev/null)"
  fi
  echo "[run_gemini.sh] json output unparseable — falling back to --output-format text." >&2

  _agy_invoke text
  rc=$?
  exit_code=$rc
  used_fmt="text"
  if [ "$rc" -eq 124 ]; then
    transport="none"
    _fail 124 "agy timed out after ${EXT_TIMEOUT}s on the text transport (model $runtime_model)."
  fi
  if [ "$rc" -ne 0 ]; then
    transport="none"
    _fail 1 "agy exited $rc on the text transport (model $runtime_model). stderr: $(tail -c 300 "$scratch/stderr.text" 2>/dev/null)"
  fi

  # Strip ANSI colour runs and residual control bytes (keep tab + newline).
  sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\^D//g' < "$scratch/stdout.text" \
    | LC_ALL=C tr -d '\000-\010\013-\037\177' > "$scratch/stdout.text.clean"

  if ! _is_blank "$scratch/stdout.text.clean"; then
    cp "$scratch/stdout.text.clean" "$output_file"
    transport="stdout-text"
  else
    echo "[run_gemini.sh] agy exited 0 with empty stdout — trying transcript fallback." >&2
    if _try_transcript && [ -s "$scratch/transcript.out" ]; then
      cp "$scratch/transcript.out" "$output_file"
      transport="windows-transcript-fallback"
    else
      transport="none"
      _fail 1 "agy exit 0 but produced no answer on any transport (stdout empty, transcript recovery failed: $(tail -c 300 "$scratch/transcript.err" 2>/dev/null))"
    fi
  fi
fi

# Guarantee a trailing newline so the answer never gets glued onto the next markdown block
# when save_run.sh concatenates panelist answers into the provenance record.
if [ -s "$output_file" ] && [ -n "$(tail -c1 "$output_file")" ]; then
  printf '\n' >> "$output_file"
fi

# --- Model routing verification (the actual pin guarantee) ----------------------------
# Configuration says what we ASKED for; this says what agy DID. A mismatch means agy
# substituted another model, which is exactly what must never pass silently.
_verify_routing "$used_fmt"
case $? in
  0)
    model_pin_verified="true"
    ;;
  1)
    _fail 1 "required model unavailable: $runtime_model — agy routed to \"$routed_label\" instead of \"$expected_label\". Refusing to pass another model's answer off as $runtime_model. (Common cause: agy is not logged in, so it cannot resolve the model table and silently falls back. Log: $scratch/agy.$used_fmt.log)"
    ;;
  *)
    echo "[run_gemini.sh] warning: could not verify which model agy routed to (no routing line in its log); recording model_pin_verified=false." >&2
    ;;
esac

# --- Anti-empty guard -----------------------------------------------------------------
if _is_blank "$output_file"; then
  transport="none"
  _fail 1 "agy produced no answer (all transports empty). Dropping Gemini."
fi

_write_provenance "ok"
echo "[run_gemini.sh] ok -> $output_file"
echo "[run_gemini.sh] provenance: backend=agy model=$runtime_model agy_model_arg=\"$agy_model_arg\" routed_model=\"${routed_label:-unverified}\" model_pin_verified=$model_pin_verified exit_code=$exit_code output_transport=$transport conversation_id=${conversation_id:-n/a}"

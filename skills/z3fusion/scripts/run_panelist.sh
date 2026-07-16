#!/usr/bin/env bash
# run_panelist.sh — generic dispatcher for every non-in-session z3Fusion panelist.
#
# SKILL.md's Step 2 calls this script once per panel slot of the form "model@runner"
# (a bare "model" with no "@" means an in-session Claude Agent-tool subagent — that case is
# handled entirely by the orchestrator and never reaches this script).
#
# Usage:
#   run_panelist.sh <runner> <model> <prompt_file> <output_file> [effort]
#
# - <runner>      : "codex" | "agy" | "ollama" | any OpenAI-compat provider name known to
#                    providers.sh (built-in table or user-registered in
#                    ~/.claude/z3fusion-runners.json) | a user-registered "custom" command
#                    template name from that same file.
# - <model>       : model name/slug for that runner. May be the empty string for runners
#                    that have their own configured default (e.g. codex, agy).
# - <prompt_file> : path to a file containing the FULL panelist prompt.
# - <output_file> : where the panelist's final answer is written.
# - [effort]      : optional reasoning effort, only meaningful for the "codex" runner.
#
# Exit codes (matches every other z3Fusion runner's convention):
#   0   success (output_file written, non-empty)
#   1   other failure or empty output
#   2   bad usage or missing prompt file
#   124 timed out
#   127 runner/CLI/API not available, or unknown/unrecognized runner name
#
# This script mostly just validates input and `exec`s into the runner-specific script, so
# the child script's own exit code becomes this script's exit code (exec replaces the process,
# it does not wrap it) — that is how 0/1/124/127 flow through untouched from run_codex.sh,
# run_gemini.sh, run_ollama.sh and run_openai_compat.sh. Only the "bad usage" (2) and
# "unknown runner" (127) cases are raised directly, here.
#
# NOTE (unverified in this environment): none of the external CLIs/APIs this dispatches to
# (codex, agy, ollama, OpenRouter, etc.) are installed/reachable here, so the dispatch paths
# below cannot be exercised end to end. The argument orders match the interface contract
# exactly; behavior of the callees themselves is documented in their own files.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Python fallback (same as _fusion_lib.sh, duplicated because this script doesn't source it):
# Windows installs often expose only `python`, not `python3`.
FUSION_PY="${FUSION_PY:-$(command -v python3 || command -v python || echo python3)}"

usage() {
  echo "usage: run_panelist.sh <runner> <model> <prompt_file> <output_file> [effort]" >&2
}

if [ "$#" -lt 4 ]; then
  usage
  exit 2
fi

runner="$1"
model="$2"
prompt_file="$3"
output_file="$4"
effort="${5:-}"

if [ -z "$runner" ]; then
  echo "[run_panelist.sh] missing <runner>" >&2
  usage
  exit 2
fi

if [ ! -s "$prompt_file" ]; then
  echo "[run_panelist.sh] prompt file is missing or empty: $prompt_file" >&2
  exit 2
fi

# NOTE: this dispatcher holds no temp state of its own — it is pure control flow that ends
# every real path in `exec` (which replaces the process image, so an EXIT trap here would
# never fire and a scratch dir would leak on every single invocation). If a future change
# needs scratch space, create it with `mktemp -d "${TMPDIR:-/tmp}/z3fusion-panelist.XXXXXX"`
# (never a fixed path — multiple concurrent z3Fusion sessions run on this machine) and clean
# it up in the same branch that used it, not via a trap that `exec` would skip.

# _custom_template <runner_name>
# Looks up ~/.claude/z3fusion-runners.json's top-level "custom" object for a
# {"template": "..."} entry for <runner_name>. Prints the template string to stdout and
# returns 0 if found; returns 1 (prints nothing) if the file, the "custom" key, the runner
# entry, or its "template" string is missing/malformed. See providers.sh's header comment
# for the full documented shape of z3fusion-runners.json (that file is the single spec).
_custom_template() {
  local runner_name="$1"
  local cfg="$HOME/.claude/z3fusion-runners.json"
  [ -f "$cfg" ] || cfg="$HOME/.claude/fusion-runners.json"   # pre-rebrand fallback
  [ -f "$cfg" ] || return 1
  "$FUSION_PY" -c '
import json, sys

cfg_path, runner_name = sys.argv[1], sys.argv[2]
try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

custom = data.get("custom") if isinstance(data, dict) else None
if not isinstance(custom, dict):
    sys.exit(1)

entry = custom.get(runner_name)
if not isinstance(entry, dict):
    sys.exit(1)

template = entry.get("template")
if not isinstance(template, str) or not template:
    sys.exit(1)

sys.stdout.write(template)
' "$cfg" "$runner_name" 2>/dev/null
}

_known_runners_message() {
  cat >&2 <<'EOF'
[run_panelist.sh] unknown runner. Known runner names:
  built-in special-cased : codex, agy, ollama
  built-in HTTP providers: openrouter, lmstudio, ollama-api, openai, groq, together,
                           fireworks, deepseek, mistral, xai, google
  plus any provider/custom runner you register in ~/.claude/z3fusion-runners.json
EOF
}

case "$runner" in
  codex)
    eff="$effort"
    if [ -z "$eff" ]; then
      eff="xhigh"   # matches run_codex.sh's own default
    fi
    exec bash "$SCRIPT_DIR/run_codex.sh" "$prompt_file" "$output_file" "$eff" "$model"
    ;;

  agy)
    if [ -n "$model" ]; then
      export AGY_MODEL="$model"
    fi
    exec bash "$SCRIPT_DIR/run_gemini.sh" "$prompt_file" "$output_file"
    ;;

  ollama)
    exec bash "$SCRIPT_DIR/run_ollama.sh" "$model" "$prompt_file" "$output_file"
    ;;

  *)
    # Try a built-in or user-registered HTTP provider first.
    if [ -f "$SCRIPT_DIR/providers.sh" ]; then
      # shellcheck disable=SC1091
      . "$SCRIPT_DIR/providers.sh"
      if declare -f provider_lookup >/dev/null 2>&1 && provider_lookup "$runner"; then
        mkdir -p "$(dirname "$output_file")" 2>/dev/null
        exec bash "$SCRIPT_DIR/run_openai_compat.sh" \
          "$PROVIDER_BASE_URL" "$PROVIDER_API_KEY_ENV" "$model" \
          "$prompt_file" "$output_file" "${PROVIDER_EXTRA_JSON:-}"
      fi
    fi

    # Not a known HTTP provider — try a user-registered "custom" command template.
    template="$(_custom_template "$runner")"
    if [ -n "$template" ]; then
      # Plain string replacement of the literal placeholders — no eval of user input beyond
      # running the templated command line itself (the template IS a shell command string
      # by design, per its documented shape in ~/.claude/z3fusion-runners.json).
      cmd="${template//\{model\}/$model}"
      cmd="${cmd//\{prompt_file\}/$prompt_file}"
      cmd="${cmd//\{output_file\}/$output_file}"
      mkdir -p "$(dirname "$output_file")" 2>/dev/null
      exec bash -c "$cmd"
    fi

    _known_runners_message
    exit 127
    ;;
esac

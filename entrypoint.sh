#!/usr/bin/env bash
# =============================================================================
# AI Evaluator — GitHub Action Entrypoint
# Repo: ai-evaluator-action
#
# Runs an evaluation against the user's agent endpoint using the AI Evaluator
# Engine API. Supports sync and async modes, file upload and inline rows,
# threshold gating, and PR comment posting.
# =============================================================================

set -euo pipefail

# ── Resolve inputs from environment (set by action.yml) ─────────────

API_KEY="${INPUT_API_KEY:-}"
AGENT_URL="${INPUT_AGENT_URL:-}"
AGENT_FORMAT="${INPUT_AGENT_FORMAT:-openai}"
AGENT_CUSTOM_TEMPLATE="${INPUT_AGENT_CUSTOM_TEMPLATE:-}"
METRICS="${INPUT_METRICS:-g_eval,faithfulness}"
CUSTOM_EVALUATORS="${INPUT_CUSTOM_EVALUATORS:-[]}"
DATASET="${INPUT_DATASET:-}"
ROWS="${INPUT_ROWS:-}"
MIN_SCORE="${INPUT_MIN_SCORE:-0.0}"
ENGINE_URL="${INPUT_ENGINE_URL:-https://api.aievaluator.dev}"
MODE="${INPUT_MODE:-sync}"
TIMEOUT="${INPUT_TIMEOUT:-300}"
COMMENT="${INPUT_COMMENT:-true}"
FAIL_ON_LIMIT="${INPUT_FAIL_ON_LIMIT:-false}"

# Strip trailing slash from engine URL
ENGINE_URL="${ENGINE_URL%/}"

# ── Colours for output ──────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

info()    { echo -e "${BLUE}[ai-eval]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ai-eval]${NC}  ✅ $*"; }
warn()    { echo -e "${YELLOW}[ai-eval]${NC}  ⚠️  $*"; }
error()   { echo -e "${RED}[ai-eval]${NC}  ❌ $*"; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}\n"; }

# ── Set outputs via GITHUB_OUTPUT ───────────────────────────────────

set_output() {
  local name="$1"
  local value="$2"
  echo "${name}=${value}" >> "$GITHUB_OUTPUT"
}

# ── Validate required inputs ────────────────────────────────────────

section "AI Evaluator — Configuration"

if [ -z "$API_KEY" ]; then
  error "Missing required input: api-key"
  echo "  Add it to your workflow:"
  echo "    with:"
  echo "      api-key: \${{ secrets.AI_EVALUATOR_API_KEY }}"
  exit 1
fi

if [ -z "$AGENT_URL" ]; then
  error "Missing required input: agent-url"
  exit 1
fi

info "Agent URL:     ${AGENT_URL}"
info "Metrics:       ${METRICS}"
info "Min score:     ${MIN_SCORE}"
info "Engine:        ${ENGINE_URL}"
info "Mode:          ${MODE}"

# Exactly one data source required
HAS_DATASET=false
HAS_ROWS=false
[ -n "$DATASET" ] && HAS_DATASET=true
[ -n "$ROWS" ] && HAS_ROWS=true

if [ "$HAS_DATASET" = true ] && [ "$HAS_ROWS" = true ]; then
  error "Both 'dataset' and 'rows' are set. Use exactly one."
  exit 1
fi
if [ "$HAS_DATASET" = false ] && [ "$HAS_ROWS" = false ]; then
  error "No data source provided. Use 'dataset' or 'rows'."
  exit 1
fi

# ── Check plan limits ───────────────────────────────────────────────

section "Checking plan limits"

USAGE_JSON=$(curl -sS -f "${ENGINE_URL}/api/v1/tenants/me/usage" \
  -H "X-API-Key: ${API_KEY}" \
  -H "Content-Type: application/json" 2>&1) || {
  warn "Could not check plan limits (engine returned error)"
  USAGE_JSON=""
}

if [ -n "$USAGE_JSON" ]; then
  EVALS_USED=$(echo "$USAGE_JSON" | jq -r '.evaluations_this_cycle // 0')
  EVALS_LIMIT=$(echo "$USAGE_JSON" | jq -r '.evaluations_limit // -1')
  TIER=$(echo "$USAGE_JSON" | jq -r '.tier // "unknown"')

  info "Plan: ${TIER}  |  Evals this cycle: ${EVALS_USED} / ${EVALS_LIMIT}"

  if [ "$EVALS_LIMIT" != "-1" ] && [ "$EVALS_USED" -ge "$EVALS_LIMIT" ]; then
    if [ "$FAIL_ON_LIMIT" = "true" ]; then
      error "Evaluation limit reached (${EVALS_USED}/${EVALS_LIMIT}). Upgrade your plan."
      exit 1
    else
      warn "Evaluation limit reached (${EVALS_USED}/${EVALS_LIMIT}). Proceeding anyway (fail-on-limit is false)."
    fi
  fi
fi

# ── Run evaluation ──────────────────────────────────────────────────

section "Running evaluation"

TMP_RESULT=$(mktemp)
TMP_COMMENT=$(mktemp)

if [ "$HAS_DATASET" = true ]; then
  # ── File upload mode ──
  if [ ! -f "$DATASET" ]; then
    error "Dataset file not found: ${DATASET}"
    exit 1
  fi

  info "Uploading dataset: ${DATASET}"

  # Build multipart form upload with curl
  HTTP_CODE=$(curl -sS -o "$TMP_RESULT" -w "%{http_code}" \
    -X POST "${ENGINE_URL}/api/v1/evaluations/sync/upload" \
    -H "X-API-Key: ${API_KEY}" \
    -F "file=@${DATASET}" \
    -F "agent_endpoint=${AGENT_URL}" \
    -F "agent_format=${AGENT_FORMAT}" \
    -F "agent_auth_type=${AGENT_AUTH_TYPE:-none}" \
    -F "agent_auth_header_name=${AGENT_AUTH_HEADER:-}" \
    -F "agent_auth_token=${AGENT_AUTH_TOKEN:-}" \
    -F "metrics=${METRICS}" 2>&1) || true

else
  # ── Inline rows mode ──
  info "Using inline rows"

  # Build agent config JSON (with auth if provided)
  AGENT_JSON=$(jq -n \
    --arg url "$AGENT_URL" \
    --arg fmt "$AGENT_FORMAT" \
    --arg auth_type "${AGENT_AUTH_TYPE:-}" \
    --arg auth_header "${AGENT_AUTH_HEADER:-}" \
    --arg auth_token "${AGENT_AUTH_TOKEN:-}" \
    '{
      url: $url,
      format: $fmt
    } + if $auth_type != "" and $auth_type != "none" then {
      auth_type: $auth_type,
      auth_header_name: (if $auth_header != "" then $auth_header else null end),
      auth_token: (if $auth_token != "" then $auth_token else null end)
    } | with_entries(select(.value != null)) else {} end')

  # Build request body
  REQUEST_BODY=$(jq -n \
    --argjson rows "$ROWS" \
    --argjson agent "$AGENT_JSON" \
    --argjson custom_evaluators "$CUSTOM_EVALUATORS" \
    --arg name "${INPUT_NAME:-}" \
    --arg judge_model "${INPUT_JUDGE_MODEL:-}" \
    --arg metrics "$METRICS" '{
    rows: $rows,
    agent: $agent,
    metrics: ($metrics | split(",")),
    custom_evaluators: $custom_evaluators
  } + (if $name != "" then {name: $name} else {} end)
  + (if $judge_model != "" then {judge_model: $judge_model} else {} end)
  ')

  HTTP_CODE=$(curl -sS -o "$TMP_RESULT" -w "%{http_code}" \
    -X POST "${ENGINE_URL}/api/v1/evaluations/sync" \
    -H "X-API-Key: ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$REQUEST_BODY" 2>&1) || true
fi

# ── Parse results ───────────────────────────────────────────────────

if [ "$HTTP_CODE" != "200" ]; then
  error "Engine returned HTTP ${HTTP_CODE}"
  echo ""
  cat "$TMP_RESULT" 2>/dev/null || true
  echo ""
  rm -f "$TMP_RESULT" "$TMP_COMMENT"
  exit 1
fi

EVAL_ID=$(jq -r '.definition_id // ""' "$TMP_RESULT")
RUN_ID=$(jq -r '.run_id // ""' "$TMP_RESULT")
OVERALL_SCORE=$(jq -r '.overall_score // 0' "$TMP_RESULT")
PASSED=$(jq -r '.passed // false' "$TMP_RESULT")
TOTAL_ROWS=$(jq -r '.total_rows // 0' "$TMP_RESULT")
INPUT_TOKENS=$(jq -r '.input_tokens // 0' "$TMP_RESULT")
OUTPUT_TOKENS=$(jq -r '.output_tokens // 0' "$TMP_RESULT")
FAILED_QUERIES=$(jq -r '[.results[] | select(.passed == false)] | length' "$TMP_RESULT")

# Format score as percentage
SCORE_PCT=$(awk "BEGIN { printf \"%.1f\", ${OVERALL_SCORE} * 100 }")

# ── Set outputs ─────────────────────────────────────────────────────

set_output "evaluation-id" "$EVAL_ID"
set_output "run-id" "$RUN_ID"
set_output "overall-score" "$OVERALL_SCORE"
set_output "passed" "$PASSED"
set_output "results-json" "$(jq -c '.' "$TMP_RESULT")"
set_output "total-rows" "$TOTAL_ROWS"
set_output "input-tokens" "$INPUT_TOKENS"
set_output "output-tokens" "$OUTPUT_TOKENS"
set_output "failed-queries" "$FAILED_QUERIES"

# ── Display results ─────────────────────────────────────────────────

section "Results"

echo "  Evaluation ID:  ${CYAN}${EVAL_ID}${NC}"
echo "  Overall Score:  ${BOLD}${SCORE_PCT}%${NC}"
echo "  Total rows:     ${TOTAL_ROWS}"
echo "  Failed queries: ${FAILED_QUERIES}"
echo "  Tokens in:      ${INPUT_TOKENS}"
echo "  Tokens out:     ${OUTPUT_TOKENS}"
echo ""

# Threshold check
MEETS_THRESHOLD=$(awk "BEGIN { print (${OVERALL_SCORE} >= ${MIN_SCORE}) ? 1 : 0 }")
if [ "$MEETS_THRESHOLD" = "1" ]; then
  ok "Score ${SCORE_PCT}% meets threshold ${MIN_SCORE}"
else
  error "Score ${SCORE_PCT}% below threshold ${MIN_SCORE}"
fi

# ── Print per-query results ─────────────────────────────────────────

echo ""
echo "┌────┬─────────────────────────────────────────────┬──────────┬──────┐"
echo "│  # │ Query                                       │ Score    │ Pass │"
echo "├────┼─────────────────────────────────────────────┼──────────┼──────┤"

jq -r '.results | to_entries[] | 
  "│ \(.key+1 | tostring | .[0:3] | rpad(3))│ \(.value.query[0:46] | rpad(46))│ \(
    ((.value.scores | to_entries[0].value // 0) * 100 | floor | tostring + "%") | rpad(9)
  )│ \(if .value.passed then "✅" else "❌" end)   │"' "$TMP_RESULT" 2>/dev/null || true

echo "└────┴─────────────────────────────────────────────┴──────────┴──────┘"
echo ""

# ── Build PR comment ────────────────────────────────────────────────

if [ "$COMMENT" = "true" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  section "Posting PR comment"

  # Detect if this is a PR
  if [ -n "${GITHUB_EVENT_NAME:-}" ] && [ "${GITHUB_EVENT_NAME}" = "pull_request" ]; then
    # Build Markdown table for the comment
    THRESHOLD_PCT=$(awk "BEGIN { printf \"%.0f\", ${MIN_SCORE} * 100 }")
    PASS_ICON="✅"
    if [ "$MEETS_THRESHOLD" != "1" ]; then
      PASS_ICON="❌"
    fi

    cat > "$TMP_COMMENT" <<MDEOF
## 🤖 AI Evaluation Results

**Agent:** \`${AGENT_URL}\`
**Score:** **${SCORE_PCT}%** ${PASS_ICON} · Threshold: ${THRESHOLD_PCT}%
**Tokens:** ↓${INPUT_TOKENS} · ↑${OUTPUT_TOKENS}

| # | Query | Score | Pass |
|---|-------|-------|------|
MDEOF

    # Append rows
    jq -r '.results | to_entries[] | 
      "| \(.key + 1) | \(.value.query[0:60]) | \(((.value.scores | to_entries[0].value // 0) * 100 | floor)%) | \(if .value.passed then "✅" else "❌" end) |"' \
      "$TMP_RESULT" >> "$TMP_COMMENT" 2>/dev/null || true

    # Dashboard link
    if [ -n "$EVAL_ID" ]; then
      cat >> "$TMP_COMMENT" <<MDEOF

[📊 View in AI Evaluator →](https://www.aievaluator.dev/evaluations/${EVAL_ID}/report)
MDEOF
    fi

    # Post via gh CLI
    if command -v gh &>/dev/null; then
      if gh pr comment "${GITHUB_HEAD_REF:-}" --body-file "$TMP_COMMENT" 2>/dev/null; then
        ok "PR comment posted"
      else
        warn "Could not post PR comment (gh CLI failed)"
      fi
    else
      warn "gh CLI not found — skipping PR comment"
    fi
  else
    info "Not a PR event — skipping comment"
  fi
fi

# ── Clean up ────────────────────────────────────────────────────────

rm -f "$TMP_RESULT" "$TMP_COMMENT"

# ── Exit with appropriate code ──────────────────────────────────────

if [ "$MEETS_THRESHOLD" != "1" ]; then
  error "Evaluation failed: score ${SCORE_PCT}% < threshold ${MIN_SCORE}"
  exit 1
fi

section "Evaluation complete — all checks passed"
exit 0

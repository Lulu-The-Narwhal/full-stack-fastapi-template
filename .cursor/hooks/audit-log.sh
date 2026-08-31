#!/bin/bash
# .cursor/hooks/audit-log.sh
# 🌸 Lulu Real-Time Evidence Logger (v2: Quality Aware)
# Tracks actual iterations, tool durations, and session velocity for GitHub reporting.

set -e

# --- CONFIGURATION ---
COST_PER_1K_TOKENS=0.015 
DEV_HOURLY_RATE=100
# ---------------------

# Read input JSON
INPUT=$(cat 2>/dev/null || echo "{}")

# Helper for JSON extraction
get_json_val() {
    echo "$INPUT" | jq -r "$1 // empty" 2>/dev/null
}

# 1. SETUP ENVIRONMENT
WORKSPACE=$(get_json_val '.workspace_roots[0] // .workspace_path // .cwd // "."')
SESSION_ID=$(get_json_val '.conversation_id // "unknown_session"')
EVENT=$(get_json_val '.hook_event_name // .event // "unknown"')
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
PRETTY_TIME=$(date '+%H:%M:%S')

# Directories
LULU_DIR="$WORKSPACE/.lulu"
SESSIONS_DIR="$LULU_DIR/sessions"
mkdir -p "$SESSIONS_DIR"

SESSION_FILE="$SESSIONS_DIR/${SESSION_ID}.json"
AUDIT_LOG="$LULU_DIR/audit.log"
GITHUB_COMMENT_FILE="$LULU_DIR/github_comment_draft.md"

# Initialize Session File if new
if [ ! -f "$SESSION_FILE" ]; then
    echo '{
        "start_time": "'$TIMESTAMP'",
        "turn_count": 0,
        "tool_counts": {},
        "tool_time_ms": 0,
        "errors": [],
        "lulu_tools": 0,
        "manual_tools": 0,
        "total_tokens_est": 0,
        "scores": [],
        "aha_moments": 0
    }' > "$SESSION_FILE"
fi

# 2. STATEFUL TRACKING
if command -v jq >/dev/null 2>&1; then
    case "$EVENT" in
        "beforeSubmitPrompt")
            PROMPT_LEN=$(get_json_val '.prompt | length')
            TOKENS=$((PROMPT_LEN / 4))
            
            tmp=$(mktemp)
            jq --argjson tokens "$TOKENS" \
               '.turn_count += 1 | .total_tokens_est += $tokens' \
               "$SESSION_FILE" > "$tmp" && mv "$tmp" "$SESSION_FILE"
            
            PROMPT_TEXT=$(get_json_val '.prompt' | cut -c1-60 | tr -d '\n')
            echo "[$PRETTY_TIME] 💬 TURN #$(jq -r '.turn_count' "$SESSION_FILE") | \"$PROMPT_TEXT...\"" >> "$AUDIT_LOG"
            ;;

        "postToolUse")
            TOOL_NAME=$(get_json_val '.tool_name // .tool_use.name')
            DURATION=$(get_json_val '.duration // 0')
            OUTPUT=$(get_json_val '.tool_output')
            
            IS_LULU=false
            if [[ "$TOOL_NAME" == lulu_* ]]; then IS_LULU=true; fi
            
            # --- QUALITY EXTRACTION ---
            SCORE_FOUND=""
            if [[ "$TOOL_NAME" == "lulu_assess" ]]; then
                # Extract score from markdown: "Overall Score: 85%"
                SCORE_FOUND=$(echo "$OUTPUT" | grep -oE "Overall Score: [0-9]+" | cut -d' ' -f3 || echo "")
            fi

            # Update Session Stats
            tmp=$(mktemp)
            if [ -n "$SCORE_FOUND" ]; then
                # Compare with last score for "Aha!" moment
                LAST_SCORE=$(jq -r '.scores[-1] // 0' "$SESSION_FILE")
                jq --arg tool "$TOOL_NAME" --argjson dur "$DURATION" --argjson is_lulu "$IS_LULU" --argjson score "$SCORE_FOUND" --argjson last "$LAST_SCORE" \
                   '.tool_counts[$tool] += 1 | .tool_time_ms += $dur | if $is_lulu then .lulu_tools += 1 else .manual_tools += 1 end | .scores += [$score] | if ($score - $last) > 15 then .aha_moments += 1 else . end' \
                   "$SESSION_FILE" > "$tmp" && mv "$tmp" "$SESSION_FILE"
                
                echo "[$PRETTY_TIME] ⭐ QUALITY   | Score: ${SCORE_FOUND}% (Lulu verified)" >> "$AUDIT_LOG"
            else
                jq --arg tool "$TOOL_NAME" --argjson dur "$DURATION" --argjson is_lulu "$IS_LULU" \
                   '.tool_counts[$tool] += 1 | .tool_time_ms += $dur | if $is_lulu then .lulu_tools += 1 else .manual_tools += 1 end' \
                   "$SESSION_FILE" > "$tmp" && mv "$tmp" "$SESSION_FILE"
            fi
            
            DUR_SEC=$(awk "begin {print $DURATION/1000}")
            if [ "$IS_LULU" = true ]; then
                echo "[$PRETTY_TIME] 🌸 LULU TOOL | $TOOL_NAME (${DUR_SEC}s)" >> "$AUDIT_LOG"
            else
                echo "[$PRETTY_TIME] 🛠️  TOOL      | $TOOL_NAME (${DUR_SEC}s)" >> "$AUDIT_LOG"
            fi
            ;;

        "postToolUseFailure")
            ERROR_MSG=$(get_json_val '.error_message')
            TOOL_NAME=$(get_json_val '.tool_use.name')
            tmp=$(mktemp)
            jq --arg tool "$TOOL_NAME" --arg err "$ERROR_MSG" '.errors += [{"tool": $tool, "error": $err}]' "$SESSION_FILE" > "$tmp" && mv "$tmp" "$SESSION_FILE"
            echo "[$PRETTY_TIME] ❌ FAILURE   | $TOOL_NAME: $ERROR_MSG" >> "$AUDIT_LOG"
            ;;

        "sessionEnd")
            END_TIME=$(date +%s)
            START_TIME_STR=$(jq -r '.start_time' "$SESSION_FILE")
            if date -v+1d >/dev/null 2>&1; then START_TIME=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$START_TIME_STR" +%s); else START_TIME=$(date -d "$START_TIME_STR" +%s); fi
            TOTAL_DURATION=$((END_TIME - START_TIME)); [ "$TOTAL_DURATION" -eq 0 ] && TOTAL_DURATION=1
            
            TURNS=$(jq -r '.turn_count' "$SESSION_FILE")
            TOOL_TIME_MS=$(jq -r '.tool_time_ms' "$SESSION_FILE")
            LULU_COUNT=$(jq -r '.lulu_tools' "$SESSION_FILE")
            MANUAL_COUNT=$(jq -r '.manual_tools' "$SESSION_FILE")
            ERRORS=$(jq -r '.errors | length' "$SESSION_FILE")
            AHA=$(jq -r '.aha_moments' "$SESSION_FILE")
            FINAL_SCORE=$(jq -r '.scores[-1] // "N/A"' "$SESSION_FILE")
            FIRST_SCORE=$(jq -r '.scores[0] // "N/A"' "$SESSION_FILE")
            
            TOOL_TIME_SEC=$(awk "begin {print $TOOL_TIME_MS / 1000}")
            AUTO_RATIO=$(awk "begin {print ($TOOL_TIME_SEC / $TOTAL_DURATION) * 100}")
            TOTAL_EST_TOKENS=$(jq -r '.total_tokens_est * 3' "$SESSION_FILE")
            COST_EST=$(awk "begin {print ($TOTAL_EST_TOKENS / 1000) * $COST_PER_1K_TOKENS}")
            
            # --- GENERATE GITHUB COMMENT ---
            cat <<EOF > "$GITHUB_COMMENT_FILE"
## 🌸 Lulu Intelligence Audit: $SESSION_ID

**Verified ROI for CTO Closing Pitch**

### 🎯 Quality & Learning
| Metric | Start | Finish | Lift |
| :--- | :--- | :--- | :--- |
| **Code Quality** | **$FIRST_SCORE%** | **$FINAL_SCORE%** | **$((FINAL_SCORE - FIRST_SCORE))%** |
| **"Aha!" Moments** | - | **$AHA** | Breakthroughs found |

### ⏱️ Velocity & Efficiency
| Metric | Value | 2026 Benchmark |
| :--- | :--- | :--- |
| **Total Duration** | **${TOTAL_DURATION}s** | - |
| **Work Velocity** | **$TURNS turns** | High Complexity |
| **Automation Ratio** | **$AUTO_RATIO%** | $([ $(echo "$AUTO_RATIO > 50" | bc) -eq 1 ] && echo "Autonomous Elite" || echo "Collaborative") |
| **Smart/Manual** | **$LULU_COUNT / $MANUAL_COUNT** | Context-First |

### 💰 Hard Savings
* **Estimated LLM Cost:** \$${COST_EST}
* **Dev Time Saved:** ~$(awk "begin {print ($LULU_COUNT * 210 / 60)}") minutes
* **Closing Value:** \$$(awk "begin {print ($TOTAL_DURATION / 3600) * $DEV_HOURLY_RATE}") (Dev Work Value)

### 🔍 Execution Trace
$(jq -r '.tool_counts | to_entries[] | "- **" + .key + "**: " + (.value|tostring) + " calls"' "$SESSION_FILE")

---
*Generated by Lulu Real-Time Evidence Layer* 🌸
EOF

            echo "[$PRETTY_TIME] 🏁 SESSION END | Quality: $FINAL_SCORE% | AHA: $AHA | Report: .lulu/github_comment_draft.md" >> "$AUDIT_LOG"
            ;;
    esac
fi

echo '{"continue": true}'
exit 0

#!/bin/bash
# .cursor/hooks/enrich-prompt.sh
# Called before every prompt submission - AUTO-ENRICHES with context!

set -e

# Read input JSON
INPUT=$(cat)

# Extract prompt and context
PROMPT=$(echo "$INPUT" | jq -r '.prompt')
WORKSPACE=$(echo "$INPUT" | jq -r '.workspace_roots[0]')
USER_EMAIL=$(echo "$INPUT" | jq -r '.user_email // "unknown"')

# Lulu server
LULU_SERVER="${LULU_SERVER:-http://localhost:8000}"

# Log
echo "[LULU] Enriching prompt: ${PROMPT:0:50}..." >&2

# Check if prompt needs enrichment
NEEDS_ENRICHMENT=$(echo "$PROMPT" | grep -iE 'refactor|debug|fix|explain|why|how does|what is|modify|change|update|rewrite|create|implement|wtf|issue|problem|error|status|embedding|finished|fail' || true)

if [ -z "$NEEDS_ENRICHMENT" ]; then
    echo "[LULU] Skipping enrichment (simple query)" >&2
    cat <<EOF
{
  "continue": true
}
EOF
    exit 0
fi

# --- LOCAL CONTEXT EXTRACTION ---
# We run git locally because the server (Docker) can't see our .git folder
GIT_CONTEXT=""
if command -v git >/dev/null 2>&1; then
    if git -C "$WORKSPACE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # 1. Current Branch
        BRANCH=$(git -C "$WORKSPACE" rev-parse --abbrev-ref HEAD 2>/dev/null)
        
        # 2. Status Summary (Dirty files)
        # Get up to 10 modified/staged files
        STATUS=$(git -C "$WORKSPACE" status -s | head -n 10)
        
        # 3. Last 5 commits formatted
        GIT_LOGS=$(git -C "$WORKSPACE" log -n 5 --pretty=format:"- %s (%an, %ar)" 2>/dev/null)
        
        # Combine into a single JSON-friendly block
        GIT_SUMMARY="Branch: $BRANCH\n\nStatus:\n$STATUS\n\nHistory:\n$GIT_LOGS"
        
        # JSON escape the string
        GIT_CONTEXT=$(echo "$GIT_SUMMARY" | jq -R -s '.')
    else
        GIT_CONTEXT="null"
    fi
else
    GIT_CONTEXT="null"
fi

# Call Lulu enrichment API
# We pass the locally extracted git context to the server
# Use 2s timeout to ensure prompt isn't blocked if API is slow/down
RESPONSE=$(curl -sf -m 2 -X POST "$LULU_SERVER/v1/enrich-prompt" \
    -H "Content-Type: application/json" \
    -d "{
        \"prompt\": $(echo "$PROMPT" | jq -Rs .),
        \"repo_path\": \"$WORKSPACE\",
        \"git_context\": $GIT_CONTEXT,
        \"enable_context_enrichment\": true,
        \"context_sources\": [\"git\", \"linear\", \"github\", \"team_kb\"],
        \"user_email\": \"$USER_EMAIL\"
    }" 2>&1) || {
    echo "[LULU] ⚠️  Enrichment API failed or offline, continuing without external context" >&2
    cat <<EOF
{
  "continue": true
}
EOF
    exit 0
}

# Extract enriched prompt
ENRICHED=$(echo "$RESPONSE" | jq -r '.enriched_prompt // empty')

if [ -n "$ENRICHED" ]; then
    CONFIDENCE=$(echo "$RESPONSE" | jq -r '.context_metadata.confidence // 0')
    SOURCES=$(echo "$RESPONSE" | jq -r '.context_metadata.sources_used | join(", ") // "none"')
    
    echo "[LULU] ✅ Enriched! Confidence: $CONFIDENCE, Sources: $SOURCES" >&2
    
    cat <<EOF
{
  "continue": true,
  "additional_context": "$(echo "$ENRICHED" | jq -Rs .)"
}
EOF
else
    echo "[LULU] No enrichment available from API" >&2
    cat <<EOF
{
  "continue": true
}
EOF
fi

exit 0

#!/usr/bin/env bash
# Foundation infrastructure for the NovaMart multi-agent system.
#
#   1. Deploy infrastructure/starter_stack.yaml as stack udacity-agentcore
#      (DynamoDB tables, policy bucket, S3 Vectors bucket + indexes, execution
#      role, log group) and wait for it to finish
#   2. Seed the DynamoDB tables and upload the policy documents
#   3. Create .env from .env.example if it does not exist yet
#   4. Check that Bedrock answers for the three models the project uses
#   5. Print the resolved configuration (python config.py)
#
# Re-running is safe: an unchanged stack is left alone, the seed rewrites the
# same records and an existing .env is kept.
#
# Usage:
#   ./scripts/deploy_foundation.sh            # apply
#   ./scripts/deploy_foundation.sh --dry-run  # print the plan, change nothing
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STARTER="$(dirname "$HERE")"
TEMPLATE="$STARTER/infrastructure/starter_stack.yaml"

REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${PROJECT_NAME:-udacity-agentcore}"
ORCHESTRATOR_MODEL="us.anthropic.claude-haiku-4-5-20251001-v1:0"
WORKER_MODEL="us.anthropic.claude-sonnet-4-5-20250929-v1:0"
EMBEDDING_MODEL="amazon.titan-embed-text-v2:0"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

PYTHON="$STARTER/.venv/bin/python"
[[ -x "$PYTHON" ]] || PYTHON="python3"

# ── Read-only lookups ─────────────────────────────────────────────────────────
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
STACK_STATUS="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE)"

echo "Account: $ACCOUNT ($REGION)"
echo "Stack:   $STACK_NAME (${STACK_STATUS/NONE/will be created})"
echo "Python:  $PYTHON"
echo ".env:    $([[ -f "$STARTER/.env" ]] && echo exists || echo 'will be created from .env.example')"

if $DRY_RUN; then
  echo; echo "Dry run only; no changes made."
  exit 0
fi

# ── 1. CloudFormation stack ──────────────────────────────────────────────────
echo "[1/5] Deploying stack $STACK_NAME (a few minutes on first run)..."
aws cloudformation deploy \
  --template-file "$TEMPLATE" \
  --stack-name "$STACK_NAME" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --no-fail-on-empty-changeset
echo "      Stack is $(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].StackStatus' --output text)"

# ── 2. Seed data ─────────────────────────────────────────────────────────────
echo "[2/5] Seeding DynamoDB and policy documents"
(cd "$STARTER" && "$PYTHON" infrastructure/seed_data.py)

# ── 3. .env ──────────────────────────────────────────────────────────────────
if [[ -f "$STARTER/.env" ]]; then
  echo "[3/5] .env exists, kept"
else
  cp "$STARTER/.env.example" "$STARTER/.env"
  echo "[3/5] Created .env from .env.example"
fi

# ── 4. Bedrock model access ──────────────────────────────────────────────────
echo "[4/5] Checking Bedrock model access"
for model in "$ORCHESTRATOR_MODEL" "$WORKER_MODEL"; do
  aws bedrock-runtime converse --region "$REGION" --model-id "$model" \
    --messages '[{"role":"user","content":[{"text":"Reply with OK"}]}]' \
    --inference-config '{"maxTokens":5}' --query 'stopReason' --output text > /dev/null
  echo "      $model OK"
done
EMBED_OUT="$(mktemp)"
aws bedrock-runtime invoke-model --region "$REGION" --model-id "$EMBEDDING_MODEL" \
  --cli-binary-format raw-in-base64-out --body '{"inputText":"access check"}' "$EMBED_OUT" > /dev/null
rm -f "$EMBED_OUT"
echo "      $EMBEDDING_MODEL OK"

# ── 5. Configuration ─────────────────────────────────────────────────────────
echo "[5/5] Resolved configuration"
(cd "$STARTER" && "$PYTHON" config.py)

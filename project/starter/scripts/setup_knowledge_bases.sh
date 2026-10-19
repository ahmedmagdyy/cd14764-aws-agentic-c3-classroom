#!/usr/bin/env bash
# Knowledge Bases for the NovaMart returns, shipping and warranty policies.
#
#   1. Create or reuse the Bedrock service role and apply its access policy
#   2. Create or reuse three S3 Vectors Knowledge Bases and wait for ACTIVE
#   3. Create or reuse their S3 data sources and wait for AVAILABLE
#   4. Sync each data source, wait for COMPLETE and print document statistics
#   5. Save the three Knowledge Base IDs to .env, preserving other settings
#
# AWS calls that change something (creation skipped for existing resources;
# sync runs every time; the inline policy runs unless the role is overridden):
#   1. iam create-role                    Bedrock service role
#   2. iam put-role-policy                NovaMartKnowledgeBaseAccess
#   3. bedrock-agent create-knowledge-base Three VECTOR / S3_VECTORS bases
#   4. bedrock-agent create-data-source    Three S3 policy prefixes
#   5. bedrock-agent start-ingestion-job   Sync each data source
#
# Usage:
#   ./scripts/setup_knowledge_bases.sh            # apply
#   ./scripts/setup_knowledge_bases.sh --dry-run  # print plan and payloads only
#   KB_ROLE_ARN=arn:aws:iam::ACCOUNT:role/ROLE ./scripts/setup_knowledge_bases.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STARTER="$(dirname "$HERE")"
ENV_FILE="$STARTER/.env"
REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT_NAME:-udacity-agentcore}"
ROLE_NAME="AmazonBedrockExecutionRoleForKnowledgeBase_novamart"
ROLE_ARN="${KB_ROLE_ARN:-}"
DRY_RUN=false
case "${1:-}" in
  --dry-run) DRY_RUN=true ;;
  "") ;;
  *) echo "Usage: $0 [--dry-run]" >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: $0 [--dry-run]" >&2; exit 1; }
BA=(aws bedrock-agent --region "$REGION")
KB_TABLE=(
  'returns|ReturnsVectorIndex|RETURNS_KB_ID'
  'shipping|ShippingVectorIndex|SHIPPING_KB_ID'
  'warranty|WarrantyVectorIndex|WARRANTY_KB_ID'
)

wait_for() {  # wait_for <description> <done status> <command that prints a status>
  local what="$1" done="$2"; shift 2
  local status
  for _ in $(seq 1 120); do
    status="$("$@")"
    [[ "$status" == "$done" ]] && { echo "      $what is $status"; return 0; }
    [[ "$status" == FAILED || "$status" == *FAIL* || "$status" == STOPPED ]] && {
      echo "      $what is $status" >&2; return 1; }
    sleep 5
  done
  echo "      Timed out waiting for $what (last status: $status)" >&2
  return 1
}

export_value() {
  local name="${PROJECT}-$1" value
  value="$(aws cloudformation list-exports --region "$REGION" \
    --query "Exports[?Name=='${name}'].Value | [0]" --output text)"
  if [[ -z "$value" || "$value" == None ]]; then
    echo "Missing export $name; deploy the foundation stack first: scripts/deploy_foundation.sh" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

save_env() {  # save_env key value
  local tmp
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  if awk -v key="$1" -v value="$2" '
    index($0, key "=") == 1 { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$ENV_FILE" > "$tmp"; then
    mv "$tmp" "$ENV_FILE"
  else
    rm -f "$tmp"
    return 1
  fi
}

# ── Read-only lookups ─────────────────────────────────────────────────────────
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="$(export_value PolicyBucket)"
VECTOR_BUCKET_ARN="$(export_value VectorBucketArn)"
INDEX_NAMES=()
for row in "${KB_TABLE[@]}"; do
  IFS='|' read -r domain export_name env_key <<< "$row"
  INDEX_NAMES+=("$(export_value "$export_name")")
done
if [[ -z "$ROLE_ARN" ]]; then
  if out="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text 2>&1)"; then
    ROLE_ARN="$out"
  elif [[ "$out" != *NoSuchEntity* ]]; then
    echo "$out" >&2
    exit 1
  fi
fi
KB_IDS=()
DS_IDS=()
STORAGE_CONFIGS=()
DS_CONFIGS=()
for i in "${!KB_TABLE[@]}"; do
  IFS='|' read -r domain export_name env_key <<< "${KB_TABLE[$i]}"
  kb_name="novamart-${domain}-policy-kb"
  ds_name="novamart-${domain}-policy-docs"
  kb_id="$("${BA[@]}" list-knowledge-bases \
    --query "knowledgeBaseSummaries[?name=='${kb_name}'].knowledgeBaseId | [0]" --output text)"
  [[ "$kb_id" != None ]] || kb_id=""
  ds_id=""
  if [[ -n "$kb_id" ]]; then
    ds_id="$("${BA[@]}" list-data-sources --knowledge-base-id "$kb_id" \
      --query "dataSourceSummaries[?name=='${ds_name}'].dataSourceId | [0]" --output text)"
    [[ "$ds_id" != None ]] || ds_id=""
  fi
  KB_IDS+=("$kb_id")
  DS_IDS+=("$ds_id")
  STORAGE_CONFIGS+=("$(jq -n --arg bucket "$VECTOR_BUCKET_ARN" --arg index "${INDEX_NAMES[$i]}" '{
    type: "S3_VECTORS", s3VectorsConfiguration: {vectorBucketArn: $bucket, indexName: $index}}')")
  DS_CONFIGS+=("$(jq -n --arg bucket "arn:aws:s3:::$BUCKET" --arg prefix "policies/$domain/" '{
    type: "S3", s3Configuration: {bucketArn: $bucket, inclusionPrefixes: [$prefix]}}')")
done

TRUST_POLICY="$(jq -n --arg acct "$ACCOUNT" --arg region "$REGION" '{
  Version: "2012-10-17", Statement: [{
    Effect: "Allow", Principal: {Service: "bedrock.amazonaws.com"}, Action: "sts:AssumeRole",
    Condition: {
      StringEquals: {"aws:SourceAccount": $acct},
      ArnLike: {"AWS:SourceArn": "arn:aws:bedrock:\($region):\($acct):knowledge-base/*"}
    }}]}')"
MODEL_ARN="arn:aws:bedrock:${REGION}::foundation-model/amazon.titan-embed-text-v2:0"
ACCESS_POLICY="$(jq -n --arg acct "$ACCOUNT" --arg bucket "arn:aws:s3:::$BUCKET" \
  --arg model "$MODEL_ARN" --arg vector "$VECTOR_BUCKET_ARN" \
  --argjson indexes "$(printf '%s\n' "${INDEX_NAMES[@]}" | jq -R . | jq -s .)" '{
  Version: "2012-10-17", Statement: [
    {Effect: "Allow", Action: ["bedrock:InvokeModel"], Resource: [$model]},
    {Effect: "Allow", Action: ["s3:ListBucket"], Resource: [$bucket],
     Condition: {StringEquals: {"aws:ResourceAccount": $acct}}},
    {Effect: "Allow", Action: ["s3:GetObject"], Resource: [$bucket + "/policies/*"],
     Condition: {StringEquals: {"aws:ResourceAccount": $acct}}},
    {Effect: "Allow", Action: ["s3vectors:PutVectors", "s3vectors:GetVectors",
      "s3vectors:DeleteVectors", "s3vectors:QueryVectors", "s3vectors:GetIndex"],
     Resource: [$indexes[] | $vector + "/index/" + .]}
  ]}')"
KB_CONFIG="$(jq -n --arg model "$MODEL_ARN" '{
  type: "VECTOR", vectorKnowledgeBaseConfiguration: {
    embeddingModelArn: $model, embeddingModelConfiguration: {
      bedrockEmbeddingModelConfiguration: {dimensions: 1024, embeddingDataType: "FLOAT32"}}}}')"

echo "Account: $ACCOUNT ($REGION)"
echo "Project: $PROJECT"
echo "Bucket:  s3://$BUCKET"
echo "Vectors: $VECTOR_BUCKET_ARN"

if $DRY_RUN; then
  echo "[1/5] Role: ${ROLE_ARN:-create $ROLE_NAME}"
  if [[ -n "${KB_ROLE_ARN:-}" ]]; then
    echo "      KB_ROLE_ARN supplied; skip role creation and inline policy"
  else
    printf '\nTrust policy:\n%s\n\nInline policy (reapplied every run):\n%s\n' "$TRUST_POLICY" "$ACCESS_POLICY"
  fi
  echo "[2/5] Create missing Knowledge Bases and wait for ACTIVE"
  printf 'Knowledge Base configuration:\n%s\n' "$KB_CONFIG"
  for i in "${!KB_TABLE[@]}"; do
    IFS='|' read -r domain export_name env_key <<< "${KB_TABLE[$i]}"
    echo "      novamart-$domain-policy-kb: ${KB_IDS[$i]:-will be created}; description: NovaMart $domain policy documents"
    printf 'Storage configuration:\n%s\n' "${STORAGE_CONFIGS[$i]}"
  done
  echo "[3/5] Create missing data sources with deletion policy DELETE; wait for AVAILABLE"
  for i in "${!KB_TABLE[@]}"; do
    IFS='|' read -r domain export_name env_key <<< "${KB_TABLE[$i]}"
    echo "      novamart-$domain-policy-docs: ${DS_IDS[$i]:-will be created}"
    printf 'Data source configuration:\n%s\n' "${DS_CONFIGS[$i]}"
  done
  echo "[4/5] Sync all three data sources; wait for COMPLETE and print statistics"
  for row in "${KB_TABLE[@]}"; do
    IFS='|' read -r domain export_name env_key <<< "$row"
    echo "      novamart-$domain-policy-kb: start ingestion and report scanned / indexed / failed"
  done
  echo "[5/5] Update $ENV_FILE (create from .env.example if absent)"
  for i in "${!KB_TABLE[@]}"; do
    IFS='|' read -r domain export_name env_key <<< "${KB_TABLE[$i]}"
    echo "      $env_key=${KB_IDS[$i]:-<new Knowledge Base ID>}"
  done
  echo "Dry run only; no changes made."
  exit 0
fi

# ── 1. Service role ──────────────────────────────────────────────────────────
if [[ -n "${KB_ROLE_ARN:-}" ]]; then
  echo "[1/5] Using supplied role $ROLE_ARN; inline policy skipped"
else
  if [[ -z "$ROLE_ARN" ]]; then
    if out="$(aws iam create-role --role-name "$ROLE_NAME" \
      --description "Service role for NovaMart policy Knowledge Bases" \
      --assume-role-policy-document "$TRUST_POLICY" --query Role.Arn --output text 2>&1)"; then
      ROLE_ARN="$out"
    else
      echo "$out" >&2
      if [[ "$out" == *AccessDenied* ]]; then
        printf 'Rerun with KB_ROLE_ARN=$(aws cloudformation list-exports --region "%s" --query "Exports[?Name=='"'"'%s-AgentCoreRoleArn'"'"'].Value" --output text) scripts/setup_knowledge_bases.sh\n' "$REGION" "$PROJECT" >&2
      fi
      exit 1
    fi
    echo "[1/5] Created role $ROLE_ARN"
  else
    echo "[1/5] Role exists: $ROLE_ARN"
  fi
  aws iam put-role-policy --role-name "$ROLE_NAME" \
    --policy-name NovaMartKnowledgeBaseAccess --policy-document "$ACCESS_POLICY"
  echo "      Applied NovaMartKnowledgeBaseAccess"
fi

# ── 2. Knowledge Bases ───────────────────────────────────────────────────────
echo "[2/5] Knowledge Bases"
for i in "${!KB_TABLE[@]}"; do
  IFS='|' read -r domain export_name env_key <<< "${KB_TABLE[$i]}"
  if [[ -z "${KB_IDS[$i]}" ]]; then
    # A freshly created role can take a few seconds to become assumable.
    for attempt in 1 2 3 4 5 6; do
      if out="$("${BA[@]}" create-knowledge-base --name "novamart-$domain-policy-kb" \
        --description "NovaMart $domain policy documents" --role-arn "$ROLE_ARN" \
        --knowledge-base-configuration "$KB_CONFIG" --storage-configuration "${STORAGE_CONFIGS[$i]}" \
        --query knowledgeBase.knowledgeBaseId --output text 2>&1)"; then
        KB_IDS[$i]="$out"; break
      fi
      if [[ "$out" == *[Rr]ole* && $attempt -lt 6 ]]; then
        echo "      Role not usable yet, retrying in 10s..."; sleep 10
      else
        echo "$out" >&2; exit 1
      fi
    done
    echo "      Created novamart-$domain-policy-kb: ${KB_IDS[$i]}"
  else
    echo "      novamart-$domain-policy-kb exists: ${KB_IDS[$i]}"
  fi
  wait_for "$domain knowledge base" ACTIVE "${BA[@]}" get-knowledge-base \
    --knowledge-base-id "${KB_IDS[$i]}" --query knowledgeBase.status --output text
done

# ── 3. Data sources ──────────────────────────────────────────────────────────
echo "[3/5] Data sources"
for i in "${!KB_TABLE[@]}"; do
  IFS='|' read -r domain export_name env_key <<< "${KB_TABLE[$i]}"
  if [[ -z "${DS_IDS[$i]}" ]]; then
    DS_IDS[$i]="$("${BA[@]}" create-data-source --knowledge-base-id "${KB_IDS[$i]}" \
      --name "novamart-$domain-policy-docs" --data-source-configuration "${DS_CONFIGS[$i]}" \
      --data-deletion-policy DELETE --query dataSource.dataSourceId --output text)"
    echo "      Created novamart-$domain-policy-docs: ${DS_IDS[$i]}"
  else
    echo "      novamart-$domain-policy-docs exists: ${DS_IDS[$i]}"
  fi
  wait_for "$domain data source" AVAILABLE "${BA[@]}" get-data-source \
    --knowledge-base-id "${KB_IDS[$i]}" --data-source-id "${DS_IDS[$i]}" --query dataSource.status --output text
done

# ── 4. Sync ──────────────────────────────────────────────────────────────────
echo "[4/5] Syncing policy documents"
for i in "${!KB_TABLE[@]}"; do
  IFS='|' read -r domain export_name env_key <<< "${KB_TABLE[$i]}"
  job_id="$("${BA[@]}" start-ingestion-job --knowledge-base-id "${KB_IDS[$i]}" \
    --data-source-id "${DS_IDS[$i]}" --query ingestionJob.ingestionJobId --output text)"
  wait_for "$domain sync" COMPLETE "${BA[@]}" get-ingestion-job \
    --knowledge-base-id "${KB_IDS[$i]}" --data-source-id "${DS_IDS[$i]}" \
    --ingestion-job-id "$job_id" --query ingestionJob.status --output text
  stats="$("${BA[@]}" get-ingestion-job --knowledge-base-id "${KB_IDS[$i]}" \
    --data-source-id "${DS_IDS[$i]}" --ingestion-job-id "$job_id" --query ingestionJob.statistics --output json)"
  jq -r --arg domain "$domain" '"      \($domain): numberOfDocumentsScanned=\(.numberOfDocumentsScanned // 0) / Indexed=\((.numberOfNewDocumentsIndexed // 0) + (.numberOfModifiedDocumentsIndexed // 0)) / Failed=\(.numberOfDocumentsFailed // 0)"' <<< "$stats"
done

# ── 5. .env ──────────────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  cp "$STARTER/.env.example" "$ENV_FILE"
fi
echo "[5/5] Writing Knowledge Base IDs to $ENV_FILE"
for i in "${!KB_TABLE[@]}"; do
  IFS='|' read -r domain export_name env_key <<< "${KB_TABLE[$i]}"
  save_env "$env_key" "${KB_IDS[$i]}"
  echo "      $env_key=${KB_IDS[$i]}"
done
echo "Next: python tests/test_agent.py task5"

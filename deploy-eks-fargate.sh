#!/usr/bin/env bash
# User-configurable variables
REGION="us-east-1"
CLUSTER_NAME="n8n"
# Persist the EFS ID so the destroy script can clean up even on failures
EFS_ID_FILE="efs_id.txt"
# Persist the CloudFront distribution ID for cleanup
CF_ID_FILE="cloudfront_id.txt"
# Persist region and cluster name for the destroy script
DEPLOY_INFO_FILE="deploy_info.env"
# Aurora Serverless scaling configuration
AURORA_MIN_CAPACITY="${AURORA_MIN_CAPACITY:-0}"
AURORA_MAX_CAPACITY="${AURORA_MAX_CAPACITY:-2}"
N8N_HOST="${N8N_HOST:-localhost}"
N8N_PROTOCOL="${N8N_PROTOCOL:-http}"
WEBHOOK_URL="${WEBHOOK_URL:-https://$N8N_HOST}"

usage() {
  echo "Usage: $0 [--region REGION] [--k8sname NAME] [--domain DOMAIN]" >&2
  exit 1
}

# Parse optional arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --region)
      REGION="$2"
      shift 2
      ;;
    --k8sname)
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --domain)
      N8N_HOST="$2"
      WEBHOOK_URL="https://$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

set -euo pipefail

# Disable AWS CLI pager for non-interactive execution
export AWS_PAGER=""

# Ensure required tools are available before continuing
missing=()
for cmd in aws eksctl kubectl helm curl openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done
if [ "${#missing[@]}" -ne 0 ]; then
  echo "Missing required tools: ${missing[*]}. Please install them and rerun." >&2
  exit 1
fi

# Validate region and cluster name after ensuring AWS CLI is available
if ! aws ec2 describe-regions --query 'Regions[].RegionName' --output text \
  | tr '\t' '\n' | grep -qx "$REGION"; then
  echo "Invalid AWS region: $REGION" >&2
  exit 1
fi
if [[ ! $CLUSTER_NAME =~ ^[A-Za-z][-A-Za-z0-9]{0,127}$ ]]; then
  echo "Invalid cluster name: $CLUSTER_NAME" >&2
  exit 1
fi

# Persist region and cluster name for the destroy script
cat >"$DEPLOY_INFO_FILE" <<EOF
REGION="$REGION"
CLUSTER_NAME="$CLUSTER_NAME"
EOF

# Precompute Load Balancer Controller IAM policy ARN
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

# Verify required IAM permissions before continuing
REQUIRED_ACTIONS=(
  "elasticfilesystem:CreateFileSystem"
  "elasticfilesystem:CreateMountTarget"
  "ec2:DescribeSubnets"
  "ec2:CreateSecurityGroup"
  "ec2:ModifyVpcAttribute"
  "ec2:AuthorizeSecurityGroupIngress"
  "ec2:DescribeSecurityGroups"
  "ec2:DescribeManagedPrefixLists"
  "rds:CreateDBCluster"
  "rds:CreateDBInstance"
  "rds:CreateDBSubnetGroup"
  "secretsmanager:CreateSecret"
  "secretsmanager:UpdateSecret"
  "secretsmanager:DescribeSecret"
  "secretsmanager:ListSecrets"
  "secretsmanager:GetSecretValue"
  "rds-data:ExecuteStatement"
  "iam:CreatePolicy"
  "iam:GetPolicy"
  "iam:GetPolicyVersion"
  "iam:ListPolicyVersions"
  "iam:DeletePolicyVersion"
  "iam:CreatePolicyVersion"
  "iam:SimulatePrincipalPolicy"
  "cloudfront:CreateDistribution"
  "cloudfront:GetDistribution"
  "cloudfront:GetDistributionConfig"
  "cloudfront:UpdateDistribution"
  "cloudfront:ListCachePolicies"
  "cloudfront:DeleteDistribution"
)

check_permissions() {
  local arn account role
  arn=$(aws sts get-caller-identity --query Arn --output text)
  if [[ $arn == arn:aws:sts::*:assumed-role/* ]]; then
    account=$(aws sts get-caller-identity --query Account --output text)
    role=$(echo "$arn" | cut -d'/' -f2)
    arn="arn:aws:iam::${account}:role/${role}"
  fi
  local missing=()
  for action in "${REQUIRED_ACTIONS[@]}"; do
    if ! aws iam simulate-principal-policy \
      --policy-source-arn "$arn" \
      --action-names "$action" \
      --query 'EvaluationResults[0].EvalDecision' --output text | grep -q allowed; then
      missing+=("$action")
    fi
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    echo "Missing required IAM permissions:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
  fi
}

ensure_lb_policy() {
  if ! aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    curl -fsSL -o iam_policy.json \
      https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.3/docs/install/iam_policy.json
    aws iam create-policy \
      --policy-name "$POLICY_NAME" \
      --policy-document file://iam_policy.json >/dev/null
    rm -f iam_policy.json
  else
    default_version=$(aws iam get-policy --policy-arn "$POLICY_ARN" \
      --query 'Policy.DefaultVersionId' --output text)
    doc=$(aws iam get-policy-version --policy-arn "$POLICY_ARN" \
      --version-id "$default_version" --query 'PolicyVersion.Document' --output json)
    if ! echo "$doc" | grep -q "DescribeListenerAttributes"; then
      curl -fsSL -o iam_policy.json \
        https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.13.3/docs/install/iam_policy.json
      if [ "$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
        --query 'Versions' --output json | grep -c 'VersionId')" -ge 5 ]; then
        oldest=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
          --query "sort_by(Versions,&CreateDate)[?IsDefaultVersion==\`false\`][0].VersionId" --output text)
        aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$oldest"
      fi
      aws iam create-policy-version --policy-arn "$POLICY_ARN" \
        --policy-document file://iam_policy.json --set-as-default >/dev/null
      rm -f iam_policy.json
    fi
  fi
}

wait_for_alb() {
  while true; do
    host=$(kubectl get ingress n8n -n n8n \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [ -n "$host" ]; then
      echo "$host"
      return
    fi
    echo "Waiting for ALB hostname..." >&2
    sleep 10
  done
}

create_cloudfront() {
  local lb_host=$1
  local cfg cf_id cache_policy ws_policy
  cache_policy=$(aws cloudfront list-cache-policies \
    --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='UseOriginCacheControlHeaders-QueryStrings'].CachePolicy.Id" \
    --output text)
  if [ -z "$cache_policy" ] || [ "$cache_policy" = "None" ]; then
    echo "Cache policy UseOriginCacheControlHeaders-QueryStrings not found" >&2
    return 1
  fi
  ws_policy="b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader
  cfg=$(mktemp)
  cat >"$cfg" <<EOF
{
  "CallerReference": "$(date +%s)",
  "Comment": "n8n distribution",
  "Enabled": true,
  "Origins": {
    "Quantity": 1,
    "Items": [{
      "Id": "n8n-alb",
      "DomainName": "$lb_host",
      "CustomOriginConfig": {
        "HTTPPort": 80,
        "HTTPSPort": 443,
        "OriginProtocolPolicy": "http-only"
      }
    }]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "n8n-alb",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 7,
      "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
      "CachedMethods": {
        "Quantity": 3,
        "Items": ["GET", "HEAD", "OPTIONS"]
      }
    },
    "CachePolicyId": "$cache_policy",
    "OriginRequestPolicyId": "$ws_policy",
    "Compress": true
  },
  "HttpVersion": "http2and3",
  "ViewerCertificate": {
    "CloudFrontDefaultCertificate": true,
    "MinimumProtocolVersion": "TLSv1.2_2021"
  },
  "PriceClass": "PriceClass_All",
  "IsIPV6Enabled": true
}
EOF
  cf_id=$(aws cloudfront create-distribution \
    --distribution-config file://"$cfg" \
    --query 'Distribution.Id' --output text)
  echo "$cf_id" > "$CF_ID_FILE"
  aws cloudfront wait distribution-deployed --id "$cf_id"
  CF_DOMAIN=$(aws cloudfront get-distribution --id "$cf_id" \
    --query 'Distribution.DomainName' --output text)
  rm -f "$cfg"
  echo "CloudFront domain: $CF_DOMAIN"
}

ensure_vpa_crd() {
  if ! kubectl get crd verticalpodautoscalers.autoscaling.k8s.io >/dev/null 2>&1; then
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/vpa-release-1.0/vertical-pod-autoscaler/deploy/vpa-v1-crd-gen.yaml
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/vpa-release-1.0/vertical-pod-autoscaler/deploy/vpa-rbac.yaml
  fi
}

check_permissions
ensure_lb_policy

# Create an EFS file system for the Fargate workloads
EFS_ID=$(aws efs create-file-system \
  --region "$REGION" \
  --tags Key=Name,Value="${CLUSTER_NAME}-efs" \
  --encrypted \
  --query 'FileSystemId' \
  --output text)

echo "Created EFS filesystem: $EFS_ID"
echo "$EFS_ID" > "$EFS_ID_FILE"

cfg="eks-fargate-cluster.generated.yaml"
sed -e "s/REPLACE_ME_CLUSTER_NAME/$CLUSTER_NAME/" \
    -e "s/REPLACE_ME_REGION/$REGION/" \
  eks-fargate-cluster.yaml > "$cfg"
eksctl create cluster -f "$cfg"

# Configure Fargate pods to send logs to CloudWatch as soon as the cluster exists
log_cfg="cloudwatch-logging.generated.yaml"
sed -e "s/REPLACE_ME_REGION/$REGION/" \
    -e "s/REPLACE_ME_CLUSTER_NAME/$CLUSTER_NAME/" \
  cloudwatch-logging.yaml > "$log_cfg"
kubectl apply -f "$log_cfg"

# Ensure the kube-system namespace runs on Fargate before deploying add-ons
eksctl create fargateprofile \
  --cluster "$CLUSTER_NAME" \
  --name system \
  --namespace kube-system \
  --labels app.kubernetes.io/name=metrics-server \
  --region "$REGION" 2>/dev/null || true

# Wait until the system profile becomes ACTIVE so pods can be scheduled
while true; do
  STATUS=$(aws eks describe-fargate-profile \
    --cluster-name "$CLUSTER_NAME" \
    --fargate-profile-name system \
    --region "$REGION" \
    --query 'fargateProfile.status' --output text 2>/dev/null || echo "")
  if [ "$STATUS" = "ACTIVE" ]; then
    break
  fi
  echo "Waiting for system Fargate profile to be ACTIVE..."
  sleep 10
done

# Restart kube-system pods to ensure logging configuration is picked up
kubectl delete pod -n kube-system --all \
  --force --grace-period=0 --ignore-not-found 2>/dev/null || true

# Install or update the metrics server add-on
if aws eks describe-addon --cluster-name "$CLUSTER_NAME" --region "$REGION" --addon-name metrics-server >/dev/null 2>&1; then
  aws eks update-addon --cluster-name "$CLUSTER_NAME" --region "$REGION" --addon-name metrics-server
else
  aws eks create-addon --cluster-name "$CLUSTER_NAME" --region "$REGION" --addon-name metrics-server
fi

# Retrieve networking information for later steps
SEC_GRP=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
SUBNETS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output text)
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

# Create a dedicated security group for the Application Load Balancer
ALB_SG_NAME="${CLUSTER_NAME}-alb-sg"
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$ALB_SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
if [ -z "$ALB_SG_ID" ] || [ "$ALB_SG_ID" = "None" ]; then
  ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name "$ALB_SG_NAME" \
    --description "n8n ALB access" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' --output text)
fi
CF_PREFIX=$(aws ec2 describe-managed-prefix-lists \
  --region "$REGION" \
  --query "PrefixLists[?PrefixListName=='com.amazonaws.global.cloudfront.origin-facing'].PrefixListId" \
  --output text)
if [ -z "$CF_PREFIX" ] || [ "$CF_PREFIX" = "None" ]; then
  echo "Unable to find CloudFront origin-facing prefix list" >&2
  exit 1
fi
aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG_ID" \
  --ip-permissions 'IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds=[{PrefixListId='"$CF_PREFIX"'}]' \
  --region "$REGION" 2>/dev/null || true
aws ec2 authorize-security-group-ingress \
  --group-id "$SEC_GRP" \
  --protocol tcp \
  --port 5678 \
  --source-group "$ALB_SG_ID" \
  --region "$REGION" 2>/dev/null || true

# Prefer the cluster's private subnets for RDS
PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" \
    Name=tag:kubernetes.io/role/internal-elb,Values=1 \
  --region "$REGION" --query 'Subnets[*].SubnetId' --output text)
if [ -n "$PRIVATE_SUBNETS" ]; then
  RDS_SUBNETS="$PRIVATE_SUBNETS"
else
  RDS_SUBNETS="$SUBNETS"
fi

# Install the AWS Load Balancer Controller if not present
if ! kubectl get deployment -n kube-system aws-load-balancer-controller >/dev/null 2>&1; then
  helm repo add eks https://aws.github.io/eks-charts
  helm repo update
  eksctl utils associate-iam-oidc-provider \
    --cluster "$CLUSTER_NAME" \
    --region "$REGION" --approve
  eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" \
    --namespace kube-system \
    --name aws-load-balancer-controller \
    --attach-policy-arn "$POLICY_ARN" \
    --override-existing-serviceaccounts \
    --region "$REGION" --approve
  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=false \
    --set region="$REGION" \
    --set vpcId="$VPC_ID" \
    --set serviceAccount.name=aws-load-balancer-controller
fi

# Create EFS mount targets in all cluster subnets so the EFS volume can be
# mounted by Fargate pods.

# Ensure DNS resolution works for EFS mounts
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}' --region "$REGION"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}' --region "$REGION"

# Allow NFS traffic from the cluster security group to the EFS mount targets
aws ec2 authorize-security-group-ingress \
  --group-id "$SEC_GRP" \
  --protocol tcp \
  --port 2049 \
  --source-group "$SEC_GRP" \
  --region "$REGION" 2>/dev/null || true

MOUNT_TARGET_IDS=()
create_failures=0
for subnet in $SUBNETS; do
  if mt_id=$(aws efs create-mount-target \
    --file-system-id "$EFS_ID" \
    --subnet-id "$subnet" \
    --security-groups "$SEC_GRP" \
    --region "$REGION" \
    --query 'MountTargetId' --output text 2>/dev/null); then
    echo "Created mount target $mt_id in subnet $subnet"
    MOUNT_TARGET_IDS+=("$mt_id")
  else
    echo "Failed to create mount target in subnet $subnet" >&2
    create_failures=1
  fi
done

if [ "$create_failures" -ne 0 ]; then
  echo "One or more mount targets failed to create" >&2
  exit 1
fi

echo "Waiting for EFS mount targets to become available..."
while true; do
  STATES=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" --region "$REGION" \
    --query 'MountTargets[*].LifeCycleState' --output text)
  all_ready=1
  for s in $STATES; do
    if [ "$s" != "available" ]; then
      all_ready=0
      break
    fi
  done
  if [ "$all_ready" -eq 1 ]; then
    break
  fi
  sleep 5
done
echo "All mount targets are available."

# Create an Aurora PostgreSQL cluster in the cluster VPC
DB_CLUSTER_ID="${CLUSTER_NAME}-aurora"
DB_SUBNET_GROUP="${CLUSTER_NAME}-aurora-subnet-group"
DB_SG_NAME="${CLUSTER_NAME}-aurora-sg"

DB_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$DB_SG_NAME" \
  --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
if [ -z "$DB_SG_ID" ] || [ "$DB_SG_ID" = "None" ]; then
  DB_SG_ID=$(aws ec2 create-security-group \
    --group-name "$DB_SG_NAME" \
    --description "n8n RDS access" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' --output text)
fi
aws ec2 authorize-security-group-ingress \
  --group-id "$DB_SG_ID" \
  --protocol tcp \
  --port 5432 \
  --source-group "$SEC_GRP" \
  --region "$REGION" 2>/dev/null || true

# shellcheck disable=SC2086
if ! aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" --region "$REGION" >/dev/null 2>&1; then
  aws rds create-db-subnet-group \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --db-subnet-group-description "n8n subnet group" \
    --subnet-ids $RDS_SUBNETS \
    --region "$REGION"
fi

DB_USER=$(awk '/POSTGRES_USER:/ {print $2}' postgres-secret.yaml)
DB_PASS=$(awk '/POSTGRES_PASSWORD:/ {print $2}' postgres-secret.yaml)
DB_NAME=$(awk '/POSTGRES_DB:/ {print $2}' postgres-secret.yaml)
NON_ROOT_USER=$(awk '/POSTGRES_NON_ROOT_USER:/ {print $2}' postgres-secret.yaml)
NON_ROOT_PASS=$(awk '/POSTGRES_NON_ROOT_PASSWORD:/ {print $2}' postgres-secret.yaml)

if ! aws rds describe-db-clusters --db-cluster-identifier "$DB_CLUSTER_ID" --region "$REGION" >/dev/null 2>&1; then
  aws rds create-db-cluster \
    --db-cluster-identifier "$DB_CLUSTER_ID" \
    --engine aurora-postgresql \
    --serverless-v2-scaling-configuration "MinCapacity=$AURORA_MIN_CAPACITY,MaxCapacity=$AURORA_MAX_CAPACITY" \
    --enable-http-endpoint \
    --storage-encrypted \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASS" \
    --vpc-security-group-ids "$DB_SG_ID" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --region "$REGION"
fi

SECRET_NAME="${DB_CLUSTER_ID}-master-secret"
SECRET_ARN=$(aws secretsmanager list-secrets --filters "Key=name,Values=$SECRET_NAME" \
  --query 'SecretList[0].ARN' --output text 2>/dev/null || echo "")
if [ -z "$SECRET_ARN" ] || [ "$SECRET_ARN" = "None" ]; then
  if ! out=$(aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --secret-string "{\"username\":\"$DB_USER\",\"password\":\"$DB_PASS\"}" \
    --region "$REGION" --query 'ARN' --output text 2>&1); then
    if echo "$out" | grep -q 'ResourceExistsException'; then
      SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" \
        --region "$REGION" --query 'ARN' --output text)
      aws secretsmanager update-secret \
        --secret-id "$SECRET_NAME" \
        --secret-string "{\"username\":\"$DB_USER\",\"password\":\"$DB_PASS\"}" \
        --region "$REGION" >/dev/null
    else
      echo "$out" >&2
      exit 1
    fi
  else
    SECRET_ARN="$out"
  fi
else
  aws secretsmanager update-secret \
    --secret-id "$SECRET_NAME" \
    --secret-string "{\"username\":\"$DB_USER\",\"password\":\"$DB_PASS\"}" \
    --region "$REGION" >/dev/null
fi

DB_ARN=$(aws rds describe-db-clusters --db-cluster-identifier "$DB_CLUSTER_ID" --region "$REGION" \
  --query 'DBClusters[0].DBClusterArn' --output text)
aws rds wait db-cluster-available --db-cluster-identifier "$DB_CLUSTER_ID" --region "$REGION"

if ! aws rds describe-db-instances --db-instance-identifier "${DB_CLUSTER_ID}-instance-1" --region "$REGION" >/dev/null 2>&1; then
  aws rds create-db-instance \
    --db-instance-identifier "${DB_CLUSTER_ID}-instance-1" \
    --db-instance-class db.serverless \
    --engine aurora-postgresql \
    --db-cluster-identifier "$DB_CLUSTER_ID" \
    --region "$REGION"
fi
aws rds wait db-instance-available --db-instance-identifier "${DB_CLUSTER_ID}-instance-1" --region "$REGION"
DB_HOST=$(aws rds describe-db-clusters --db-cluster-identifier "$DB_CLUSTER_ID" --region "$REGION" --query 'DBClusters[0].Endpoint' --output text)

while ! aws rds-data execute-statement --resource-arn "$DB_ARN" --secret-arn "$SECRET_ARN" \
  --sql "SELECT 1" --database postgres --region "$REGION" >/dev/null 2>&1; do
  echo "Waiting for PostgreSQL to accept connections via Data API..."
  sleep 5
done

if ! aws rds-data execute-statement --resource-arn "$DB_ARN" --secret-arn "$SECRET_ARN" \
  --sql "SELECT 1 FROM pg_database WHERE datname='$DB_NAME';" --database postgres --region "$REGION" \
  --query 'records[0][0].longValue' --output text 2>/dev/null | grep -q 1; then
  aws rds-data execute-statement --resource-arn "$DB_ARN" --secret-arn "$SECRET_ARN" \
    --sql "CREATE DATABASE \"$DB_NAME\";" --database postgres --region "$REGION"
fi

if ! aws rds-data execute-statement --resource-arn "$DB_ARN" --secret-arn "$SECRET_ARN" \
  --sql "SELECT 1 FROM pg_roles WHERE rolname='$NON_ROOT_USER';" --database postgres --region "$REGION" \
  --query 'records[0][0].longValue' --output text 2>/dev/null | grep -q 1; then
  aws rds-data execute-statement --resource-arn "$DB_ARN" --secret-arn "$SECRET_ARN" \
    --sql "CREATE USER \"$NON_ROOT_USER\" WITH PASSWORD '$NON_ROOT_PASS';" --database postgres --region "$REGION"
fi

aws rds-data execute-statement --resource-arn "$DB_ARN" --secret-arn "$SECRET_ARN" \
  --sql "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$NON_ROOT_USER\";" --database postgres --region "$REGION"

# Ensure the app user can create tables in the public schema
aws rds-data execute-statement --resource-arn "$DB_ARN" --secret-arn "$SECRET_ARN" \
  --sql "GRANT ALL PRIVILEGES ON SCHEMA public TO \"$NON_ROOT_USER\";" --database "$DB_NAME" --region "$REGION"

sed -e "s/REPLACE_ME_DB_HOST/$DB_HOST/" \
    -e "s/REPLACE_ME_N8N_HOST/$N8N_HOST/" \
    -e "s#REPLACE_ME_WEBHOOK_URL#$WEBHOOK_URL#" \
    n8n-deployment.yaml > n8n-deployment.generated.yaml
sed -e "s/REPLACE_ME_DB_HOST/$DB_HOST/" \
    -e "s/REPLACE_ME_N8N_HOST/$N8N_HOST/" \
    -e "s#REPLACE_ME_WEBHOOK_URL#$WEBHOOK_URL#" \
    n8n-worker-deployment.yaml > n8n-worker-deployment.generated.yaml

# Apply the EFS storage class
kubectl apply -f efs-storageclass.yaml

# Create PersistentVolumes bound to the new EFS file system
out="n8n-pv.generated.yaml"
sed "s/REPLACE_ME/$EFS_ID/" n8n-pv.yaml > "$out"
kubectl apply -f "$out"

# Deploy n8n resources
kubectl apply -f namespace.yaml
ENCRYPTION_KEY=$(openssl rand -hex 32)
# Default basic auth variables disable authentication unless explicitly set
N8N_BASIC_AUTH_ACTIVE="${N8N_BASIC_AUTH_ACTIVE:-false}"
N8N_BASIC_AUTH_USER="${N8N_BASIC_AUTH_USER:-}"
N8N_BASIC_AUTH_PASSWORD="${N8N_BASIC_AUTH_PASSWORD:-}"

kubectl create secret generic n8n-secret \
  --from-literal=N8N_ENCRYPTION_KEY="$ENCRYPTION_KEY" \
  --from-literal=N8N_BASIC_AUTH_ACTIVE="$N8N_BASIC_AUTH_ACTIVE" \
  --from-literal=N8N_BASIC_AUTH_USER="$N8N_BASIC_AUTH_USER" \
  --from-literal=N8N_BASIC_AUTH_PASSWORD="$N8N_BASIC_AUTH_PASSWORD" \
  -n n8n --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f postgres-secret.yaml
kubectl apply -f n8n-claim0-persistentvolumeclaim.yaml
kubectl apply -f n8n-deployment.generated.yaml
kubectl apply -f n8n-worker-deployment.generated.yaml
kubectl apply -f n8n-service.yaml
kubectl apply -f redis.yaml
kubectl apply -f n8n-hpa.yaml
ensure_vpa_crd
kubectl apply -f n8n-vpa.yaml
out="n8n-ingress.generated.yaml"
sed "s/REPLACE_ME_ALB_SG/$ALB_SG_ID/" n8n-ingress.yaml > "$out"
kubectl apply -f "$out"

# Create a CloudFront distribution in front of the ALB
LB_HOST=$(wait_for_alb)
create_cloudfront "$LB_HOST"

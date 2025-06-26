#!/usr/bin/env bash
# User-configurable variables
REGION="us-east-1"
CLUSTER_NAME="n8n"
EFS_ID_FILE="efs_id.txt"
# File storing the CloudFront distribution ID
CF_ID_FILE="cloudfront_id.txt"
# File storing region and cluster from deploy script
DEPLOY_INFO_FILE="deploy_info.env"


usage() {
  echo "Usage: $0 [--region REGION] [--k8sname NAME]" >&2
  exit 1
}

# Parse optional arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --region)
      REGION="$2"
      region_set=1
      shift 2
      ;;
    --k8sname)
      CLUSTER_NAME="$2"
      cluster_set=1
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

# Load region and cluster from deployment info if not provided
if [ -f "$DEPLOY_INFO_FILE" ]; then
  file_region=$(grep '^REGION=' "$DEPLOY_INFO_FILE" | cut -d= -f2- | tr -d '"')
  file_cluster=$(grep '^CLUSTER_NAME=' "$DEPLOY_INFO_FILE" | cut -d= -f2- | tr -d '"')
  if [ -z "${region_set:-}" ] && [ -n "$file_region" ]; then
    REGION="$file_region"
  fi
  if [ -z "${cluster_set:-}" ] && [ -n "$file_cluster" ]; then
    CLUSTER_NAME="$file_cluster"
  fi
fi

DB_CLUSTER_ID="${CLUSTER_NAME}-aurora"
DB_SUBNET_GROUP="${CLUSTER_NAME}-aurora-subnet-group"
DB_SG_NAME="${CLUSTER_NAME}-aurora-sg"
SECRET_NAME="${DB_CLUSTER_ID}-master-secret"

set -euo pipefail

# Disable AWS CLI pager for non-interactive execution
export AWS_PAGER=""

# Ensure required tools are available before continuing
missing=()
for cmd in aws eksctl kubectl jq; do
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

# Verify required IAM permissions before continuing
REQUIRED_ACTIONS=(
  "elasticfilesystem:DeleteFileSystem"
  "elasticfilesystem:DeleteMountTarget"
  "elasticfilesystem:DescribeFileSystems"
  "elasticfilesystem:DescribeMountTargets"
  "elasticloadbalancing:DescribeLoadBalancers"
  "rds:DeleteDBCluster"
  "rds:DeleteDBInstance"
  "rds:DeleteDBSubnetGroup"
  "secretsmanager:DeleteSecret"
  "secretsmanager:ListSecrets"
  "ec2:DeleteSecurityGroup"
  "ec2:DescribeSecurityGroups"
  "ec2:DescribeVpcs"
  "ec2:DescribeSubnets"
  "ec2:DeleteVpc"
  "ec2:DeleteSubnet"
  "ec2:DescribeNetworkInterfaces"
  "iam:SimulatePrincipalPolicy"
  "cloudfront:ListDistributions"
  "cloudfront:GetDistribution"
  "cloudfront:GetDistributionConfig"
  "cloudfront:UpdateDistribution"
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

delete_cloudfront() {
  local id etag
  id="${CF_ID:-}"
  if [ -z "$id" ] && [ -f "$CF_ID_FILE" ]; then
    id=$(cat "$CF_ID_FILE")
  fi
  if [ -z "$id" ] || [ "$id" = "None" ]; then
    id=$(aws cloudfront list-distributions \
      --query "DistributionList.Items[?Origins.Items[0].DomainName=='${LB_HOST}'].Id" \
      --output text 2>/dev/null || true)
  fi
  if [ -z "$id" ] || [ "$id" = "None" ]; then
    echo "CloudFront distribution ID not found." >&2
    return
  fi
  echo "Disabling CloudFront distribution $id..."
  etag=$(aws cloudfront get-distribution-config --id "$id" --query 'ETag' --output text)
  aws cloudfront get-distribution-config --id "$id" --query 'DistributionConfig' --output json |
    jq '.Enabled=false' > cfg.json
  aws cloudfront update-distribution --id "$id" --if-match "$etag" --distribution-config file://cfg.json >/dev/null
  aws cloudfront wait distribution-deployed --id "$id"
  etag=$(aws cloudfront get-distribution-config --id "$id" --query 'ETag' --output text)
  aws cloudfront delete-distribution --id "$id" --if-match "$etag" >/dev/null
  rm -f cfg.json "$CF_ID_FILE"
}

delete_vpa_crd() {
  if kubectl get crd verticalpodautoscalers.autoscaling.k8s.io >/dev/null 2>&1; then
    kubectl delete -f https://raw.githubusercontent.com/kubernetes/autoscaler/vpa-release-1.0/vertical-pod-autoscaler/deploy/vpa-rbac.yaml >/dev/null 2>&1 || true
    kubectl delete -f https://raw.githubusercontent.com/kubernetes/autoscaler/vpa-release-1.0/vertical-pod-autoscaler/deploy/vpa-v1-crd-gen.yaml >/dev/null 2>&1 || true
  fi
}


check_permissions

# Record the cluster VPC ID before deletion
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "")

EFS_ID="${EFS_ID:-}"
if [ -z "$EFS_ID" ]; then
  if [ -f efs_id.txt ]; then
    EFS_ID=$(cat efs_id.txt)
  elif [ -f n8n-pv.generated.yaml ]; then
    EFS_ID=$(grep volumeHandle n8n-pv.generated.yaml | awk '{print $2}')
  else
    EFS_ID=$(aws efs describe-file-systems --region "$REGION" \
      --query "FileSystems[?Name=='${CLUSTER_NAME}-efs'].FileSystemId" --output text 2>/dev/null || true)
  fi
fi

echo "Deleting EFS resources..."
if [ -n "$EFS_ID" ]; then
  echo "Deleting EFS mount targets for $EFS_ID"
  TARGETS=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" --region "$REGION" --query 'MountTargets[*].MountTargetId' --output text || true)
  for mt in $TARGETS; do
    aws efs delete-mount-target --mount-target-id "$mt" --region "$REGION" || true
  done
  echo "Waiting for EFS mount targets to be deleted..."
  while true; do
    REMAINING=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" --region "$REGION" --query 'MountTargets' --output text || true)
    if [ -z "$REMAINING" ] || [ "$REMAINING" = "None" ]; then
      break
    fi
    sleep 5
  done
  echo "Deleting EFS filesystem $EFS_ID"
  aws efs delete-file-system --file-system-id "$EFS_ID" --region "$REGION" || true
else
  echo "EFS_ID not found. You may need to delete the EFS filesystem manually." >&2
fi

echo "Deleting ALB resources..."
# Capture the load balancer hostname before deleting the ingress
LB_HOST=$(kubectl get ingress n8n -n n8n -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
kubectl delete -f n8n-ingress.yaml --ignore-not-found
kubectl delete -f n8n-hpa.yaml --ignore-not-found
if kubectl get crd verticalpodautoscalers.autoscaling.k8s.io >/dev/null 2>&1; then
  kubectl delete -f n8n-vpa.yaml --ignore-not-found
else
  echo "VPA CRD not found. Skipping VPA resource deletion." >&2
fi
delete_vpa_crd
kubectl delete -f n8n-worker-deployment.generated.yaml --ignore-not-found
kubectl delete -f redis.yaml --ignore-not-found
if [ -n "$LB_HOST" ]; then
  echo "Waiting for load balancer $LB_HOST to be deleted..."
  while aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?DNSName=='${LB_HOST}'].[DNSName]" --output text | grep -q "$LB_HOST"; do
    sleep 10
  done
fi

ALB_SG_NAME="${CLUSTER_NAME}-alb-sg"
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$ALB_SG_NAME" \
  --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
if [ -n "$ALB_SG_ID" ] && [ "$ALB_SG_ID" != "None" ]; then
  echo "Waiting for network interfaces using $ALB_SG_ID to be detached..."
  while aws ec2 describe-network-interfaces \
    --filters Name=group-id,Values="$ALB_SG_ID" \
    --region "$REGION" --query 'NetworkInterfaces' --output text | grep -q .; do
    sleep 5
  done
  aws ec2 delete-security-group --group-id "$ALB_SG_ID" --region "$REGION" || true
fi

delete_cloudfront

echo "Deleting RDS cluster..."
if aws rds describe-db-instances --db-instance-identifier "${DB_CLUSTER_ID}-instance-1" --region "$REGION" >/dev/null 2>&1; then
  aws rds delete-db-instance --db-instance-identifier "${DB_CLUSTER_ID}-instance-1" --region "$REGION" --skip-final-snapshot || true
  aws rds wait db-instance-deleted --db-instance-identifier "${DB_CLUSTER_ID}-instance-1" --region "$REGION" || true
fi
if aws rds describe-db-clusters --db-cluster-identifier "$DB_CLUSTER_ID" --region "$REGION" >/dev/null 2>&1; then
  aws rds delete-db-cluster --db-cluster-identifier "$DB_CLUSTER_ID" --region "$REGION" --skip-final-snapshot || true
  aws rds wait db-cluster-deleted --db-cluster-identifier "$DB_CLUSTER_ID" --region "$REGION" || true
fi
aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" --region "$REGION" 2>/dev/null || true
DB_SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$DB_SG_NAME" --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
if [ -n "$DB_SG_ID" ] && [ "$DB_SG_ID" != "None" ]; then
  aws ec2 delete-security-group --group-id "$DB_SG_ID" --region "$REGION" || true
fi
SECRET_ARN=$(aws secretsmanager list-secrets --filters "Key=name,Values=$SECRET_NAME" \
  --query 'SecretList[0].ARN' --output text 2>/dev/null || echo "")
if [ -n "$SECRET_ARN" ] && [ "$SECRET_ARN" != "None" ]; then
  aws secretsmanager delete-secret --secret-id "$SECRET_NAME" --region "$REGION" \
    --force-delete-without-recovery || true
fi

echo "Deleting EKS cluster..."
eksctl delete cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION"

# Ensure the VPC created for the cluster is deleted
if [ -n "$VPC_ID" ] && aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" >/dev/null 2>&1; then
  subnets=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" \
    --region "$REGION" --query 'Subnets[].SubnetId' --output text)
  for subnet in $subnets; do
    if [ -z "$subnet" ] || [ "$subnet" = "None" ]; then
      continue
    fi
    in_use=$(aws ec2 describe-network-interfaces \
      --filters Name=subnet-id,Values="$subnet" \
      --region "$REGION" --query 'NetworkInterfaces' --output text)
    if [ -z "$in_use" ] || [ "$in_use" = "None" ]; then
      aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION" || true
    else
      echo "Subnet $subnet still in use and could not be deleted automatically" >&2
    fi
  done
  remaining=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" \
    --region "$REGION" --query 'Subnets' --output text)
  if [ -z "$remaining" ] || [ "$remaining" = "None" ]; then
    aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" || true
  else
    echo "VPC $VPC_ID still contains subnets and could not be deleted automatically" >&2
  fi
fi

rm -f efs-storageclass.generated.yaml n8n-pv.generated.yaml n8n-deployment.generated.yaml n8n-worker-deployment.generated.yaml n8n-ingress.generated.yaml "$EFS_ID_FILE"
rm -f "$CF_ID_FILE"

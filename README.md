# n8n on AWS EKS Fargate

> **Note:** This repository is **only for deploying n8n on AWS EKS Fargate**. All manifests, automation scripts, and configurations are AWS cloud-native and **do not work on other Kubernetes environments or public clouds**.

---

## About

This solution deploys [n8n](https://n8n.io/) (an open-source workflow automation platform) on serverless Kubernetes (EKS Fargate) with **full AWS-native services**:

- **EKS Fargate** (serverless Kubernetes compute)
- **Amazon EFS** (shared, persistent PVC for n8n state and files)
- **Amazon Aurora PostgreSQL Serverless v2** (scaling DB backend)
- **Amazon Elasticache (Redis)** (for n8n queue mode; see below)
- **Application Load Balancer (ALB) & Ingress**
- **Amazon CloudFront** (secure, global edge access)
- **AWS IAM** (auto IAM policy management)
- **AWS Secrets Manager** (stores DB/master credentials securely)
- **AWS CloudWatch** (logs from all pods)

All services are provisioned and destroyed with the provided scripts, and n8n runs in **queue mode**: main and worker pods scale dynamically, connected via Redis.

---

## Origin and License

This project includes code derived from the n8n-hosting repository:  
[https://github.com/n8n-io/n8n-hosting/tree/main/kubernetes](https://github.com/n8n-io/n8n-hosting/tree/main/kubernetes)

Released under the MIT License (see `LICENSE`).

---

## Features

- **AWS-Only:** All deployments, resources, IAM policies, and security groups are AWS-specific.
- **Automated lifecycle:** One-step deploy and destroy for your cloud-native n8n stack.
- **Queue Mode Enabled:** n8n runs in queue mode by default; workers scale via HPA, Redis included.
- **Security best practices:** Secrets/credentials stored in Kubernetes Secrets and AWS Secrets Manager.
- **Persistent & Highly Available:** All n8n data is on AWS EFS, supporting parallel scaling and stateless bridges.
- **All pod logs go to CloudWatch Logs.**
- **Ingress traffic is only allowed via CloudFront.**

---

## Prerequisites & Tooling

Install and configure on your system:

- AWS CLI
- eksctl
- kubectl
- helm
- curl
- openssl  (for generating encryption keys)
- jq       (required for resource cleanup scripts)

You must provide AWS credentials and have the correct IAM permissions (see below).

---

## Required IAM Permissions

The deployment (**deploy-eks-fargate.sh**) and destroy (**destroy-eks-fargate.sh**) scripts **explicitly check** for these IAM permissions and will refuse to run if any are missing.

### For Deployment

- `elasticfilesystem:CreateFileSystem`
- `elasticfilesystem:CreateMountTarget`
- `ec2:DescribeSubnets`
- `ec2:CreateSecurityGroup`
- `ec2:ModifyVpcAttribute`
- `ec2:AuthorizeSecurityGroupIngress`
- `ec2:DescribeSecurityGroups`
- `ec2:DescribeManagedPrefixLists`
- `rds:CreateDBCluster`
- `rds:CreateDBInstance`
- `rds:CreateDBSubnetGroup`
- `secretsmanager:CreateSecret`
- `secretsmanager:UpdateSecret`
- `secretsmanager:DescribeSecret`
- `secretsmanager:ListSecrets`
- `secretsmanager:GetSecretValue`
- `rds-data:ExecuteStatement`
- `iam:CreatePolicy`
- `iam:GetPolicy`
- `iam:GetPolicyVersion`
- `iam:ListPolicyVersions`
- `iam:DeletePolicyVersion`
- `iam:CreatePolicyVersion`
- `iam:SimulatePrincipalPolicy`
- `cloudfront:CreateDistribution`
- `cloudfront:GetDistribution`
- `cloudfront:GetDistributionConfig`
- `cloudfront:UpdateDistribution`
- `cloudfront:ListCachePolicies`
- `cloudfront:DeleteDistribution`

### For Destroy

- `elasticfilesystem:DeleteFileSystem`
- `elasticfilesystem:DeleteMountTarget`
- `elasticfilesystem:DescribeFileSystems`
- `elasticfilesystem:DescribeMountTargets`
- `elasticloadbalancing:DescribeLoadBalancers`
- `rds:DeleteDBCluster`
- `rds:DeleteDBInstance`
- `rds:DeleteDBSubnetGroup`
- `secretsmanager:DeleteSecret`
- `secretsmanager:ListSecrets`
- `ec2:DeleteSecurityGroup`
- `ec2:DescribeSecurityGroups`
- `iam:SimulatePrincipalPolicy`
- `cloudfront:ListDistributions`
- `cloudfront:GetDistribution`
- `cloudfront:GetDistributionConfig`
- `cloudfront:UpdateDistribution`
- `cloudfront:DeleteDistribution`

If any required permission is missing, the script will abort and print a list of missing actions.

---

## Quickstart

### 1. Optional: Set Environment Variables

Before deploying, you may export these variables to override defaults:

- `AURORA_MIN_CAPACITY` / `AURORA_MAX_CAPACITY`  
- `N8N_BASIC_AUTH_ACTIVE`, `N8N_BASIC_AUTH_USER`, `N8N_BASIC_AUTH_PASSWORD`
- `N8N_HOST`
- Edit the database credentials in `postgres-secret.yaml`.

### 2. Deploy

```bash
./deploy-eks-fargate.sh --region <aws-region> --k8sname <cluster-name> --domain <n8n-domain>
# All arguments are optional and have defaults.
```

On completion, the script prints a CloudFront endpoint for public access.

### 3. Access n8n

- Use the provided CloudFront DNS (HTTPS enforced, modern TLS).
- Data persists to EFS; all logs go to CloudWatch.
- Automatic scaling for worker deployments via HPA.
- All sensitive values are stored securely.

---

## Cleaning Up

To destroy **all provisioned AWS resources** (EKS, Aurora, EFS, CloudFront, ALB, Secrets, Security Groups, etc):

```bash
./destroy-eks-fargate.sh
```

This uses state files generated on deployment (`efs_id.txt`, `cloudfront_id.txt`, `deploy_info.env`).

---

## Notes

- **Kubernetes Secrets and DB credentials:** Handled automatically, but you can customize before initial deploy.
- **Redis deployment:** Included as a Deployment and Service in `redis.yaml`.
- **kustomize** is required (`kubectl apply -k`). Install via official script or Homebrew.
- **Troubleshooting:** If permissions or resource creation fails, scripts will stop and print diagnostics. See their "Troubleshooting" sections.

---

## File Structure

- `deploy-eks-fargate.sh`: Main deployment script
- `destroy-eks-fargate.sh`: Complete stack clean-up script
- `eks-fargate-cluster.yaml`: EKS cluster configuration
- `cloudwatch-logging.yaml`: CloudWatch log configuration
- `n8n-deployment.yaml`, `n8n-worker-deployment.yaml`: n8n and queue worker deployments
- `redis.yaml`: Redis deployment and Service
- `efs-storageclass.yaml`, `n8n-pv.yaml`, `n8n-claim0-persistentvolumeclaim.yaml`: EFS persistent volumes
- All other manifests and scripts are AWS-specific.

---

## Caveats

- This solution is **only** maintained and supported for AWS EKS Fargate.
- Do **not** attempt to run on Azure, GCP, or any other Kubernetes environment.
- All infrastructure and data are managed at your own risk.

---

## More Information

- Questions/discussion: [n8n Community Forums](https://community.n8n.io/)
- Upstream origin: [n8n-hosting/kubernetes](https://github.com/n8n-io/n8n-hosting/tree/main/kubernetes)

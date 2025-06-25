# n8n on AWS EKS Fargate

> **Note:** This repository is **only for deploying n8n on AWS EKS Fargate**. All manifests and scripts are AWS specific and will not work on other Kubernetes environments or cloud providers.

## Overview

This project contains automation scripts and Kubernetes manifests to run [n8n](https://n8n.io/) on serverless EKS Fargate. It relies on AWS managed services such as EFS, Aurora PostgreSQL, and CloudFront. n8n runs in queue mode with scaling worker pods, and all logs stream to CloudWatch.

## Prerequisites

Install and configure the following tools and ensure your AWS credentials are available:

- AWS CLI
- eksctl
- kubectl
- helm
- curl
- openssl (for generating encryption keys)
- jq (required by the cleanup script)
- kustomize (used with `kubectl apply -k`)

### Required IAM permissions

`deploy-eks-fargate.sh` and `destroy-eks-fargate.sh` check that your user or role has these permissions before running.

#### For deployment
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

#### For destroy
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

If a permission is missing, the script prints which actions are required and exits.

## Quickstart

1. **Optionally configure environment variables**
   
   - `AURORA_MIN_CAPACITY` / `AURORA_MAX_CAPACITY`
   - `N8N_BASIC_AUTH_ACTIVE`, `N8N_BASIC_AUTH_USER`, `N8N_BASIC_AUTH_PASSWORD`
   - `N8N_HOST`
   - Update credentials in `postgres-secret.yaml` if needed

2. **Deploy**
   ```bash
   ./deploy-eks-fargate.sh --region <aws-region> --k8sname <cluster-name> --domain <n8n-domain>
   ```
   The arguments are optional and have sensible defaults. When complete, the script prints the CloudFront URL to access n8n. Run `./deploy-eks-fargate.sh --help` for all options.

3. **Access n8n**
   
   - Use the CloudFront DNS name (HTTPS enforced)
   - Data persists on EFS and logs stream to CloudWatch
   - Worker pods scale via HPA

4. **Clean up**
   ```bash
   ./destroy-eks-fargate.sh
   ```
   This removes all resources using state files from the deployment.

## Architecture

This solution deploys [n8n](https://n8n.io/), an open source workflow automation platform, on serverless Kubernetes (EKS Fargate) using AWS managed services. n8n runs in queue mode with worker pods connected through Redis, and all logs stream to CloudWatch.

## Features

- **AWS only** – all resources, IAM policies and security groups are AWS specific
- **Automated lifecycle** – single commands to deploy and destroy the entire stack
- **Queue mode enabled** – workers scale automatically via HPA
- **Security best practices** – secrets stored in Kubernetes Secrets and AWS Secrets Manager
- **Persistent and highly available** – data stored on EFS for horizontal scaling
- **Ingress via CloudFront** – public access is served through CloudFront

## Repository structure

- `deploy-eks-fargate.sh` – deployment script
- `destroy-eks-fargate.sh` – teardown script
- `eks-fargate-cluster.yaml` – EKS cluster configuration
- `cloudwatch-logging.yaml` – CloudWatch logging configuration
- `n8n-deployment.yaml`, `n8n-worker-deployment.yaml` – n8n and worker deployments
- `redis.yaml` – Redis deployment
- `efs-storageclass.yaml`, `n8n-pv.yaml`, `n8n-claim0-persistentvolumeclaim.yaml` – EFS volumes
- Other manifests and scripts are AWS specific

## Notes

- Kubernetes Secrets and database credentials are generated automatically but can be customised before deploying
- Troubleshooting steps are documented in the scripts if resource creation fails

## Caveats

- Supported only on AWS EKS Fargate
- Do not attempt to use these manifests on other Kubernetes environments
- Manage infrastructure at your own risk

## Origin and license

Parts of this repository come from [n8n-hosting](https://github.com/n8n-io/n8n-hosting/tree/main/kubernetes). This project is released under the MIT License (see `LICENSE`).

## More information

- Ask questions on the [n8n Community Forums](https://community.n8n.io/)

- Upstream origin: [n8n-hosting/kubernetes](https://github.com/n8n-io/n8n-hosting/tree/main/kubernetes)

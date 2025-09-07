canary_rollout :

Multi-target canary rollout on AWS (London `eu-west-2`) for **Podinfo** to **Lambda (API Gateway)** and **EC2 behind ALB** with **CodeDeploy blue/green**, **canary shift**, **auto-rollback**, **signed images**, **SBOM**, **OIDC (no static creds)**, **Secrets Manager rotation**, and **CloudWatch observability**.

> Region: **eu-west-2 (London)**  
> EC2 size: **t2.micro**  
> Randomized resource name markers are used where values were unspecified (commented in code as `# this field indicates this`).

Quick Start :

 0) Prereqs
- AWS account with admin or appropriate permissions in **eu-west-2**.
- Terraform >= 1.5
- Docker
- GitHub repo named **canary_rollout** (or update workflow env).  
- Configure GitHub Environments `dev` and `prod` with required reviewers for manual approval to prod.

1) Bootstrap Global Infra
```bash
cd infra/global
terraform init
terraform apply -auto-approve
```
Outputs include ECR repo URL, OIDC role ARN for GitHub, SNS topic, CloudWatch dashboard, and the Secrets Manager secret ARN.

 2) Deploy Lambda & EC2 Stacks
```bash
cd ../lambda
terraform init
terraform apply -auto-approve

cd ../ec2
terraform init
terraform apply -auto-approve
```
Outputs provide API Gateway URL and ALB DNS name.

3) Configure GitHub OIDC & Repo Secrets
- In GitHub, set `AWS_ROLE_TO_ASSUME` to the output OIDC role ARN.
- Ensure workflows have `id-token: write` permission (already configured). No static keys required.

4) Build & Push (CI)
Push to `main` to trigger `.github/workflows/build.yml`. It will:
- Build Podinfo container (multi-stage Dockerfile),
- Push to ECR,
- Generate **SBOM** (Syft),
- **Sign** image (Cosign keyless/OIDC).

Artifacts include the image digest and SBOM.

5) Deploy to Dev, then Approve to Prod
A successful build triggers `.github/workflows/deploy.yml`:
- Deploys the **same image digest** to **Lambda (API GW)** and **EC2 (ALB)** in **dev** via CodeDeploy **canary 10% → 100%** with **alarms for rollback**.
- Runs smoke tests on both front doors.
- Waits for **manual approval** to promote to **prod**.  
- Repeats the process for prod with the same digest.

6) Verify
- Visit **API Gateway URL** and **ALB DNS** from Terraform outputs.
- See **CloudWatch Dashboard** `cw-dashboard-zhbj86yg` for metrics.
- Try `curl $ALB/healthz` and `curl $API/healthz`.

7) Secret Rotation
- A secret exists at **/dockyard/SUPER_SECRET_TOKEN**.
- Rotation via Lambda is enabled. Trigger a rotation:
```bash
aws secretsmanager rotate-secret --secret-id /dockyard/SUPER_SECRET_TOKEN --region eu-west-2
```
- App processes keep working; value is fetched on demand. Logs are **redacted** using CloudWatch Logs data protection.

8) Teardown
```bash
./scripts/teardown.sh
```
Follows safe order to destroy stacks.

Design/Decisions
- Canary: **10% for 5m** then 100% (fast detection with minimal blast radius).
- Rollback: CloudWatch alarms on 5xx/error-rate trigger **automatic rollback** in CodeDeploy.
- Supply chain: OIDC, **cosign** signatures, **syft** SBOM, digest-only promotion.
- Scaling improvement implemented: **EC2 TargetTrackingPolicy** on ALB **RequestCountPerTarget** with safe drain/surge.
- Multi-region plan: Route53 weighted/latency routing, ECR replication, per-account isolation (see `SCALING.md`).

For all micro steps, see inline comments (`# this field indicates this`) and `ENVIRONMENT.md` for exact names/ARNs.

# Health Check API

A serverless `/health` endpoint on AWS: API Gateway → Lambda → DynamoDB, all
defined in Terraform, deployed by GitHub Actions to two independent
environments, with production behind a manual approval gate.

```
                    ┌─────────────────────────────────────────────────────────┐
                    │  <env>-health-check-api  (API Gateway REST API)         │
  client ──────────▶│  GET|POST /health                                       │
                    │  • JSON-schema request validator: "payload" required    │
                    │  • stage + method throttling  (rate / burst)            │
                    │  • access logs → CloudWatch (KMS-encrypted)             │
                    └───────────────────────────┬─────────────────────────────┘
                                                │ AWS_PROXY → alias "live"
                    ┌───────────────────────────▼─────────────────────────────┐
                    │  <env>-vpc  (private subnets, no internet route)        │
                    │  ┌───────────────────────────────────────────────────┐  │
                    │  │ <env>-health-check-function  (Python 3.12, arm64)  │ │
                    │  │  1. log the event to CloudWatch                    │ │
                    │  │  2. re-validate "payload"                          │ │
                    │  │  3. put item with a fresh UUID                     │ │
                    │  │  4. 200 {"status":"healthy", ...}                  │ │
                    │  └──────────────────────┬────────────────────────────┘  │
                    │        egress-only SG   │ DynamoDB prefix list only     │
                    │  ┌──────────────────────▼────────────────────────────┐  │
                    │  │ DynamoDB Gateway VPC endpoint (free, policy-scoped)│ │
                    │  └──────────────────────┬────────────────────────────┘  │
                    └─────────────────────────┼───────────────────────────────┘
                                              ▼
                              <env>-requests-db  (SSE with a customer-managed
                                                  KMS key, TTL, PITR in prod)
```

---

## Repository layout

```
.
├── .github/workflows/
│   ├── ci.yml              PR checks: tests, dependency scan, IaC scan, plan
│   └── deploy.yml          main: quality → security → staging → [approval] → prod
├── shared/                 run ONCE per account: state backend, CI user, deploy roles
├── scripts/smoke-test.sh   post-deploy contract check
├── src/lambda/handler.py   the function
├── tests/test_handler.py   unit tests (moto, no AWS account needed)
└── terraform/
    ├── backend.tf          partial S3 backend
    ├── main.tf             wires the modules together
    ├── variables.tf outputs.tf locals.tf providers.tf versions.tf
    ├── env/
    │   ├── staging.tfvars  prod.tfvars              ← the -var-file inputs
    │   └── staging.backend.hcl  prod.backend.hcl    ← the -backend-config inputs
    └── modules/
        ├── network/        VPC, private subnets, SG, DynamoDB endpoint, flow logs
        ├── dynamodb/       the table + SSE
        ├── lambda/         packaging, versioning, alias, execution role
        ├── api_gateway/    REST API, validators, throttling, stage, logs
        └── deploy_iam/     the CI/CD deployment role
```

---

### Tooling

| Tool | Version | Why |
| --- | --- | --- |
| Terraform | ≥ 1.6, < 2.0 | `required_version` in `terraform/versions.tf` |
| AWS CLI | v2 | shared and manual verification |
| Python | 3.12 | matches the Lambda runtime |
| An AWS account | — | with admin access for the one-time shared resources. Organizations and multiple aws accounts for environments are not supported as it is outside of free tier acc |

### One-time shared resources

Nothing in `terraform/` will work until the account-level resources exist. See
[`shared/README.md`](shared/README.md). In short:

```bash
cd shared
terraform init
terraform apply -var="deploy_role_external_id=$(openssl rand -hex 16)"
```

That creates the Terraform state bucket and lock table, the CI IAM user and its
access key, one deployment role per environment, and the account-wide API
Gateway CloudWatch role.

### GitHub repository secrets

Settings → Secrets and variables → Actions → **Secrets**:

| Secret | Where it comes from | Used by |
| --- | --- | --- |
| `AWS_ACCESS_KEY_ID` | `terraform output ci_access_key_id` | every AWS step |
| `AWS_SECRET_ACCESS_KEY` | `terraform output -raw ci_secret_access_key` | every AWS step |
| `AWS_DEPLOY_ROLE_ARN_STAGING` | `terraform output deploy_role_arns` | staging plan/apply |
| `AWS_DEPLOY_ROLE_ARN_PROD` | `terraform output deploy_role_arns` | prod plan/apply |
| `AWS_DEPLOY_EXTERNAL_ID` | the value you passed to shared | `sts:AssumeRole` |

### GitHub repository variables

Settings → Secrets and variables → Actions → **Variables**:

| Variable | Example |
| --- | --- |
| `AWS_REGION` | `eu-central-1` |

### GitHub environments

Settings → **Environments**. Both are referenced by name in the workflows.

| Environment | Configuration |
| --- | --- |
| `staging` | no protection rules — deploys automatically |
| `production` | **Required reviewers**: at least one person. This *is* the manual approval gate. Optionally also restrict to the `main` branch. |

### Fill in the backend config

Replace `<ACCOUNT_ID>` in `terraform/env/staging.backend.hcl` and
`terraform/env/prod.backend.hcl` with your account number, or generate them:

```bash
cd shared
terraform output -raw backend_config_staging > ../terraform/env/staging.backend.hcl
terraform output -raw backend_config_prod    > ../terraform/env/prod.backend.hcl
```

---

## Deploying staging, step by step

### Through the pipeline (the normal path)

1. Branch off `main` and make your change.
2. Open a pull request. `ci.yml` runs: ruff, pytest, `pip-audit`, bandit,
   `terraform fmt/validate`, tflint, Checkov, Trivy, then a `terraform plan` against staging which it posts as a PR comment.
3. Get the PR reviewed and merge it into `main`.
4. `deploy.yml` starts automatically. The `quality` and `security` jobs run in
   parallel; when both pass, `deploy-staging` applies and then runs
   `scripts/smoke-test.sh` against the freshly deployed URL.
5. The staging endpoint appears in the run summary and on the `staging`
   environment card.

To deploy staging without touching production, run the workflow manually:
Actions → **Deploy** → *Run workflow* → untick **Continue to production**.

### Locally from laptop (for a first bring-up or a debug loop)

```bash
cd terraform

terraform init -backend-config=env/staging.backend.hcl

terraform plan  -var-file=env/staging.tfvars
terraform apply -var-file=env/staging.tfvars

terraform output health_endpoint
```

Add `-var="deploy_role_arn=arn:aws:iam::<ACCOUNT_ID>:role/staging-health-check-deploy-role"`
and `-var="deploy_role_external_id=<the id>"` to deploy through the same role
the pipeline uses, rather than with your own credentials.

Switching to production from the same working directory needs
`-reconfigure`, because the backend key changes:

```bash
terraform init -reconfigure -backend-config=env/prod.backend.hcl
terraform plan -var-file=env/prod.tfvars
```

---

## Testing the endpoint

`terraform output health_endpoint` prints the URL; it looks like
`https://a1b2c3d4e5.execute-api.eu-central-1.amazonaws.com/staging/health`.

**POST with a payload — the happy path:**

```bash
curl -sS -X POST \
  "https://a1b2c3d4e5.execute-api.eu-central-1.amazonaws.com/staging/health" \
  -H "Content-Type: application/json" \
  -d '{"payload": {"service": "checkout", "region": "eu-central-1"}}'
```

```json
{"status": "healthy", "message": "Request processed and saved.", "id": "0f8c...c41e"}
```

**GET — same contract, payload as a query-string parameter:**

```bash
curl -sS "https://a1b2c3d4e5.execute-api.eu-central-1.amazonaws.com/staging/health?payload=ping"
```

**Missing `payload` — rejected by API Gateway, 400, Lambda never invoked:**

```bash
curl -sS -i -X POST \
  "https://a1b2c3d4e5.execute-api.eu-central-1.amazonaws.com/staging/health" \
  -H "Content-Type: application/json" \
  -d '{"nope": true}'
```

```
HTTP/2 400
{"status":"error","message":"Request body must be a JSON object containing a 'payload' key."}
```

**Everything at once:**

```bash
./scripts/smoke-test.sh "$(terraform -chdir=terraform output -raw health_endpoint)"
```

**Confirm it was stored:**

```bash
aws dynamodb scan --table-name staging-requests-db --max-items 5
aws logs tail /aws/lambda/staging-health-check-function --since 5m
```

---

## How the CI/CD pipeline works

### `ci.yml` — on every pull request

| Job | What it does | Fails the PR when |
| --- | --- | --- |
| `lambda` | ruff, pytest, **`pip-audit`** on `src/lambda/requirements.txt`, bandit | a test fails, a dependency has a known CVE, or bandit finds a medium+ issue |
| `terraform` | `fmt -check`, `validate` (root and shared), tflint | formatting drift, invalid config, lint rule violation |
| `iac-security` | **Checkov** + **Trivy** config scan, results uploaded as SARIF to the Security tab | any HIGH/CRITICAL misconfiguration not explicitly justified in `.checkov.yml` |
| `plan` | `terraform plan` against **both** staging and prod (matrix), each posted as its own PR comment and rewritten in place on every push | plan errors in either environment |

`plan` needs secrets, so it is skipped on pull requests from forks rather than
failing.

### `deploy.yml` — on push to `main`

```
  ┌──────────┐   ┌──────────┐
  │ quality  │   │ security │      both must pass
  └────┬─────┘   └─────┬────┘
       └───────┬───────┘
        ┌──────▼───────┐
        │deploy-staging│  apply + smoke test
        └──────┬───────┘
        ┌──────▼───────────────────────┐
        │  ⏸  environment: production   │  ← job waits here for approver
        │     required reviewers        │
        └──────┬───────────────────────┘
        ┌──────▼───────┐
        │ deploy-prod  │  plan (shown in the summary) + apply + smoke test
        └──────────────┘
```

Key properties:

- **Security scanning runs before any `terraform apply`.** `deploy-staging`
  declares `needs: [quality, security]`, so a Checkov or Trivy failure stops
  the deploy rather than being reported after the fact.
- **The apply consumes the plan file that was just produced.** Each deploy job
  runs `plan -out=<env>.tfplan` and then applies that file, so what is applied
  is exactly what was planned. The production plan is rendered into the run
  summary before the apply step, giving the approver the diff to read.
- **The approval gate is a GitHub environment protection rule**, not a step in
  the workflow file. Someone who can edit `deploy.yml` still cannot approve
  their own production deploy, and the approval is recorded in the deployment
  history.
- **Staging is always deployed first.** Production can only be reached through
  a staging deploy that passed its smoke test.
- **The PR plan jobs carry no `environment:` key.** Attaching `production`
  there would put every pull request behind the approval gate, which trains
  reviewers to approve reflexively — the opposite of what the gate is for.
- `concurrency: deploy-main` with `cancel-in-progress: false` means two merges
  in quick succession queue rather than racing, and a run is never cancelled
  mid-apply.
- Lambda **packaging and versioning are automated**: `archive_file` zips
  `src/lambda`, the archive is stored at a content-addressed S3 key
  (`lambda/<function>/<sha256>.zip`) in a versioned, KMS-encrypted bucket,
  `publish = true` mints a numbered Lambda version, and the `live` alias moves
  onto it. `github.sha` is stamped on the function and the artifact, so a
  running function traces back to a commit — and a rollback is moving the alias
  back, not a redeploy.

### Rolling back

```bash
aws lambda update-alias \
  --function-name prod-health-check-function \
  --name live \
  --function-version <previous-version>
```

Then revert the commit so Terraform's state matches reality on the next apply.

---

## Security notes

| Requirement | How it is met |
| --- | --- |
| Encryption everywhere | One customer-managed KMS key per environment, with rotation enabled, used for the DynamoDB table, every CloudWatch log group, the Lambda environment variables and the S3 artifact bucket. Terraform state is separately KMS-encrypted. Both buckets deny non-TLS access. |
| DynamoDB SSE | `server_side_encryption { enabled = true, kms_key_arn = ... }`, with a `precondition` that fails the plan if no key ARN is supplied. |
| Invalid requests cannot reach Lambda | A JSON-schema model with `required: ["payload"]` plus an API Gateway request validator on POST, and a required `payload` query-string parameter on GET. Rejections are 400s generated by the gateway; the function is never invoked. The handler re-validates anyway, because a validator only applies when the request's `Content-Type` matches the model. |
| DDoS / throttling | Stage- and method-level rate and burst limits, an optional per-client usage plan in prod, and `reserved_concurrent_executions` on the function so a flood cannot consume account-wide Lambda concurrency. A CloudWatch alarm fires on sustained 4xx. |
| Lambda in its own VPC | A dedicated VPC per environment, private subnets only, no internet gateway, no NAT. The security group has **no ingress rules** and egress restricted to the DynamoDB prefix list. The default security group is explicitly emptied. VPC flow logs go to CloudWatch. |
| Input validation | `payload` required in the JSON body (POST) or query string (GET); body must be a JSON object; 8 KB size cap; 400 with a JSON error body otherwise. |
| AWS authentication via API key | GitHub Actions authenticates with an IAM access key whose user has exactly two permissions: `sts:AssumeRole` on the two deployment roles, and `sts:GetCallerIdentity`. Every deploy then runs under short-lived credentials from a region- and prefix-fenced role, additionally protected by an `ExternalId`. |
| Least privilege, no wildcards | See below. |
| Dependency scanning | `pip-audit --strict` against the Lambda's pinned requirements, plus bandit for the function's own code. |
| IaC security scanning | Checkov and Trivy, both before apply, both failing the build, with every suppression documented and justified in `.checkov.yml`. |

### The wildcards that remain, and why

The rule is "no `*` except where mandatory". Four remain, all deliberate:

1. **`ec2:DescribeNetworkInterfaces`** in the Lambda execution role. AWS does
   not support resource-level permissions for the EC2 `Describe*` family at
   all; `"*"` is the only accepted value. It is read-only. For comparison,
   AWS's own managed `AWSLambdaVPCAccessExecutionRole` uses `"*"` for all five
   ENI actions; here the other four are scoped to this VPC's subnets, security
   group and ENIs.
2. **`kms:CreateKey`** in the deployment role. The key does not exist when the
   call is authorised, so there is nothing to scope to. It is fenced by
   `aws:RequestedRegion`.
3. **Resource *paths* ending in `/*`** — `log-stream:*`, `network-interface/*`,
   `restapis/*`, the artifact bucket's `/*`. These are not "any resource": the
   account, region and parent resource are all pinned; only the
   service-generated child id is a pattern.
4. **Service-wide actions inside `Deny` statements** in the deployment role's
   guardrail policy (`ec2:*`, `lambda:*`, …, when `aws:RequestedRegion` is
   wrong). A `Deny` removes permission rather than granting it. Written as an
   allow-list it could never keep pace with new API actions, and every gap
   would be a deploy escaping the region fence.

Everything else is pinned to a specific ARN. The staging deployment role can
read and write only `staging/*` in the state bucket and can only touch
`staging-*` resources in one region; it physically cannot read production
state or modify production resources.

---

## Design choices and assumptions

**REST API rather than HTTP API.** HTTP APIs are cheaper ($1.00 vs $3.50 per
million requests) and simpler, but they have no request validators. The
requirement that invalid requests must not reach Lambda can only be met at the
gateway with a REST API. The extra ~$12.50/month at 5 M requests is the price
of that guarantee.

**`GET` takes `payload` as a query-string parameter.** The assignment states the
endpoint accepts GET or POST *and* that the JSON body must contain `payload`.
A GET with a body is not something API Gateway (or most HTTP intermediaries)
will reliably carry, so the contract is translated rather than dropped: POST
validates the body against a JSON-schema model, GET requires a `payload`
query-string parameter. Both are enforced at the gateway and re-checked in the
handler, and both produce the same 400 when absent.

**One root module + `-var-file`, not one directory per environment.** The task
asks explicitly for `terraform apply -var-file="staging.tfvars"`. A single root
module with `env/*.tfvars` and matching `env/*.backend.hcl` partial backend
configs delivers exactly that, keeps the two environments byte-identical apart
from their variables, and avoids the copy-paste drift that per-environment
directories accumulate. Workspaces are not being used: they share one backend
credential and one state bucket path, which would defeat the per-environment
IAM fencing above.

**A Gateway VPC endpoint, not a NAT Gateway.** The function only ever talks to
DynamoDB. A Gateway endpoint costs nothing, keeps the traffic off the public
internet entirely, and carries its own resource policy scoped to a single table
and two actions. A NAT Gateway would have added ~$38 per environment per month
for no benefit. If the function ever needs a third-party API, that is when a
NAT Gateway (or an interface endpoint) gets added.

**arm64.** Graviton is ~20 % cheaper per GB-second and the function has no
native dependencies.

**Content-addressed artifacts with a `live` alias.** The S3 key is the package's
SHA-256, so an identical build produces an identical key and no redeploy;
a changed build gets a new key, a new published version, and the alias moves.
That gives a real rollback path and an audit trail from a running function back
to a commit.

**No third-party Python dependencies.** The handler uses only the AWS SDK the
runtime already provides. `requirements.txt` still pins boto3/botocore so
`pip-audit` has something concrete to check and so tests run against the same
major version as the runtime, but nothing is vendored into the package.

**DynamoDB TTL on every item.** `expires_at` (7 days in staging, 90 in prod)
keeps storage bounded. TTL deletes are not billed as write units.

**No WAF.** A web ACL is ~$5/month plus per-rule and per-request charges. For
an unauthenticated health probe, gateway throttling plus a reserved-concurrency
cap is the proportionate mitigation. Adding a WAF is the documented next step
if this is ever exposed to hostile volume; the suppression in `.checkov.yml`
says so.

**The health endpoint is unauthenticated.** A liveness probe that requires
credentials is not much of a liveness probe. It is schema-validated, size-
capped and throttled, and it writes a bounded amount of data. Set
`authorization = "AWS_IAM"` in the `api_gateway` module to close it.

### Assumptions

- Both environments live in **one AWS account**, separated by resource-name
  prefix and by IAM. Separate accounts per environment would be better and the
  code supports it, point each environment's backend and deployment role at
  its own account, but that needs AWS Organizations, which is out of scope of Free tier.
- The stored request item is roughly 1 KB. Payloads are capped at 8 KB.
- The account-level API Gateway CloudWatch role is managed by `shared/` part. If
  something else in the account already owns it, apply shared resources with
  
  `-var="manage_apigateway_account_role=false"`.
- `shared/` keeps local state and contains the CI secret access key.
  `shared/README.md` covers the three ways to handle that.

---

## Local development

```bash
python -m pip install -r requirements-dev.txt

pytest                                   # unit tests, no AWS account needed
ruff check src tests                     # lint
bandit -r src/lambda -ll                 # Python SAST
pip-audit -r src/lambda/requirements.txt # dependency scan

terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
tflint --recursive
checkov -d . --config-file .checkov.yml
trivy config . --config trivy.yaml
```

## Tearing an environment down

```bash
cd terraform
terraform init -backend-config=env/staging.backend.hcl
terraform destroy -var-file=env/staging.tfvars
```

Production has `deletion_protection_enabled = true` on the table and
`force_destroy = false` on the artifact bucket, so a destroy there fails until
those are deliberately turned off. That is intentional.

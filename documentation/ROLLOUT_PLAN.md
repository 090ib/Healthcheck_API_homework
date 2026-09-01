# Rollout plan

How to get this project from a git repository to a running staging/production
endpoint, in 7 phases. Each phase ends with an explicit verification gate
and a rollback route, so a failure stops at a known point rather than halfway
through the next thing.

| Phase | What                                          |
| --- |-----------------------------------------------|
| 0 | Pre-flight checks                             |
| 1 | Account shared resources (once per AWS account) |
| 2 | Repository and pipeline wiring                |
| 3 | First staging deploy                          |
| 4 | Staging soak and validation                   |
| 5 | Production deploy                             |
| 6 | Day-two operations                            |


---

## Phase 0 — Pre-flight

Nothing here touches AWS. The point is to fail on your laptop rather than in a
pipeline run.

### 0.1 Confirm the toolchain

```bash
terraform version     # must satisfy >= 1.6.0, < 2.0.0
aws --version         # v2
python3 --version     # 3.12 to match the Lambda runtime
```

Your local Terraform must not be **older** than the `TF_VERSION` pinned in
`.github/workflows/*.yml` (currently `1.16.0`). Terraform upgrades the state
format on write and an older binary refuses to read a newer state file, so a CI
runner behind your workstation fails on the first pipeline deploy after a local
apply, with *"state snapshot was created by Terraform vX, which is newer than
current"*. If you upgrade locally, bump `TF_VERSION` in the same commit.

### 0.2 Run local pre-checks (optional)


```bash
python -m pip install -r requirements-dev.txt
pytest -q
ruff check src tests
bandit -r src/lambda -ll
pip-audit -r src/lambda/requirements.txt --strict

terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
terraform -chdir=shared init -backend=false
terraform -chdir=shared validate

tflint --recursive
checkov -d . --config-file .checkov.yml
trivy config . --config trivy.yaml
```

Fix anything that fails here. A provider-schema error found now costs minutes;
found in phase 3 it costs a debugging session with half a stack deployed.

### 0.3 Check account headroom

```bash
aws sts get-caller-identity                       # right account?
aws service-quotas get-service-quota \
  --service-code lambda --quota-code L-B99A9384   # concurrent executions
```

```bash
aws lambda get-account-settings --query 'AccountLimit.ConcurrentExecutions'
```

Reserving concurrency requires the account to keep a minimum pool of
*unreserved* executions — 100 on a standard account, but as low as 10 on a new
one. AWS names the floor in the error if you cross it.

**A new account often has a total Lambda concurrency limit of 10**, which means
it cannot reserve anything at all. `staging.tfvars` therefore ships with
`lambda_reserved_concurrency = -1`, and the account quota acts as the cap
instead — which is the same protection, just enforced one level up. On a
default 1 000-execution account, set staging back to `10` and leave prod at
`100`.

**Gate:** every command in 0.2 exits zero, and the four items in 0.3 have an
owner and an answer.

---

## Phase 1 — Account shared resources

Run **once per AWS account**, from a workstation with admin
credentials. This creates the things everything else assumes already exist:
the Terraform state backend, the CI identity, the deployment roles, and the
account-wide API Gateway CloudWatch role.

### 1.1 Apply

```bash
cd shared
terraform init

EXTERNAL_ID=$(openssl rand -hex 16)
echo "$EXTERNAL_ID"          # save this — you need it in phase 2

terraform plan  -var="deploy_role_external_id=$EXTERNAL_ID"
terraform apply -var="deploy_role_external_id=$EXTERNAL_ID"
```

**Before you apply, check `shared/terraform.tfvars`.** It ships pinned to
`environments = ["staging"]`, so that a shared/ re-run cannot create a
production role by accident. The full rollout will need both, so widen it first:

```hcl
environments = ["staging", "prod"]
```
for staging only rollout:
```hcl
environments = ["staging"]
```
Read the plan before approving. It should create roughly: one S3 bucket, one
DynamoDB table, one KMS key + alias, one IAM user + access key + policy, two
deployment roles with three inline policies each, and one API Gateway account
role.


NOTE: Terraform auto-loads `terraform.tfvars` from the working directory, so this
applies to **every** run in `shared/` without anyone passing a flag. That
matters more than it looks: shared/ gets re-applied occasionally, most often
to rotate the CI access key - and a run that forgot
`-var='environments=["staging"]'` would fall back to the variable's default and
create the production deployment role as a side effect of rotating a key.
Harmless, but surprising, and the sort of thing that surfaces in an access
review months later with nobody able to explain it. Keeping the intent in a
committed file rather than in someone's shell history closes that gap.

So the apply is just:

```bash
cd shared
terraform init

EXTERNAL_ID=$(openssl rand -hex 16)
echo "$EXTERNAL_ID"          # save this

terraform apply -var="deploy_role_external_id=$EXTERNAL_ID"
```
### 1.2 Capture the outputs

```bash
terraform output state_bucket
terraform output state_lock_table
terraform output deploy_role_arns
terraform output ci_access_key_id
terraform output -raw ci_secret_access_key      # handle carefully

terraform output -raw backend_config_staging > ../terraform/env/staging.backend.hcl
terraform output -raw backend_config_prod    > ../terraform/env/prod.backend.hcl
```

The last two commands replace the `<ACCOUNT_ID>` placeholders. Commit the
resulting backend files, they contain no secrets, only bucket and table
names.

### 1.3 Deal with the state file

`shared/terraform.tfstate` now contains the CI user's **secret access key in
cleartext**, and it is gitignored, so it exists only on the machine you ran it
from. Pick one before moving on:

- store it in a password manager or secure share, or
- re-apply with `-var="create_ci_access_key=false"` and create the key by hand
  with `aws iam create-access-key --user-name healthcheck-api-ci-user`, or
- migrate this stack into the bucket it just created:
  `terraform init -migrate-state -backend-config=...`

### 1.4 Verify

```bash
aws s3api get-bucket-versioning --bucket "$(terraform output -raw state_bucket)"
aws s3api get-public-access-block --bucket "$(terraform output -raw state_bucket)"
aws dynamodb describe-table --table-name "$(terraform output -raw state_lock_table)" \
  --query 'Table.TableStatus'
aws apigateway get-account --query 'cloudwatchRoleArn'
aws iam get-role --role-name staging-health-check-deploy-role --query 'Role.Arn'
aws iam get-role --role-name prod-health-check-deploy-role    --query 'Role.Arn'
```

**Gate:** versioning `Enabled`, public access fully blocked, lock table
`ACTIVE`, an API Gateway CloudWatch role ARN present, both deployment roles
exist.

**Rollback:** `terraform destroy` in `shared/`. Note that the state bucket
carries `prevent_destroy = true` and must be released deliberately, that
guard is intentional, since destroying it orphans every environment.

---

## Phase 2 - Repository and pipeline wiring

### 2.1 Push the code to manually created repo

Then, in Settings → Branches, protect `main`: require a pull request, require
the CI status checks to pass, and disallow direct pushes. Without this the
pipeline's gates are advisory.

### 2.2 Secrets

Settings → Secrets and variables → Actions → **Secrets**:

| Secret | Value                                                                  |
| --- |------------------------------------------------------------------------|
| `AWS_ACCESS_KEY_ID` | from `terraform output ci_access_key_id`                               |
| `AWS_SECRET_ACCESS_KEY` | from `terraform output -raw ci_secret_access_key`                      |
| `AWS_DEPLOY_ROLE_ARN_STAGING` | staging entry of `deploy_role_arns`                                    |
| `AWS_DEPLOY_ROLE_ARN_PROD` | prod entry of `deploy_role_arns`                                       |
| `AWS_DEPLOY_EXTERNAL_ID` | the `$EXTERNAL_ID` from 1.1                                            |
                                                         |
Create the **staging** environment only, with no protection rules. Protect
`main` as usual: require a pull request and require the CI checks to pass.

**Gate:** a throwaway pull request produces green checks and a staging plan
comment; the `Plan (prod)` leg is disabled for now.


### 2.3 Variables

Settings → Secrets and variables → Actions → **Variables**:

| Variable | Value |
| --- | --- |
| `DEPLOY_PROD` = `false` | Variable to switch off prod part from pipeline (budget based decision) |
| `AWS_REGION` | Variable
### 2.4 Environments

Settings → **Environments**:

- **`staging`** - create it now, no protection rules.
- **`production`** - create it once needed, add **Required reviewers** 
 and optionally restrict deployment to the `main` branch.

The required-reviewer rule *is* the manual approval gate.
### 2.5 Verify with a throwaway PR

Open a pull request that changes only a comment. It should run `lambda`,
`terraform`, `iac-security` and then two `plan` jobs, and post two comments,
one plan for staging, (one for prod). Both plans will show the full stack as
resources to create.

**Gate:** all CI jobs green, both plan comments present and showing sensible
creates. Close the PR without merging.

If the plan jobs fail on credentials, the usual causes are a wrong
`ExternalId`, a secret pasted with trailing whitespace, or `AWS_REGION` unset.

---

## Phase 3 - First staging deploy

For the very first apply, run it locally, You get interactive error messages
and can stop halfway; a pipeline run gives you a log after the fact. Every
subsequent deploy goes through the pipeline.

### 3.1 Apply as yourself

Run this with your own admin credentials - **do not pass `deploy_role_arn`**:

```bash
cd terraform
terraform init -backend-config=env/staging.backend.hcl

terraform plan  -var-file=env/staging.tfvars
terraform apply -var-file=env/staging.tfvars

bash ../scripts/smoke-test.sh "$(terraform output -raw health_endpoint)"
```

NOTE: The deployment role trusts only the CI user
(`trusted_principal_arns = [aws_iam_user.ci.arn]` in shared/). Your own IAM
user is not on that list, so passing `-var="deploy_role_arn=..."` here fails
with:

```
api error AccessDenied: User: arn:aws:iam::<ACCT>:user/<you> is not authorized
to perform: sts:AssumeRole on resource: .../staging-health-check-deploy-role
```

That is the role working correctly, not a misconfiguration. `sts:AssumeRole`
needs both the caller's identity policy *and* the role's trust policy to allow
it; an administrator satisfies the first and still fails the second. The role
exists so the pipeline's long-lived key carries almost no privilege - an
administrator has no reason to launder their own permissions through a role
that is deliberately *more* restricted than they are.


### 3.2 Verify

```bash
terraform output health_endpoint
bash ../scripts/smoke-test.sh "$(terraform output -raw health_endpoint)"
```

The smoke test checks all four contract cases: POST with payload → 200, POST
without → 400, GET with `?payload=` → 200, GET without → 400.

Then confirm the requirements that the smoke test cannot see:

```bash
# the request was actually stored
aws dynamodb scan --table-name staging-requests-db --max-items 5

# the event was logged
aws logs tail /aws/lambda/staging-health-check-function --since 10m

# encryption is on, with a customer-managed key
aws dynamodb describe-table --table-name staging-requests-db \
  --query 'Table.SSEDescription'

# the function is in the VPC with no public route
aws lambda get-function-configuration \
  --function-name staging-health-check-function --query 'VpcConfig'

# a version was published and the alias points at it
aws lambda list-versions-by-function \
  --function-name staging-health-check-function --query 'Versions[].Version'
aws lambda get-alias --function-name staging-health-check-function --name live
```

### 3.3 Hand control to the pipeline

Merge a real change to `main` and let `deploy.yml` run. Because the state
already reflects reality, the staging apply should be a no-op or a small diff,
which is a good way to confirm the pipeline's credentials work without risking
a first-time create.

**Gate:** smoke test passes, an item exists in `staging-requests-db`, the
request event appears in CloudWatch, and a pipeline-driven deploy has
succeeded at least once.

**Rollback:** `terraform destroy -var-file=env/staging.tfvars`. Staging sets
`artifacts_force_destroy = true` and no deletion protection precisely so this
works cleanly.

### Known first-run stumbles

| Symptom | Cause | Fix                                                                                                         |
| --- | --- |-------------------------------------------------------------------------------------------------------------|
| `CloudWatch Logs role ARN must be set in account settings` | Phase 1 skipped or `manage_apigateway_account_role=false` | Re-run shared/                                                                                              |
| `BucketAlreadyExists` | Someone else owns that global bucket name | Change `artifacts_bucket_name` in the tfvars                                                                |
| `KMSAccessDeniedException` on first invoke | Key policy still propagating | Wait a minute and retry                                                                                     |
| `InvalidParameterValueException: ... decreases account's UnreservedConcurrentExecution below its minimum value of [N]` | The account's total Lambda concurrency quota is at or near the floor AWS insists stays unreserved — typical on a new account, where the limit is 10 | Set `lambda_reserved_concurrency = -1` (already the staging default), or raise the quota via Service Quotas |
| Plan wants to replace the Lambda every run | `source_version` differs between local and CI | Expected — it is a tag change, not a replacement                                                            |

---

## Phase 4 - Staging soak

Resist going straight to production. A day in staging surfaces the things a
single smoke test cannot.

### 4.1 Exercise the guardrails

```bash
URL=$(terraform -chdir=terraform output -raw health_endpoint)

# 1. Warm the function. The first invocation of a VPC-attached Lambda is a
#    cold start of a second or more; letting it land inside the measured run
#    would inflate concurrency and skew every number after it.
for i in 1 2 3; do curl -s -o /dev/null "$URL?payload=warmup-$i"; done

# 2. 60 requests, at most 8 in flight. Bounded parallelism is the point:
#    eight concurrent ~120 ms invocations sustain roughly 65 rps, well over
#    the 20 rps stage limit, while staying under the account's Lambda
#    concurrency ceiling. Raising rate WITHOUT raising parallelism is what
#    isolates the gateway throttle from Lambda throttling.
seq 1 60 | xargs -P 8 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  "$URL?payload=load-{}" | sort | uniq -c
```

Reading the result:

| Output | Meaning |
| --- | --- |
| Mostly `200`, a tail of `429` | The stage throttle is working — the burst bucket drained and API Gateway rejected the overflow. This is the pass condition. |
| Any `502` or `500` | You exceeded **Lambda** concurrency, not the gateway throttle. Lower `-P` and re-run; a 5xx here says nothing about the anti-DDoS control. |
| All `200` | Never reached the limit. Raise the count to 120, or `-P` to 10 if the account quota allows. |

Check your ceiling before adjusting `-P`:

```bash
aws lambda get-account-settings --query 'AccountLimit.ConcurrentExecutions'
```

On a new account that returns `10`, so keep `-P` at 8 or below.

Then the validation guardrail — an oversized body must be rejected:

```bash
python3 -c "import json;print(json.dumps({'payload':'x'*9000}))" \
  | curl -s -o /dev/null -w '%{http_code}\n' -X POST "$URL" \
    -H 'Content-Type: application/json' -d @-
```

Expect `400`.

### 4.2 Confirm the operational surface

- Alarms exist and are in `OK`:
  `aws cloudwatch describe-alarms --alarm-name-prefix staging-health-check`
- Items carry `expires_at` so TTL will reclaim them
- Log groups have the expected retention and a KMS key
- VPC flow logs are arriving

### 4.3 Look at the bill

After 24 hours, check Cost Explorer. Staging should be
running at under 10$ a month, dominated by the KMS key. A number far
off that estimate means something is misconfigured, usually log retention or
an unexpected NAT.

**Gate:** throttling observed, validation rejects observed, alarms in `OK`,
cost within the estimated range.

---

## Phase 5 - Production

### 5.1 Pre-checks

- Create the on-call SNS topic and put its ARN in `alarm_sns_topic_arns` in
  `terraform/env/prod.tfvars`. Alarms that notify nobody are decoration.
- Re-read `prod.tfvars`. Confirm `dynamodb_deletion_protection = true`,
  `dynamodb_point_in_time_recovery = true`, and that the throttle limits
  (200 rps / 400 burst) match the expected traffic.
- Confirm the `production` environment's required reviewers are available.
- Announce a window. Nothing here causes an outage, it is a first create,
  but the approval blocks the pipeline until someone acts.

### 5.2 Deploy

Merge to `main`. The pipeline runs the quality and security gates, deploys
staging, then **stops** at the production job with status *Waiting*.

The approver should:

1. Open the run, read the plan rendered in the job summary.
2. Check the resource count matches expectations (a first prod deploy is all
   creates; a later one should be a small, explainable diff).
3. Click **Review deployments → production → Approve and deploy**.

### 5.3 Verify

```bash
bash scripts/smoke-test.sh "<prod health endpoint from the run summary>"

aws dynamodb describe-table --table-name prod-requests-db \
  --query '{SSE:Table.SSEDescription,Protection:Table.DeletionProtectionEnabled}'
aws dynamodb describe-continuous-backups --table-name prod-requests-db
aws cloudwatch describe-alarms --alarm-name-prefix prod-health-check \
  --query 'MetricAlarms[].{Name:AlarmName,Actions:AlarmActions}'
```

Record the endpoint URL and the published Lambda version somewhere durable —
the run summary prints both.

**Gate:** smoke test passes against production, PITR enabled, deletion
protection on, alarms have a non-empty action list.

**Rollback:** move the alias back to the previous version. This takes seconds
and needs no Terraform run:

```bash
aws lambda update-alias \
  --function-name prod-health-check-function \
  --name live --function-version <previous>
```

Then revert the commit so the next apply agrees with reality. For an
infrastructure-level problem rather than a code one, revert the commit and let
the pipeline apply the previous configuration.

---

## Phase 6 — Day-two operations

| Cadence | Task                                                                                                                           |
| --- |--------------------------------------------------------------------------------------------------------------------------------|
| Every deploy | Watch the smoke test; it is the canary                                                                                         |
| Weekly | Review alarm history and any 5xx                                                                                               |
| Monthly | Check spend against `docs/COST.md`                                                                                             |
| Quarterly | Rotate the CI access key: `terraform apply -replace=aws_iam_access_key.ci[0]` in `shared/`, then update the two GitHub secrets |
| Quarterly | Bump provider and action versions, let the scanners re-run                                                                     |
| On drift suspicion | `terraform plan` against each environment; a non-empty plan means someone changed something by hand                            |

### Teardown

```bash
cd terraform
terraform init -backend-config=env/staging.backend.hcl
terraform destroy -var-file=env/staging.tfvars
```

Production resists on purpose: turn off `dynamodb_deletion_protection` and set
`artifacts_force_destroy = true`, apply that, then destroy. Shared/ goes
last, and the state bucket's `prevent_destroy` has to be removed by hand.

---

## Risk register

| Risk                                                  | Likelihood | Impact | Mitigation |
|-------------------------------------------------------| --- | --- | --- |
| Untested code fails on first real apply               | **High** | Medium | Phase 0.2 runs every check before any AWS call |
| CI secret access key leaks                            | Low | High | Key holder can only `sts:AssumeRole`; `ExternalId` required; roles fenced by region and name prefix; quarterly rotation |
| Someone approves a production plan without reading it | Medium | High | Plan rendered in the job summary; approval recorded; two-person rule if a second reviewer is added |
| Shared/ state file with the secret key is mishandled  | Medium | High | Phase 1.3 forces an explicit choice |
| Alarms fire into the void                             | **High** if 5.1 skipped | Medium | Explicit pre-check; `alarm_sns_topic_arns` ships empty by design |
| Cost surprise from log retention                      | Low | Low | Retention set on every group; TTL on items; phase 4.3 checks the bill |
| Unauthenticated endpoint abused                       | Medium | Medium | Edge validation, stage throttling, reserved concurrency, 4xx alarm. Set `authorization = "AWS_IAM"` or add a WAF if exposure grows |
| Terraform state corrupted or lost                     | Low | High | Versioned, encrypted bucket with DynamoDB locking; deployment roles denied `s3:DeleteBucket` on it |

## Rollback summary

| Phase | Rollback                                                                              |
| --- |---------------------------------------------------------------------------------------|
| 0 | Nothing deployed                                                                      |
| 1 | `terraform destroy` in `shared/` (release `prevent_destroy` first)                    |
| 2 | Delete the secrets and environments; nothing in AWS changed                           |
| 3 | `terraform destroy -var-file=env/staging.tfvars`                                      |
| 4 | As phase 3                                                                            |
| 5 | Move the Lambda alias back (seconds), or revert the commit and let the pipeline apply |

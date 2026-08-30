# Shared resources for staging and prod

Run this **once per AWS account**, from a workstation with administrator
credentials, before anything else. It creates the things the environment
stacks assume already exist.

| Resource | Why it is here and not in `terraform/` |
| --- | --- |
| S3 state bucket + KMS key | It *is* the remote backend, so it cannot be stored in the remote backend. |
| DynamoDB state lock table | Same. |
| `healthcheck-api-ci-user` + access key | The one long-lived credential. A deployment must never be able to mint credentials for itself. |
| `staging-health-check-deploy-role`, `prod-health-check-deploy-role` | A role cannot create the role that creates it. |
| API Gateway account CloudWatch role | Account-wide singleton — two environments managing it would fight. |

## Apply

```bash
cd shared
terraform init
terraform apply -var="deploy_role_external_id=$(openssl rand -hex 16)"
```

`terraform.tfvars` is auto-loaded and controls which environments get a
deployment role. It ships as:

```hcl
environments = ["staging"]
```

Widen it to `["staging", "prod"]` when production is signed off. The list lives
in a committed file rather than a `-var` flag on purpose: this stack is
re-applied to rotate the CI key, and a run that forgot the flag would create
the production role as a side effect of a key rotation.


Keep the `deploy_role_external_id` you generated: it becomes the
`AWS_DEPLOY_EXTERNAL_ID` GitHub secret and is required on every `AssumeRole`.

## Collect the values the pipeline needs

```bash
terraform output state_bucket
terraform output deploy_role_arns
terraform output ci_access_key_id
terraform output -raw ci_secret_access_key
terraform output -raw backend_config_staging > ../terraform/env/staging.backend.hcl
terraform output -raw backend_config_prod    > ../terraform/env/prod.backend.hcl
```

## State handling

This stack keeps **local state**, and that state contains the CI user's secret
access key. Either:

- store `shared/terraform.tfstate` somewhere safe (it is gitignored), or
- apply with `-var="create_ci_access_key=false"` and mint the key by hand:
  `aws iam create-access-key --user-name healthcheck-api-ci-user`, or
- migrate this stack into the bucket it just created, once, with
  `terraform init -migrate-state -backend-config=...`.

## Rotating the CI key

```bash
terraform apply -replace=aws_iam_access_key.ci[0]
```

Then update the `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` repository
secrets. Rotate at least quarterly.

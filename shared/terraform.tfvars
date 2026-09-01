###############################################################################
# Shared variables — auto-loaded by Terraform on every apply in this
# directory.
#
# This file exists so the environment list is not a command-line flag someone
# has to remember. Shared resources are re-applied occasionally — most often to rotate
# the CI access key:
#
#     terraform apply -replace=aws_iam_access_key.ci[0]
#
# and a run that forgot `-var='environments=["staging"]'` would fall back to
# the variable's default and quietly create the production deployment role as a
# side effect of rotating a key. Harmless and the kind of
# thing that turns up in an access review months later with nobody able to say
# why it exists.
#
# No secrets belong here. `deploy_role_external_id` stays on the command line.
###############################################################################

# Only staging is deployed for now. Add "prod" when production is signed off
# and/or added later
environments = ["staging"]

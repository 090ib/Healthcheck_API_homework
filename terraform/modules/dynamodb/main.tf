###############################################################################
# DynamoDB module
#
# A single table storing one item per /health request, encrypted at rest with a
# customer-managed KMS key.
###############################################################################

resource "aws_dynamodb_table" "this" {
  name         = "${var.name_prefix}-${var.table_name}"
  billing_mode = var.billing_mode
  hash_key     = "id"

  # Only set for PROVISIONED; null under PAY_PER_REQUEST.
  read_capacity  = var.billing_mode == "PROVISIONED" ? var.read_capacity : null
  write_capacity = var.billing_mode == "PROVISIONED" ? var.write_capacity : null

  attribute {
    name = "id"
    type = "S"
  }

  # Server-Side Encryption with a customer-managed key, so key rotation,
  # access and deletion are all under our control and auditable in CloudTrail.
  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery_enabled
  }

  # Requests age out automatically, which bounds both storage cost and the
  # amount of request data retained.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  deletion_protection_enabled = var.deletion_protection_enabled

  tags = merge(var.tags, { Name = "${var.name_prefix}-${var.table_name}" })

  lifecycle {
    precondition {
      condition     = var.kms_key_arn != null && var.kms_key_arn != ""
      error_message = "A KMS key ARN is required: the table must use server-side encryption with a customer-managed key."
    }
  }
}

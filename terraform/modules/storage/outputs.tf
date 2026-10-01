output "assets_bucket" {
  value = aws_s3_bucket.this["assets"].bucket
}

output "reports_bucket" {
  value = aws_s3_bucket.this["reports"].bucket
}

output "bucket_arns" {
  value = { for k, b in aws_s3_bucket.this : k => b.arn }
}

output "kms_key_arn" {
  value = aws_kms_key.s3.arn
}

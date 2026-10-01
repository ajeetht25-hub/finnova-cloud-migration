bucket         = "finnova-tfstate-staging-<ACCOUNT_ID>"
key            = "order-management/stack/terraform.tfstate"
region         = "ap-south-1"
dynamodb_table = "finnova-tf-locks"
encrypt        = true
kms_key_id     = "alias/finnova-tfstate"

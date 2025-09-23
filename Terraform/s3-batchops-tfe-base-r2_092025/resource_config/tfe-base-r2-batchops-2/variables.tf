variable "app_code"        { type = string }
variable "env_number"      { type = number }
variable "region"          { type = string }

# Human-readable purpose/description for the job (appears in the console)
variable "purpose"         { type = string }

# ARNs from your two bucket modules
variable "source_bucket_arn"       { type = string }
variable "source_kms_key_arn"      { type = string }
variable "destination_bucket_arn"  { type = string }
variable "destination_kms_key_arn" { type = string }

# Toggle to actually create the Batch Ops job
variable "enable_batch_copy" { 
type = bool
default = false 
}

# Optional knobs
variable "priority"      {
     type = number
     default = 10 
     } # 0-99 (0 highest)
variable "manifest_prefix" {
    type = string
    default = null
}

variable "report_prefix" { 
    type = string
    default = "batchops" 
    }

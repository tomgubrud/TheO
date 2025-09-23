variable "app_code"                 { type = string }
variable "env_number"               { type = number }
variable "purpose"                  { 
    type = string 
default = "backfill" 
} # shows up in names/descriptions

variable "source_bucket_arn"        { type = string }
variable "source_kms_key_arn"       { type = string }
variable "destination_bucket_arn"   { type = string }
variable "destination_kms_key_arn"  { type = string }

# When false: only the IAM role/policy are created. Flip to true to create & start the Batch Ops job.
variable "enable_batch_ops"         { 
    type = bool    
    default = false 
    }

# Optional: narrow what gets copied (leave empty to copy everything)
variable "prefixes"                 { 
    type = list(string) 
    default = [] 
    }

# Optional: job priority (1..priority ceiling)
variable "priority"                 { 
    type = number  
    default = 10 
    }

# Optional: write reports to this prefix in the destination bucket
variable "report_prefix"            { 
    type = string  
    default = "batchops/report" 
    }

# Optional: unique token; keeps job creation idempotent per (source,dest,purpose)
variable "client_request_token" {
  type    = string
  default = null
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "lab"
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.31"
}

variable "enable_disaggregated" {
  description = "Enable disaggregated prefill/decode NodePools (LLM-D pattern)"
  type        = bool
  default     = true # main = LLM-D lab; combined pattern lives on branch combined-serving
}

variable "model_bucket" {
  description = "S3 bucket for model weights"
  type        = string
  default     = ""
}

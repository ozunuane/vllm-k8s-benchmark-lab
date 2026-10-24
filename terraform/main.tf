# EKS cluster for vLLM inference benchmarks
# GPU nodes: g6.xlarge (L4, 24 GB VRAM)

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

provider "aws" {
  region = var.region
}

locals {
  cluster_name = "vllm-bench-${var.environment}"
  tags = {
    Project     = "vllm-k8s-benchmark-lab"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

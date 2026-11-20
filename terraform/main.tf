# EKS cluster for vLLM inference benchmarks
# GPU nodes: g6.xlarge (L4, 24 GB VRAM)

terraform {
  required_version = ">= 1.10" # S3 native locking (use_lockfile)

  backend "s3" {
    bucket       = "vllm-bench-tfstate-595893120359" # created outside TF (chicken-and-egg)
    key          = "vllm-bench-lab/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # S3-native lock — no DynamoDB table needed (TF >= 1.10)
  }

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
  azs          = slice(data.aws_availability_zones.available.names, 0, 3)
  tags = {
    Project     = "vllm-k8s-benchmark-lab"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# -----------------------------------------------------
# VPC
# -----------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = local.azs
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true # save cost — single NAT for lab
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = local.cluster_name
  }

  tags = local.tags
}

# -----------------------------------------------------
# EKS Cluster
# -----------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  # Pin admin access to an explicit principal instead of
  # enable_cluster_creator_admin_permissions: "creator" is derived from the
  # CALLER, so CI's plan role would plan to replace ozi's access entry
  # (lockout if ever applied) and churn every CI plan.
  access_entries = {
    ozi_admin = {
      principal_arn = "arn:aws:iam::595893120359:user/ozi"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # Same caller-relative trap: KMS key administrators default to the caller
  kms_key_administrators = ["arn:aws:iam::595893120359:user/ozi"]

  # System node group — small, runs karpenter + system pods
  eks_managed_node_groups = {
    system = {
      instance_types = ["m5.large"]
      min_size       = 1
      max_size       = 3
      # 2 nodes: Prometheus + Grafana + KEDA need the room, and the
      # Karpenter HA replica (pod anti-affinity) needs a second node.
      # Managed node groups don't autoscale without CAS — size explicitly.
      desired_size = 2

      labels = {
        role = "system"
      }
    }
  }

  # EKS module already creates 8443 ingress rule for webhooks
  # No additional security group rules needed for Karpenter

  tags = merge(local.tags, {
    "karpenter.sh/discovery" = local.cluster_name
  })
}

# -----------------------------------------------------
# Karpenter
# -----------------------------------------------------
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = module.eks.cluster_name

  # Helm chart uses IRSA (eks.amazonaws.com/role-arn annotation),
  # so the controller role must trust the cluster OIDC provider,
  # not pods.eks.amazonaws.com (Pod Identity).
  enable_irsa                     = true
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["karpenter:karpenter"]

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.1.1"
  wait             = true

  set {
    name  = "settings.clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "settings.interruptionQueue"
    value = module.karpenter.queue_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter.iam_role_arn
  }
}

# -----------------------------------------------------
# Karpenter GPU NodePool
# -----------------------------------------------------
resource "kubectl_manifest" "gpu_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: gpu
    spec:
      amiSelectorTerms:
        - alias: al2023@latest
      role: ${module.karpenter.node_iam_role_name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${local.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${local.cluster_name}
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 100Gi
            volumeType: gp3
            deleteOnTermination: true
      tags:
        ${jsonencode(local.tags)}
  YAML

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "gpu_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: gpu
    spec:
      template:
        metadata:
          labels:
            node-type: gpu
            # nvidia-device-plugin's default nodeAffinity requires this
            # label (normally set by Node Feature Discovery, which we
            # don't run). Without it the plugin never schedules and the
            # node never advertises nvidia.com/gpu.
            nvidia.com/gpu.present: "true"
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: gpu
          requirements:
            - key: node.kubernetes.io/instance-type
              operator: In
              values:
                - g6.xlarge
            - key: karpenter.sh/capacity-type
              operator: In
              values:
                - on-demand
          taints:
            - key: nvidia.com/gpu
              effect: NoSchedule
      limits:
        cpu: "32"
        nvidia.com/gpu: "4"
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 5m
  YAML

  depends_on = [helm_release.karpenter]
}

# -----------------------------------------------------
# Disaggregated Serving NodePools (LLM-D)
# Prefill nodes: compute-heavy (g6.xlarge / L4)
# Decode nodes: bandwidth-heavy (g5.xlarge / A10G)
# Enable by setting var.enable_disaggregated = true
# -----------------------------------------------------
resource "kubectl_manifest" "prefill_node_pool" {
  count = var.enable_disaggregated ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: prefill
    spec:
      template:
        metadata:
          labels:
            node-type: gpu
            inference-role: prefill
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: gpu
          requirements:
            - key: node.kubernetes.io/instance-type
              operator: In
              values:
                - g6.xlarge    # L4 — good compute-to-cost ratio for prefill
            - key: karpenter.sh/capacity-type
              operator: In
              values:
                - on-demand
          taints:
            - key: nvidia.com/gpu
              effect: NoSchedule
            - key: inference-role
              value: prefill
              effect: NoSchedule
      limits:
        cpu: "16"
        nvidia.com/gpu: "2"
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 5m
  YAML

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "decode_node_pool" {
  count = var.enable_disaggregated ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: decode
    spec:
      template:
        metadata:
          labels:
            node-type: gpu
            inference-role: decode
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: gpu
          requirements:
            - key: node.kubernetes.io/instance-type
              operator: In
              values:
                - g5.xlarge    # A10G — higher memory bandwidth for decode
            - key: karpenter.sh/capacity-type
              operator: In
              values:
                - on-demand
          taints:
            - key: nvidia.com/gpu
              effect: NoSchedule
            - key: inference-role
              value: decode
              effect: NoSchedule
      limits:
        cpu: "32"
        nvidia.com/gpu: "4"       # more decode capacity — decode is the bottleneck
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 5m
  YAML

  depends_on = [helm_release.karpenter]
}

# -----------------------------------------------------
# NVIDIA Device Plugin
# -----------------------------------------------------
resource "helm_release" "nvidia_device_plugin" {
  namespace        = "nvidia-device-plugin"
  create_namespace = true
  name             = "nvidia-device-plugin"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = "0.17.0"
  wait             = true

  # Only run on GPU nodes
  set {
    name  = "nodeSelector.node-type"
    value = "gpu"
  }

  set {
    name  = "tolerations[0].key"
    value = "nvidia.com/gpu"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  depends_on = [module.eks]
}

# -----------------------------------------------------
# DCGM Exporter (GPU metrics for Prometheus)
# -----------------------------------------------------
resource "helm_release" "dcgm_exporter" {
  namespace  = "nvidia-device-plugin"
  name       = "dcgm-exporter"
  repository = "https://nvidia.github.io/dcgm-exporter/helm-charts"
  chart      = "dcgm-exporter"
  version    = "3.6.0"
  wait       = true

  # ServiceMonitor CRD is provided by kube-prometheus-stack
  set {
    name  = "serviceMonitor.enabled"
    value = "true"
  }

  # Only run on GPU nodes — crashes on CPU nodes (no GPU to monitor)
  set {
    name  = "nodeSelector.node-type"
    value = "gpu"
  }

  set {
    name  = "tolerations[0].key"
    value = "nvidia.com/gpu"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  depends_on = [module.eks, helm_release.kube_prometheus_stack]
}

# -----------------------------------------------------
# Monitoring: kube-prometheus-stack (Prometheus + Grafana)
# Provides the ServiceMonitor CRDs (dcgm) and the metrics
# backend KEDA queries for autoscaling.
# -----------------------------------------------------
resource "helm_release" "kube_prometheus_stack" {
  namespace        = "monitoring"
  create_namespace = true
  name             = "kube-prometheus-stack"
  # Local chart: the HTTPS repo's ~15 MB index times out on slow links and
  # ghcr OCI hit a stale-credential 403. Pre-pulled via:
  #   helm pull oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack -d charts/
  chart   = "${path.module}/charts/kube-prometheus-stack-93.5.0.tgz"
  wait    = true
  timeout = 600

  values = [
    yamlencode({
      alertmanager = {
        enabled = false # lab — no paging
      }
      grafana = {
        enabled = true
        # kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
      }
      prometheus = {
        prometheusSpec = {
          retention = "2d" # lab — keep storage small
          # Select ALL ServiceMonitors/PodMonitors, not only those labeled
          # with this Helm release (otherwise dcgm's monitor is ignored)
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          # vLLM pods advertise metrics via prometheus.io/* annotations
          # (set by the Helm chart). The operator doesn't scrape annotations
          # by default — this classic job adds it.
          additionalScrapeConfigs = [
            {
              job_name              = "kubernetes-pods"
              kubernetes_sd_configs = [{ role = "pod" }]
              relabel_configs = [
                {
                  source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_scrape"]
                  action        = "keep"
                  regex         = "true"
                },
                {
                  source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_path"]
                  action        = "replace"
                  target_label  = "__metrics_path__"
                  regex         = "(.+)"
                },
                {
                  source_labels = ["__address__", "__meta_kubernetes_pod_annotation_prometheus_io_port"]
                  action        = "replace"
                  regex         = "([^:]+)(?::\\d+)?;(\\d+)"
                  replacement   = "$1:$2"
                  target_label  = "__address__"
                },
                {
                  source_labels = ["__meta_kubernetes_namespace"]
                  target_label  = "namespace"
                },
                {
                  source_labels = ["__meta_kubernetes_pod_name"]
                  target_label  = "pod"
                },
              ]
            }
          ]
        }
      }
    })
  ]

  depends_on = [module.eks]
}

# -----------------------------------------------------
# KEDA — event-driven autoscaler. Reads Prometheus,
# drives the HPA created by the vLLM chart's ScaledObject.
# -----------------------------------------------------
resource "helm_release" "keda" {
  namespace        = "keda"
  create_namespace = true
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  wait             = true

  depends_on = [module.eks]
}

# -----------------------------------------------------
# Outputs
# -----------------------------------------------------
output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

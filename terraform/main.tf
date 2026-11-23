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

  # EKS >=1.23 ships no storage driver: PVCs (qdrant) hang on
  # "waiting for ebs.csi.aws.com" without this addon.
  cluster_addons = {
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

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
      # CSI controller + node pods use node-role creds (no IRSA at lab scale)
      iam_role_additional_policies = {
        EBSCSIDriver = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }
      # 3 nodes: with the llm-d v1.0 stack (EPP+Envoy, LWS controller) on top
      # of Prometheus/Grafana/KEDA/Argo CD/middledock, 2 nodes sat at ~90%
      # CPU requests — Argo CD had no burst headroom and the UI crawled.
      # min_size does the scaling: the EKS module ignores desired_size
      # changes after creation (lifecycle ignore_changes, so TF doesn't
      # fight autoscalers) — bumping desired_size alone is a silent no-op.
      min_size     = 3
      max_size     = 3
      desired_size = 3

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
    ModelsS3                     = aws_iam_policy.models_s3.arn
    EBSCSIDriver                 = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  }

  tags = local.tags
}

# Model weights bucket access — GPU nodes (initContainer sync) and
# system nodes (one-time HF→S3 transfer job). Pods use the node
# instance profile; no IRSA needed at lab scale.
resource "aws_iam_policy" "models_s3" {
  name = "${local.cluster_name}-models-s3"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::vllm-bench-models-595893120359",
        "arn:aws:s3:::vllm-bench-models-595893120359/*"
      ]
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "system_models_s3" {
  role       = module.eks.eks_managed_node_groups["system"].iam_role_name
  policy_arn = aws_iam_policy.models_s3.arn
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
      # Hop limit 1 (default) blocks PODS from IMDS — the S3 initContainer
      # gets "Unable to locate credentials". 2 = container-depth access
      # to the node role (coarse but intentional at lab scale, no IRSA).
      metadataOptions:
        httpPutResponseHopLimit: 2
        httpTokens: required
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
                # Never pin one type: g6 (L4) hit InsufficientInstanceCapacity
                # across all our AZs. Karpenter picks the cheapest available,
                # so g6 stays preferred; g5 (A10G, same 24GB VRAM) is fallback.
                - g6.xlarge
                - g5.xlarge
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
            nvidia.com/gpu.present: "true" # device plugin affinity (gotcha 9)
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: gpu
          requirements:
            - key: node.kubernetes.io/instance-type
              operator: In
              values:
                - g6.xlarge # L4 preferred (cheapest wins when in stock)
                - g5.xlarge # A10G fallback — us-east-1 L4 drought (gotcha 16)
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
            nvidia.com/gpu.present: "true" # device plugin affinity (gotcha 9)
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
  # Role NodePools (prefill/decode) carry a second taint — without this
  # toleration the device plugin never lands and the GPU never registers
  set {
    name  = "tolerations[1].key"
    value = "inference-role"
  }
  set {
    name  = "tolerations[1].operator"
    value = "Exists"
  }
  set {
    name  = "tolerations[1].effect"
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
  # Role NodePools (prefill/decode) carry a second taint — without this
  # toleration the device plugin never lands and the GPU never registers
  set {
    name  = "tolerations[1].key"
    value = "inference-role"
  }
  set {
    name  = "tolerations[1].operator"
    value = "Exists"
  }
  set {
    name  = "tolerations[1].effect"
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
# Argo CD — GitOps. Apps live in argocd/ in this repo.
# OCI registry: avoids argoproj helm repo's large index on slow links.
# -----------------------------------------------------
resource "helm_release" "argocd" {
  namespace        = "argocd"
  create_namespace = true
  name             = "argocd"
  repository       = "oci://ghcr.io/argoproj/argo-helm"
  chart            = "argo-cd"
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      configs = {
        params = {
          "server.insecure" = true # lab: port-forward, no TLS termination
        }
      }
    })
  ]

  depends_on = [module.eks]
}

# -----------------------------------------------------
# GitHub Actions APPLY role — the deploy half of the pipeline.
# Plan role (AWS_ROLE secret, read-only) handles PRs; this role applies on
# main, and ONLY from a job gated by the GitHub "production" environment:
# the OIDC sub for an environment-gated job is
#   repo:<owner@id>/<repo@id>:environment:production
# (immutable-ID format — gotcha 13; plain branch subs won't match).
# Blast radius controls: environment requires manual approval in GitHub,
# trust matches this repo's immutable ID only.
# -----------------------------------------------------
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "gha_apply" {
  name = "gha-terraform-apply"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:ozunuane@30769770/vllm-k8s-benchmark-lab@1431717694:environment:production"
        }
      }
    }]
  })
}

# The stack manages IAM/EKS/VPC — an apply role is admin in practice.
# Honest admin + hard gates beats a 300-line "least privilege" policy that
# drifts every time the stack grows.
resource "aws_iam_role_policy_attachment" "gha_apply_admin" {
  role       = aws_iam_role.gha_apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Cluster access for the helm/kubectl providers during apply —
# explicit entry, never caller-derived (gotcha 14).
resource "aws_eks_access_entry" "gha_apply" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.gha_apply.arn
}

resource "aws_eks_access_policy_association" "gha_apply_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.gha_apply.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }

  depends_on = [aws_eks_access_entry.gha_apply]
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

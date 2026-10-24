# vllm-k8s-benchmark-lab

Production-style vLLM deployment on EKS with benchmarking, autoscaling, and observability.

## What this is

A hands-on lab for deploying and operating LLM inference infrastructure:

- **vLLM** serving Qwen2.5-7B-Instruct (BF16 and AWQ)
- **EKS** with g6.xlarge (L4) nodes via Karpenter
- **Helm** chart for vLLM with tuned serving parameters
- **KEDA** autoscaling on `vllm:num_requests_waiting`
- **Prometheus + Grafana** dashboards (TTFT, ITL, throughput, GPU utilisation)
- **Argo CD** GitOps deployment
- **GitHub Actions** CI/CD with OIDC auth

## Structure

```
terraform/          EKS cluster, Karpenter NodePool, S3 for model weights
helm/vllm/          Helm chart for vLLM deployment
benchmarks/         Scripts, raw results (CSV), and plots
argocd/             Argo CD Application manifests
grafana/dashboards/ Grafana dashboard JSON
docs/               Architecture notes and runbooks
.github/workflows/  CI/CD pipelines
```

## Model weights

Pulled from Hugging Face once, stored in S3, mounted via initContainer/PVC.
Never re-downloaded per pod start.

## GPU instances

| Instance | GPU   | VRAM  | Use case           |
|----------|-------|-------|--------------------|
| g6.xlarge | L4   | 24 GB | Default for labs   |
| g5.xlarge | A10G | 24 GB | Comparison runs    |

## Quick start

```bash
# 1. Stand up EKS cluster
cd terraform && terraform init && terraform apply

# 2. Deploy vLLM via Argo CD
kubectl apply -f argocd/

# 3. Run benchmarks
cd benchmarks && ./run-benchmark.sh
```

## Related

- [Inference Engineering roadmap](https://github.com/ozunuane) — parent planning repo
- [kipply — Transformer Inference Arithmetic](https://kipp.ly/transformer-inference-arithmetic/)
- [vLLM docs](https://docs.vllm.ai/)

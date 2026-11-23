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

**Planned improvement — stream weights, skip the copy:** scale-out is currently
~8 min pod-to-serving, dominated by the initContainer's `s3 sync` to local disk
followed by a sequential load into VRAM. vLLM's
[Run:ai Model Streamer](https://docs.vllm.ai/en/latest/models/extensions/runai_model_streamer.html)
(`--load-format runai_streamer` + `--model s3://...`) reads tensors from S3
concurrently and streams them straight into GPU memory — no initContainer, no
node-disk staging, load time bounded by S3 throughput instead of
disk-write + sequential-read. Candidate next step for cutting cold-start.

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

- [Build log / blog series](https://medium.com/@ozidevops) — the write-ups behind this lab:
  - [Prefill vs Decode: Why LLM Inference Looks Nothing Like Serving a REST API](https://blog.stackademic.com/prefill-vs-decode-why-llm-inference-looks-nothing-like-serving-a-rest-api-204a4900d772)
  - [I Built a Production Lab-Grade LLM Serving Platform on EKS](https://ozidevops.medium.com/i-built-a-production-lab-grade-llm-serving-platform-on-eks-the-model-was-the-easy-part-acc186037b2a)
- [middledock-rag-assistant](https://github.com/ozunuane/middledock-rag-assistant) — companion RAG app served by this platform
- [kipply — Transformer Inference Arithmetic](https://kipp.ly/transformer-inference-arithmetic/)
- [vLLM docs](https://docs.vllm.ai/)
- [llm-d project](https://llm-d.ai/) — the disaggregated serving stack installed in `llm-d-v1/`

## Deployment patterns (branches)

| Branch | Pattern | When to use |
|---|---|---|
| [`combined-serving`](../../tree/combined-serving) | Prefill + decode on one GPU per replica. KEDA scales whole replicas on queue depth. | Most workloads under ~100 concurrent users — simplest, cheapest |
| `main` (in progress) | LLM-D disaggregated: prefill nodes (compute-heavy GPU) + decode nodes (bandwidth-heavy GPU), KV cache transfer between them | Large scale, long prompts, when prefill and decode contention hurts both |

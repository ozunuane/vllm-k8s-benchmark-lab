# llm-d-v1 — official llm-d stack (GitOps install)

The official llm-d v1.0 project installed declaratively via Argo CD, in
**standalone router mode** — no gateway controller, no Gateway API CRDs.
This coexists with `../llm-d/`, the hand-rolled P/D disaggregation lab
(NixlConnector + stdlib pd-proxy) — kept as the from-first-principles
reference. Only one of the two should hold GPU replicas at a time
(8 G-vCPU quota = 2 single-GPU nodes).

| | `llm-d/` (hand-rolled) | `llm-d-v1/` (official) |
|---|---|---|
| Routing | stdlib Python pd-proxy | EPP scheduler + Envoy sidecar (llm-d-router-standalone) |
| Scheduling | none (every request is P→D) | pluggable: prefix-cache affinity, token/load scorers |
| KV transfer | NixlConnector, manual wiring | NixlConnector via llm-d routing sidecar (nixlv2) |
| Workload kind | 2 Deployments | DisaggregatedSet (LWS operator) — P/D rolls out as one unit |
| Tuning | raw Deployment yaml | EPP plugin config + values in git, synced by Argo CD |

## Components (Argo CD apps in `../argocd/`, sync-waved)

| Wave | App | Source | Version |
|---|---|---|---|
| 0 | `llm-d-v1-crds` | vendored GAIE `v1-manifests.yaml` (`crds/`) | v1.6.2 |
| 0 | `llm-d-v1-lws` | `oci registry.k8s.io/lws/charts/lws`, `enableDisaggregatedSet=true` | 1.0.0 |
| 1 | `llm-d-v1-router` | `oci ghcr.io/llm-d/charts/llm-d-router-standalone` | v1.0.0 |
| 2 | `llm-d-v1-modelserver` | `modelserver/` kustomize (DisaggregatedSet) | vLLM v0.31.0 / sidecar v1.0.0 |

All images and charts pinned — upstream guides default to moving tags
(`v0`, `:main`), which silently drift under Argo.

## Request path

```
client → Service llm-d-pd-epp:80 (Envoy sidecar :8081, OpenAI API)
       → EPP picks prefill endpoint (pd-config.yaml scheduling profiles)
       → prefill pod :8000 (kv_producer)
       → decode pod  :8000 routing sidecar → vLLM :8200 (kv_consumer, KV via NIXL)
```

Label contract: DisaggregatedSet pods carry `llm-d.ai/pool: qwen-pd`;
the router values' `modelServers.matchLabels` must match — that is what the
InferencePool selects.

## Lab adaptations vs upstream guide

- Qwen2.5-7B-Instruct-AWQ instead of gpt-oss-120b; decode TP=1 (1 GPU)
  instead of TP=4 — one g6/g5.xlarge per role, UCX over TCP (no EFA)
- cpu 3 / mem 12Gi requests (allocatable-fit, gotcha 5); shm 8Gi
- EPP + Envoy sized down from cpu 4/mem 8Gi to fit m5.large system nodes
- decode rollout maxSurge=0 (no spare GPU under quota)
- `peakPrefillThroughput` is upstream's H200 calibration — re-measure with
  the calibration script before trusting the affinity gate

## Prereq (out-of-band, once per cluster)

```
kubectl create secret generic llm-d-hf-token -n llm-d --from-literal=HF_TOKEN=dummy
```

## Smoke test

```
kubectl -n llm-d port-forward svc/llm-d-pd-epp 8080:80
curl -s localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct-AWQ","messages":[{"role":"user","content":"hi"}],"max_tokens":32}'
```

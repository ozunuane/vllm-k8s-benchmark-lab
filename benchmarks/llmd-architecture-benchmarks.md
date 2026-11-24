# Official llm-d v1.0 (EPP) vs hand-rolled pd-proxy — same-harness A/B

Date: 2026-11-23 · Harness: /tmp/bench.py — fixed prompt (~25 tok), max_tokens=100,
temp=0, e2e latency, warm engine. seq=20 reqs, c10=30 reqs @10 conc, c30=60 reqs @30 conc.
Hardware both runs: prefill g6.xlarge (L4) us-east-1b + decode g5.xlarge (A10G) us-east-1a
(cross-AZ). NOTE: older published numbers (0.40/0.97/1.95) used a different harness —
not comparable; this file is the valid A/B.

## Official llm-d v1.0 — EPP scheduler + Envoy sidecar + routing sidecar (nixlv2)

| Load | p50 | p95 | max | err |
|---|---|---|---|---|
| seq | 1.57s | 1.59s | 1.59s | 0 |
| c10 | 1.75s | 2.00s | 2.00s | 0 |
| c30 | 2.44s | 2.83s | 2.84s | 0 |

Scaling shape: 1→10 = +11% p50, 1→30 = +55% p50. First-request NIXL transfer:
7.0 MB @ 135 MB/s, 51.77 ms, 0 failures (cross-AZ).

## Hand-rolled pd-proxy (stdlib Python, blind P→D forwarding)

| Load | p50 | p95 | max | err |
|---|---|---|---|---|
| seq | 1.58s | 2.33s | 2.33s | 0 |
| c10 | 2.16s | 2.68s | 2.69s | 0 |
| c30 | 3.73s | 4.41s | 5.10s | 0 |

## Verdict — CORRECTED (first conclusion was wrong)

| Load | official-stack p50 advantage |
|---|---|
| seq | 0% |
| c10 | 19% |
| c30 | 35% (p95 36%; max 2.84s vs 5.10s) |

INVALID as a scheduler comparison: with 1 prefill + 1 decode endpoint the EPP
has nothing to schedule — its scorers pick among one option. The delta
measures PROXY IMPLEMENTATION only: Envoy + Go routing sidecar vs a single
stdlib-Python proxy that serializes under concurrency (GIL). Expected result,
no inference-infra insight. Do not publish this as "EPP wins".

Valid experiments to run instead:
1. Architecture A/B: combined-serving vLLM vs official llm-d, same harness
   (claim about the P/D pattern itself)
2. Scheduler A/B: 1P+2D both stacks — pd-proxy spreads decode via ClusterIP
   round-robin (random) vs EPP load-aware picking. Needs quota 16 (have it).
   Folds into the KEDA heterogeneous autoscaling lab.

Gotcha 25 found during the swap: DisaggregatedSet spec.slices has CRD
minimum 1 — scale-to-zero parking must use per-role replicas: 0.

# Architecture A/B: combined (1x A10G) vs disaggregated llm-d (2x A10G)

Same harness; ALL nodes g5.xlarge/A10G this round (confound-free). Streamer-
loaded engines. Short prompt (~25 tok), max_tokens=100.

| Load | Combined p50/p95 (req/s) | Disagg p50/p95 (req/s) | Δp50 |
|---|---|---|---|
| seq  | 1.77/1.91 | 1.83/2.08 | ~0 |
| c10  | 1.89/2.09 | 1.90/2.27 | ~0 |
| c30  | 2.34/2.60 (12.2) | 2.36/2.94 (11.2) | ~0 |
| c60  | 3.52/4.06 (16.0) | 3.15/4.32 (16.1) | -11% |
| c100 | 4.35/6.45 (19.5) | 3.81/6.64 (19.1) | -12% |

0 errors / 760 reqs. FINDINGS (the honest kind):
1. Short-prompt workloads: disaggregation ≈ no win. Prefill at 25 tokens is
   trivial — nothing to isolate. 2x silicon for ~0-12% p50.
2. Throughput flatlines at ~19.5 req/s on BOTH — single decode GPU is the
   bottleneck in both architectures. Disagg p50 advantage at c60+ = prefill
   queueing moved off the hot path; tails stay decode-bound.
3. Implication: P/D pays when (a) prompts are long (prefill interference) or
   (b) decode scales independently (1P+2D) — which combined cannot do.
   Next tests: long-prompt round (RAG-style ~1.5-2k tok) and 1P+2D.

# Heterogeneous P/D (L40S prefill + A10G decode) — short prompts
Same short-prompt harness. L40S = g6e.xlarge (~3x A10G FP16 compute), same-AZ pair.
| Load | p50/p95 | req/s |
|---|---|---|
| c30 | 2.41/2.69 | 11.8 |
| c60 | 2.84/3.87 | 18.0 (best of all configs) |
| c100 | 5.31/6.69 | 17.0 (worst — single run, repeat before publishing) |
Finding: upgrading the NON-bottleneck phase helps until decode saturates, then
faster admission into a saturated decode HURTS (deeper batches, slower tokens).

# THE HEADLINE: long prompts (1404 tok, cache-busted), combined vs disagg
| Load | Combined 1xA10G | Disagg L40S+A10G | delta |
|---|---|---|---|
| c10 | 4.70s / 2.1 r/s | 3.34s / 2.8 r/s | -29% p50, +33% thr |
| c30 | 11.39s / 2.6 r/s | 7.17s / 4.1 r/s | -37% p50, +58% thr |
| c60 | 21.72s / 2.7 r/s | 10.88s / 4.2 r/s | -50% p50, +56% thr |

Complete claim (with the short-prompt null result): disaggregation buys ~0 on
short prompts and ~2x on long prompts. Phase isolation + right silicon per
phase pays exactly when prefill is heavy. Know your workload.

GOTCHA 28 (benchmark validity, again): identical prompts + enable_prefix_caching
= prefill becomes a cache hit; first long-prompt run measured the CACHE
(c10 1.63s, faster than short prompts!). Unique prompt HEAD per request busts
it (prefix matching starts at token 0). Randomize heads in every serving bench.

# ATTRIBUTION GAP + planned 2x2 (before ANY headline publishes)
The long-prompt round ran ONLY on hetero L40S+A10G: the -50%/+56% result
conflates architecture (split) with silicon (bigger prefill GPU). Owed cells:
| | Split | Replicated/Combined |
|---|---|---|
| Same silicon | 2xA10G P/D, long prompts (MISSING) | 2x plain A10G replicas, long prompts (MISSING — iso-cost baseline, $2.01/hr) |
| Better silicon | L40S+A10G (done, $2.87/hr) | single A10G (done, $1.01/hr) |
Plus cost-per-request column for every cell. Reproducibility pins per run:
chart+image versions (in git), weights = frozen S3 snapshot, prompt set +
harness (bench.py/bench-long.py — to be committed to repo).

## Streamer cold-start (measured during Phase 4 merge, warm node)
- Weights: 731 tensors S3→VRAM in 19s (runai_streamer, no disk staging)
- Pod→Ready: 2m34s (vs ~9 min HF path incl. node+image pull — confounded,
  but the weights stage itself collapsed from minutes to 19s)
- Remaining boot = engine init + CUDA graphs; next rung = 8GB image pull
  (ECR pull-through cache)

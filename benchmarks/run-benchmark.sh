#!/usr/bin/env bash
# Run vllm bench serve against a running vLLM endpoint.
# Usage: ./run-benchmark.sh [endpoint] [model]
#
# Requires: pip install vllm (for the bench CLI)

set -euo pipefail

ENDPOINT="${1:-http://localhost:8000}"
MODEL="${2:-Qwen/Qwen2.5-7B-Instruct}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="$(dirname "$0")/results"
mkdir -p "$OUTPUT_DIR"

echo "=== vLLM Benchmark ==="
echo "Endpoint: $ENDPOINT"
echo "Model:    $MODEL"
echo "Output:   $OUTPUT_DIR/$TIMESTAMP.json"
echo ""

python -m vllm.entrypoints.openai.api_server 2>/dev/null || true

vllm bench serve \
  --base-url "$ENDPOINT" \
  --model "$MODEL" \
  --num-prompts 100 \
  --dataset-name sharegpt \
  --save-result \
  --result-dir "$OUTPUT_DIR" \
  --result-filename "$TIMESTAMP.json"

echo ""
echo "Done. Results saved to $OUTPUT_DIR/$TIMESTAMP.json"

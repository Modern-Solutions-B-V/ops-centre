#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f docker-compose.base.yml ]]; then
  echo "ERROR: run from the ods/ directory" >&2
  exit 1
fi

files=(
  docker-compose.base.yml
  docker-compose.amd.yml
  extensions/services/ape/compose.yaml
  extensions/services/comfyui/compose.yaml
  extensions/services/comfyui/compose.amd.yaml
  extensions/services/embeddings/compose.yaml
  extensions/services/hermes/compose.yaml
  extensions/services/hermes-proxy/compose.yaml
  extensions/services/langfuse/compose.yaml.disabled
  extensions/services/litellm/compose.yaml
  extensions/services/n8n/compose.yaml
  extensions/services/perplexica/compose.yaml
  extensions/services/privacy-shield/compose.yaml
  extensions/services/qdrant/compose.yaml
  extensions/services/searxng/compose.yaml
  extensions/services/token-spy/compose.yaml
  extensions/services/tts/compose.yaml
  extensions/services/whisper/compose.yaml
  docker-compose.ms-qr1.yml
)

for file in "${files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "ERROR: missing QR1 compose file: $file" >&2
    exit 1
  fi
done

printf -- '-f %s ' "${files[@]}"
printf '\n'

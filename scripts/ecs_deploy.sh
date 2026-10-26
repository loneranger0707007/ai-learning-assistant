#!/bin/bash
set -e
REG="crpi-jpkia6z75h1unxo1.cn-guangzhou.personal.cr.aliyuncs.com"
IMG="$REG/loneranger/ai-learning-assistant:v2"
CONTAINER="aila-backend"

echo "=== 1. dirs ==="
mkdir -p /opt/ai-agent/data /opt/ai-agent/workspace

echo "=== 2. model key (developer mode) ==="
# MODEL_API_KEY must be supplied in the environment; never hardcode it here.
: "${MODEL_API_KEY:?Set MODEL_API_KEY in the environment before running}"
cat > /opt/ai-agent/data/model-secrets.env <<KEYEOF
MODEL_API_KEY=${MODEL_API_KEY}
KEYEOF
chmod 600 /opt/ai-agent/data/model-secrets.env

echo "=== 3. ACR login ==="
# ACR_PASSWORD must be supplied in the environment.
: "${ACR_PASSWORD:?Set ACR_PASSWORD in the environment before running}"
echo "$ACR_PASSWORD" | docker login --username="半学期英语课代表" --password-stdin "$REG"

echo "=== 4. pull image ==="
docker pull "$IMG"

echo "=== 5. run container ==="
docker rm -f "$CONTAINER" 2>/dev/null || true
docker run -d \
  --name "$CONTAINER" \
  --restart unless-stopped \
  -p 14242:14242 \
  -v /opt/ai-agent/data:/app/data \
  -v /opt/ai-agent/workspace:/app/workspace \
  -e MODEL_SECRET_FILE=/app/data/model-secrets.env \
  "$IMG"

echo "=== 6. wait for health ==="
for i in $(seq 1 30); do
  sleep 3
  CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:14242/health || true)
  echo "attempt $i: HTTP $CODE"
  if [ "$CODE" = "200" ]; then
    echo "HEALTH OK"
    break
  fi
done

echo "=== 7. verify ==="
curl -s http://127.0.0.1:14242/health
echo ""
docker ps --filter "name=$CONTAINER" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo DONE

#!/bin/bash
set -e
REG="crpi-jpkia6z75h1unxo1.cn-guangzhou.personal.cr.aliyuncs.com"
IMG="$REG/loneranger/ai-learning-assistant:v2"
ROOT="/opt/ai-agent"

echo "=== 1. install docker compose v2 plugin ==="
if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y -qq docker-compose-v2 || {
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -sSL "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64" -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  }
fi
docker compose version

echo "=== 2. stop old docker-run container ==="
docker rm -f aila-backend 2>/dev/null || true

echo "=== 3. write ECS compose.yml ==="
mkdir -p "$ROOT/scripts" "$ROOT/data" "$ROOT/workspace"
cat > "$ROOT/compose.yml" <<EOF
services:
  backend:
    image: $IMG
    ports:
      - "14242:14242"
    environment:
      APP_SQLITE_PATH: /app/data/app.sqlite
      WORKSPACE_ROOT: /app/workspace
      MODEL_SECRET_FILE: /app/data/model-secrets.env
    volumes:
      - $ROOT/data:/app/data
      - $ROOT/workspace:/app/workspace
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:14242/health', timeout=2).read()"]
      interval: 10s
      timeout: 3s
      retries: 12
      start_period: 10s
EOF

echo "=== 4. ensure model key ==="
# MODEL_API_KEY must be supplied in the environment; never hardcode it here.
: "${MODEL_API_KEY:?Set MODEL_API_KEY in the environment before running}"
cat > "$ROOT/data/model-secrets.env" <<KEYEOF
MODEL_API_KEY=${MODEL_API_KEY}
KEYEOF
chmod 600 "$ROOT/data/model-secrets.env"

echo "=== 5. compose up ==="
cd "$ROOT"
docker compose up -d

echo "=== 6. wait for healthy ==="
for i in $(seq 1 30); do
  sleep 3
  STATUS=$(docker compose ps --status running --services 2>/dev/null | tr -d '\n')
  CODE=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:14242/health || true)
  echo "attempt $i: services=[$STATUS] health=HTTP $CODE"
  if [ "$CODE" = "200" ] && echo "$STATUS" | grep -q backend; then
    echo "READY"
    break
  fi
done

echo "=== 7. copy check script ==="
cat > "$ROOT/scripts/check-ecs-docker.sh" <<'CHECKEOF'
#!/usr/bin/env bash
set -u
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_URL="${AILA_BACKEND_URL:-http://127.0.0.1:14242}"
OUTPUT_FILE="${AILA_CHECK_OUTPUT:-${ROOT_DIR}/ecs-docker-check.txt}"
exec > >(tee "${OUTPUT_FILE}") 2>&1
fail() { echo; echo "Result: FAIL"; echo "[FAIL] $1" >&2; exit 1; }
echo "AI Learning Assistant ECS Docker Check"
echo "Checked at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "Output file: ${OUTPUT_FILE}"
echo
echo "Checking the AI Learning Assistant runtime on this ECS server..."
command -v docker >/dev/null 2>&1 || fail "Docker is not installed."
echo "[OK] Docker CLI is installed."
docker info >/dev/null 2>&1 || fail "Docker daemon not running."
echo "[OK] Docker daemon is running."
docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin not available."
echo "[OK] Docker Compose is available."
running_services="$(docker compose -f "${ROOT_DIR}/compose.yml" ps --status running --services 2>/dev/null)"
grep -qx "backend" <<<"${running_services}" || fail "Backend container not running for this Compose project."
echo "[OK] Backend container is running."
command -v curl >/dev/null 2>&1 || fail "curl required."
curl -fsS "${BACKEND_URL}/health" >/dev/null 2>&1 || fail "Health endpoint did not respond."
echo "[OK] Application health check passed at ${BACKEND_URL}/health."
echo
echo "Result: PASS"
echo "Docker and the AI Learning Assistant are running correctly on this ECS server."
CHECKEOF
chmod +x "$ROOT/scripts/check-ecs-docker.sh"

echo "=== 8. run check ==="
cd "$ROOT"
bash scripts/check-ecs-docker.sh

echo "=== 9. show result file ==="
cat "$ROOT/ecs-docker-check.txt"
echo DONE

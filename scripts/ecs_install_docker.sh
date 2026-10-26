#!/bin/bash
set -e
echo "=== apt update ==="
apt-get update -qq
echo "=== install docker.io ==="
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io curl
echo "=== enable & start docker ==="
systemctl enable --now docker
sleep 3
docker --version
echo "=== add 2G swap (idempotent) ==="
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
echo "=== memory ==="
free -h
echo "=== docker info ==="
docker info --format 'ServerVersion={{.ServerVersion}} CgroupDriver={{.CgroupDriver}}'
echo DONE

#!/usr/bin/env bash
# Start (or rebuild) the spark-lab container. Data persists in volume spark-lab-home.
#   ./run.sh          build image if needed, start container, clone the fork inside once
#   ./run.sh rebuild  rebuild the image (volume kept)
set -euo pipefail
cd "$(dirname "$0")"
[ "${1:-}" = rebuild ] && docker rm -f spark-lab >/dev/null 2>&1 || true
docker build -q -t spark-lab:latest . >/dev/null
if ! docker ps -a --format '{{.Names}}' | grep -qx spark-lab; then
  docker run -d --name spark-lab --restart unless-stopped \
    -v spark-lab-home:/home/lab spark-lab:latest >/dev/null
fi
docker start spark-lab >/dev/null
docker exec spark-lab bash -lc '
  [ -d open-ssp/.git ] || git clone -q --recurse-submodules https://github.com/ibirapay/open-ssp.git
  cd open-ssp && git log --oneline -1 && git submodule status'

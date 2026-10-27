#!/usr/bin/env bash
# Regenerate spark/proto/spark/* from protos/spark.proto (the Makefile's %/% rule never matches).
set -euo pipefail
export PATH=$HOME/labs/spark-lab/tools/bin:$PATH
cd "${1:-.}"
d=spark/proto/spark/
protoc --go_out=$d --go_opt=paths=source_relative --proto_path=protos \
  --go-grpc_out=$d --go-grpc_opt=paths=source_relative \
  --validate_out="lang=go,paths=source_relative:$d" protos/spark.proto

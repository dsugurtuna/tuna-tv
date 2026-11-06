#!/usr/bin/env bash
# Runs the TunaCore unit tests on Linux inside the official Swift image (no Mac needed).
# Usage: scripts/test-core.sh [extra swift test args]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${SWIFT_IMAGE:-swift:6.2-noble}"
docker run --rm -v "$ROOT/Packages/TunaCore:/work" -w /work "$IMAGE" \
  bash -lc "swift build --build-tests -Xswiftc -warnings-as-errors=false 2>&1 | grep -E 'error|warning: unre|Compiling|Build' | tail -60; swift test $* 2>&1 | tail -80"

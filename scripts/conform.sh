#!/usr/bin/env bash
# Conformance gate (#127, processor #40): check the golden batches against the event catalogue at
# the tag pinned in catalogue.version. Needs go and git. PROCESSOR_DIR reuses a local checkout.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tag="$(cat "$root/catalogue.version")"
src="${PROCESSOR_DIR:-}"
if [ -z "$src" ]; then
  src="$(mktemp -d)"
  trap 'rm -rf "$src"' EXIT
  git clone -q --depth 1 --branch "$tag" https://github.com/NCG-Africa/edge_telemetry_processor_go.git "$src"
fi
cd "$src" && go run ./cmd/conform "$root/test/golden"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Building never installs. Each invocation preserves previous bundles/ZIPs and
# writes a newly verified local candidate under .build/local-packages.
export PYTHONDONTWRITEBYTECODE=1
exec python3 "${SCRIPT_DIR}/local_build.py" build "$@"

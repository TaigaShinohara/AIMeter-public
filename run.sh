#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPTIONS=()
for arg in "$@"; do
    case "${arg}" in
        -r|--restart) OPTIONS+=(--restart) ;;
        -b|--build) OPTIONS+=(--force-build) ;;
        -h|--help)
            echo "使用方法: ./run.sh [-r|--restart] [-b|--build]"
            echo "必要なら新規ビルドを作成し、検証後に設置して起動します。"
            echo "AIMETER_INSTALL_TO_APPLICATIONS=0 で設置を無効にできます。"
            exit 0 ;;
        *) echo "[AIMeter] 未対応のオプションです。" >&2; exit 1 ;;
    esac
done
export PYTHONDONTWRITEBYTECODE=1
# The launcher explicitly permits installation; build_app.sh itself never does.
exec python3 "${SCRIPT_DIR}/scripts/local_build.py" run --install "${OPTIONS[@]}"

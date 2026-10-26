#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

RESTART=false
FORCE_BUILD=false

for arg in "$@"; do
    case "${arg}" in
        -r|--restart)
            RESTART=true
            ;;
        -b|--build)
            FORCE_BUILD=true
            ;;
        -h|--help)
            echo "使用方法: ./run.sh [オプション]"
            echo ""
            echo "オプション:"
            echo "  -r, --restart   実行中のプロセスを終了して再起動"
            echo "  -b, --build     強制的に再ビルドを行ってから起動"
            echo "  -h, --help      このヘルプを表示"
            exit 0
            ;;
    esac
done

TARGET_APP="/Applications/AIMeter.app"
LOCAL_APP="${SCRIPT_DIR}/AIMeter.app"
APP_TO_OPEN=""

if [ -d "${TARGET_APP}" ] && [ -w "${TARGET_APP}" ]; then
    APP_TO_OPEN="${TARGET_APP}"
else
    APP_TO_OPEN="${LOCAL_APP}"
fi

# 起動中プロセスの確認
PID=$(pgrep -x AIMeter 2>/dev/null || true)

if [ -n "${PID}" ] && [ "${RESTART}" = true ]; then
    echo "[AIMeter] 実行中のプロセス (PID: ${PID}) を終了しています..."
    kill "${PID}" 2>/dev/null || true
    # 終了を少し待機
    for _ in {1..20}; do
        if ! pgrep -x AIMeter >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
    PID=""
fi

# 変更検知によるビルド要否の判定
NEED_BUILD=false
if [ "${FORCE_BUILD}" = true ] || [ ! -d "${APP_TO_OPEN}" ]; then
    NEED_BUILD=true
else
    APP_EXEC="${APP_TO_OPEN}/Contents/MacOS/AIMeter"
    if [ ! -f "${APP_EXEC}" ]; then
        NEED_BUILD=true
    else
        # ソースファイルの更新日時をチェック
        NEWEST_SRC=$(find Sources Package.swift scripts -type f 2>/dev/null | xargs stat -f "%m" 2>/dev/null | sort -nr | head -n 1 || echo 0)
        APP_TIME=$(stat -f "%m" "${APP_EXEC}" 2>/dev/null || echo 0)
        if [ "${NEWEST_SRC}" -gt "${APP_TIME}" ]; then
            NEED_BUILD=true
        fi
    fi
fi

if [ "${NEED_BUILD}" = true ]; then
    echo "[AIMeter] 変更が検出されたため、最新版をビルド中..."
    ./scripts/build_app.sh
fi

if [ -n "${PID}" ]; then
    echo "[AIMeter] AIMeter は既に起動しています (PID: ${PID})。"
    echo "[AIMeter] ウィジェットウィンドウを前面に呼び出します..."
    open "aimeter://show" 2>/dev/null || open "${APP_TO_OPEN}"
    echo "[AIMeter] ※ 再起動したい場合は './run.sh --restart' を実行してください。"
else
    echo "[AIMeter] AIMeter を起動しています..."
    open "${APP_TO_OPEN}"
    echo "[AIMeter] 起動完了！メニューバーおよびウィジェットをご確認ください。"
fi

.PHONY: run restart build test help

run:
	@./run.sh

restart:
	@./run.sh -r

build:
	@./scripts/build_app.sh

test:
	@swift test

help:
	@echo "AIMeter コマンド一覧:"
	@echo "  make run       - AIMeter を起動 (変更があれば自動ビルド、起動中なら前面表示)"
	@echo "  make restart   - 実行中の AIMeter を終了して最新版を再起動"
	@echo "  make build     - 新規のローカル用アプリと検証済みZIPを生成（設置なし）"
	@echo "  make test      - 単体テストを実行"

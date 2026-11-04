#!/usr/bin/env bash
# 共享资源目录迁移 CLI（默认 dry-run）
#
#   bash scripts/dsq-shared-migrate.sh --dry-run   # 只看计划，不动盘
#   bash scripts/dsq-shared-migrate.sh --apply     # 显式执行
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${TMPDIR:-/tmp}/dsq-shared-migrate"

swiftc -O -o "$BIN" \
    "$ROOT/QQPlayer/Services/UserHomeDirectory.swift" \
    "$ROOT/QQPlayer/Services/DSQSharedPaths.swift" \
    "$ROOT/QQPlayer/Services/DSQSharedMigrator.swift" \
    "$ROOT/scripts/dsq-shared/migrate/main.swift"

exec "$BIN" "$@"

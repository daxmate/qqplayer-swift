#!/usr/bin/env bash
# 共享资源路径层 + 迁移器自检（无模拟器 · swiftc 直编生产源码）
#
# 覆盖：环境变量覆盖 / 无容器回落 / 非沙盒直连 Group 容器 /
#      dry-run 零变更 / 迁移幂等 / 目标非空不覆盖 / 同卷 move / 跨卷 copy。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${TMPDIR:-/tmp}/dsq-shared-selftest"

swiftc -O -o "$BIN" \
    "$ROOT/QQPlayer/Services/UserHomeDirectory.swift" \
    "$ROOT/QQPlayer/Services/DSQSharedPaths.swift" \
    "$ROOT/QQPlayer/Services/DSQSharedMigrator.swift" \
    "$ROOT/scripts/dsq-shared/selftest/main.swift"

exec "$BIN"

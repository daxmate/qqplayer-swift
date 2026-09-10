#!/usr/bin/env bash
#
# xcbuild.sh — QQPlayer 统一构建入口（共享 SPM 缓存 + 独立 DerivedData）
#
# 为什么存在：
#   Xcode 每次在新 DerivedData 路径下构建，都会新建一个空的 SourcePackages 并重新
#   解析/clone 全部 SPM 依赖（GRDB.swift 的 git 子模块 SQLiteLib 在慢网络下能挂 1-2
#   小时）。本项目早就有一份完整缓存，但靠人手写 `-clonedSourcePackagesDirPath`
#   很容易漏 —— 本脚本把它固化成唯一入口，所有 worktree / 子代理一律走这里。
#
# 用法（与 xcodebuild 参数完全一致，脚本自动补两个路径参数）：
#   scripts/xcbuild.sh build-for-testing -scheme QQPlayer -destination 'generic/platform=iOS Simulator'
#   scripts/xcbuild.sh build -scheme QQPlayerMac -destination 'platform=macOS'
#   scripts/xcbuild.sh test -scheme QQPlayer -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
#
# 环境变量：
#   QQPLAYER_DD  覆盖 DerivedData 路径（默认 /tmp/dd-<worktree 目录名>，按工作区隔离防互踩）
#
set -euo pipefail

SHARED_SPM_DEFAULT="/Users/dax/codes/qqplayer-swift/build/SourcePackagesShared"
SHARED_SPM="${QQPLAYER_SPM:-$SHARED_SPM_DEFAULT}"

if [ ! -d "$SHARED_SPM/checkouts" ]; then
  echo "❌ 共享 SPM 缓存不存在或不完整：$SHARED_SPM" >&2
  echo "   （期望其下有 checkouts/，含 GRDB.swift、SFBAudioEngine 等）" >&2
  exit 2
fi

if command -v git >/dev/null 2>&1; then
  TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  WORKSPACE_NAME="$(basename "$TOPLEVEL")"
else
  WORKSPACE_NAME="$(basename "$(pwd)")"
fi
DERIVED_DATA="${QQPLAYER_DD:-/tmp/dd-$WORKSPACE_NAME}"
mkdir -p "$DERIVED_DATA"

echo "▶︎ 共享 SPM 缓存：$SHARED_SPM"
echo "▶︎ DerivedData：$DERIVED_DATA"
echo "▶︎ 命令：xcodebuild $*"

exec xcodebuild \
  -clonedSourcePackagesDirPath "$SHARED_SPM" \
  -derivedDataPath "$DERIVED_DATA" \
  "$@"

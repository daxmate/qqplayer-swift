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
#   QQPLAYER_DD       覆盖 DerivedData 路径（默认 /tmp/dd-<worktree 目录名>，按工作区隔离防互踩）
#   QQPLAYER_NO_LOCK  置 1 跳过构建锁（仅在确知无并发构建时用）
#
# 构建锁（2026-09-13 立，血的教训）：
#   两个 worktree 同时构建时，SPM 会对**同一份共享 clone 缓存**做并发解析——
#   实测会把 repositories/<pkg> 镜像清空并重新 `git clone --mirror`（日志特征
#   `skipping cache due to an error: ... already exists unexpectedly`），慢网络下
#   克隆挂死、构建 CPU 归零、缓存处于半残状态（当日两次踩坑，含子代理构建）。
#   DerivedData 会话名隔离挡不住这个（踩的是共享 clone 缓存）→ 这里用目录锁把**所有**
#   走本入口的构建全局串行化；后到者排队等待，超时/陈旧锁自动清理。
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

# ---- 构建锁（全局串行；mkdir 原子性做锁，macOS 无 flock）----
LOCK_DIR="/tmp/qqplayer-xcbuild.lock"
if [ "${QQPLAYER_NO_LOCK:-0}" != "1" ]; then
  waited=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    lock_age=0
    if [ -d "$LOCK_DIR" ]; then
      lock_mtime="$(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)"
      lock_age=$(( $(date +%s) - lock_mtime ))
    fi
    if [ "$lock_age" -gt 1800 ]; then
      echo "⚠️  构建锁超过 30 分钟未释放（疑似中断残留），强制清理：$LOCK_DIR"
      rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
      continue
    fi
    if [ "$waited" -ge 2400 ]; then
      echo "❌ 等待构建锁超时（40 分钟）：$LOCK_DIR（如确无并发构建，用 QQPLAYER_NO_LOCK=1 绕过）" >&2
      exit 3
    fi
    [ $(( waited % 60 )) -eq 0 ] && echo "⏳ 其他构建进行中，排队等待（已等 ${waited}s）…"
    sleep 5
    waited=$((waited + 5))
  done
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true; exit 130' INT TERM
fi

echo "▶︎ 共享 SPM 缓存：$SHARED_SPM"
echo "▶︎ DerivedData：$DERIVED_DATA"
echo "▶︎ 命令：xcodebuild $*"

# ⚠️ 不能用 exec：exec 会替换 shell 进程 → EXIT trap 不执行 → 锁永不释放
# （2026-09-13 实测：冒烟测试后 /tmp/qqplayer-xcbuild.lock 残留）。
xcodebuild \
  -clonedSourcePackagesDirPath "$SHARED_SPM" \
  -derivedDataPath "$DERIVED_DATA" \
  "$@"

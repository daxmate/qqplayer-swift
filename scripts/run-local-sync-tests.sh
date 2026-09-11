#!/usr/bin/env bash
# run-local-sync-tests.sh — M3-3b 无模拟器本地 harness
#
# 为什么存在：iOS 单测走 xcodebuild + 模拟器（CI 兜底），而"不许启模拟器"的纪律下
# 本地无法真跑 QQPlayerTests。本脚本用 swiftc 直编**生产源码**（QQPlayer/Sync/* 纯
# 逻辑 + MusicDirectoryScanner + aligned 歌词库）+ scripts/sync-harness 的夹具，真跑与
# 测试套件同构的断言（帧编解码/路径解析/应答器计划/控制器状态机与对账/三条端到端场景：
# 拉取一致、远端已删不传播、越界拒绝 + M4-2b 歌词库与随歌同步）。
#
# R1b-2 起：发起方恒为 Mac（SyncLibraryPushController / SyncLibraryPullController），
# 旧 iOS 主动拉取控制器（SyncLibrarySyncController）已退役。
#
# 覆盖不到的（由 CI 的 xcodebuild test 兜底）：Swift Testing 套件本体、iOS/Mac
# target 的特有代码路径（LibraryIndexer 真实现、MacSyncLibraryHost 装配）。
#
# 用法：scripts/run-local-sync-tests.sh [--verbose]
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

OUT_DIR="${TMPDIR:-/tmp}/qqp-sync-harness-build"
mkdir -p "$OUT_DIR"
BIN="$OUT_DIR/sync-harness"

SOURCES=(
  QQPlayer/Sync/SyncFrame.swift
  QQPlayer/Sync/SyncCrypto.swift
  QQPlayer/Sync/SyncIdentity.swift
  QQPlayer/Sync/DeviceID.swift
  QQPlayer/Sync/PairingModels.swift
  QQPlayer/Sync/PairingStateMachine.swift
  QQPlayer/Sync/SyncSessionModels.swift
  QQPlayer/Sync/SyncPeerSession.swift
  QQPlayer/Sync/SyncPeerSession+Frames.swift
  QQPlayer/Sync/SyncFileChecksum.swift
  QQPlayer/Sync/SyncFileTransferModels.swift
  QQPlayer/Sync/SyncFileSender.swift
  QQPlayer/Sync/SyncFileReceiver.swift
  QQPlayer/Sync/SyncManifest.swift
  QQPlayer/Sync/SyncManifestGenerator.swift
  QQPlayer/Sync/SyncManifestReconciler.swift
  QQPlayer/Sync/SyncManifestPeer.swift
  QQPlayer/Sync/SyncCollection.swift
  QQPlayer/Sync/SyncCollectionSelection.swift
  QQPlayer/Sync/SyncCollectionSyncCoordinator.swift
  # R3b「跟歌走」计划器：纯逻辑（不依赖 GRDB），随编排一起真跑。
  QQPlayer/Sync/SyncPlaybackCarryPlan.swift
  QQPlayer/Sync/SyncLibrarySyncModels.swift
  QQPlayer/Sync/SyncLibraryFetchResponder.swift
  QQPlayer/Sync/SyncLocalLibraryProvider.swift
  QQPlayer/Sync/SyncLibraryPushModels.swift
  QQPlayer/Sync/SyncLibrarySink.swift
  QQPlayer/Sync/SyncLibraryPushController.swift
  QQPlayer/Sync/SyncLibraryPullController.swift
  QQPlayer/Sync/SyncLyricsReceiver.swift
  QQPlayer/Sync/SyncLibraryPassiveHost.swift
  QQPlayer/Sync/SyncLocalLibraryScanner.swift
  QQPlayer/Sync/SyncAlignedLyrics.swift
  QQPlayer/Services/LyricsModels.swift
  QQPlayer/Services/AlignedLyricsStore.swift
  # v2 §12b-7「删除不跨端传播」单一事实源：纯 op 字符串判定，无 GRDB 依赖，
  # 可直接进无模拟器 harness（真跑断言）。
  QQPlayer/Sync/SyncChangeLogDeletionPolicy.swift
  QQPlayer/Services/MusicDirectoryScanner.swift
  scripts/sync-harness/Stubs.swift
  scripts/sync-harness/HarnessSupport.swift
  scripts/sync-harness/main.swift
)

echo "▶︎ 编译 GRDB 模块桩（生产源码 PairingModels 仅用到两个 Record 协议）"
swiftc -swift-version 5 -emit-module -emit-library -module-name GRDB \
  -emit-module-path "$OUT_DIR/GRDB.swiftmodule" -o "$OUT_DIR/libGRDB.dylib" \
  scripts/sync-harness/GRDBShim.swift 2>&1 | tee "$OUT_DIR/shim.log"
shim_status="${PIPESTATUS[0]}"
if [ "$shim_status" -ne 0 ]; then
  echo "❌ GRDB 模块桩编译失败（详见 $OUT_DIR/shim.log）"
  exit 1
fi

echo "▶︎ swiftc 编译 harness（生产源码 $((${#SOURCES[@]} - 3)) 个 + 夹具 3 个）"
swiftc -swift-version 5 -I "$OUT_DIR" -L "$OUT_DIR" -lGRDB -o "$BIN" "${SOURCES[@]}" 2>&1 | tee "$OUT_DIR/compile.log"
compile_status="${PIPESTATUS[0]}"
if [ "$compile_status" -ne 0 ]; then
  echo "❌ harness 编译失败（详见 $OUT_DIR/compile.log）"
  exit 1
fi
echo "✅ harness 编译通过 → $BIN"

echo "▶︎ 运行 harness"
DYLD_LIBRARY_PATH="$OUT_DIR" "$BIN"

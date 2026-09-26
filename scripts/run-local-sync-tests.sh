#!/usr/bin/env bash
# run-local-sync-tests.sh — M3-3b 无模拟器本地 harness
#
# 为什么存在：iOS 单测走 xcodebuild + 模拟器（CI 兜底），而"不许启模拟器"的纪律下
# 本地无法真跑 QQPlayerTests。本脚本用 swiftc 直编**生产源码**（QQPlayer/Sync/* 纯
# 逻辑 + 自动补入的 Services/Models 依赖 + aligned 歌词库）+ scripts/sync-harness 的
# 夹具，真跑与测试套件同构的断言（帧编解码/路径解析/应答器计划/控制器状态机与对账/
# 四条端到端场景：拉取一致、远端已删不传播、越界拒绝 + M4-2b 歌词库与随歌同步）。
#
# R1b-2 起：发起方恒为 Mac（SyncLibraryPushController / SyncLibraryPullController），
# 旧 iOS 主动拉取控制器（SyncLibrarySyncController）已退役。
#
# 覆盖不到的（由 CI 的 xcodebuild test 兜底）：Swift Testing 套件本体、iOS/Mac
# target 的特有代码路径（LibraryIndexer 真实现、MacSyncLibraryHost 装配）。
#
# ★ 编译集是「自动发现 + 自动补闭包」，不再手工枚举（2026-09-26）：
#   手工清单必然逐批腐烂（2026-09-21 E 拆分批后只收 Sync/ 的 42/68 个文件 ⇒ harness
#   在基线上就编不过，而它又不在 CI 里，红了没人知道）。现在：
#     起点 = QQPlayer/Sync/*.swift 全收（减黑名单）+ 三个夹具
#     迭代 = swiftc 报 cannot find '<X>' in scope → 在 QQPlayer/{Sync,Services,Models}
#            定位 X 的声明文件 → 全部候选一起加入（同名不猜）→ 重编 → 直到编译通过
#     终点 = 无解即 exit 1 点名（绝不静默降级 / 绝不悄悄漏文件）
#   实现在 scripts/sync-harness/closure_resolver.py（按内容哈希缓存，--refresh 重算）；
#   黑名单 scripts/sync-harness/blacklist.txt 只放「确实编不进命令行」的文件，
#   且自带两道守卫（路径存在 / 声明的符号仍被黑名单外的生产代码引用）。
#
# T12（2026-09-14）：`SyncBrowseSource.swift` 依赖的 `SmartPlaylistKind` 走 harness 同形桩
# （生产宿主 SmartPlaylistStore 是 GRDB-SQL 重依赖，无法命令行直编）——编译前先跑桩/生产
# 声明一致性守卫，防「生产新增 case」这类编译期看不见的漂移。
#
# 用法：scripts/run-local-sync-tests.sh [--verbose] [--refresh]
#   --verbose  打印闭包解析每轮细节
#   --refresh  忽略闭包缓存，强制重算编译集
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

VERBOSE=0
REFRESH=0
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=1 ;;
    --refresh) REFRESH=1 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "❌ 未知参数：$arg（仅支持 --verbose / --refresh）"; exit 2 ;;
  esac
done

OUT_DIR="${TMPDIR:-/tmp}/qqp-sync-harness-build"
mkdir -p "$OUT_DIR"
BIN="$OUT_DIR/sync-harness"

# ── 漂移守卫：SmartPlaylistKind（生产 vs harness 桩）──────────────────────────
# `SyncBrowseSource.swift`（T11「来源挑歌」）依赖 `SmartPlaylistKind`，而它的生产宿主
# `Services/SmartPlaylistStore.swift` 是 GRDB-SQL 重依赖、无法命令行直编，故本 harness
# 用同形桩（scripts/sync-harness/Stubs.swift）替代。桩与生产必须逐字同形，否则
# 「生产新增 case」这类漂移编译期看不见。守卫失败即退出，不静默降级。
extract_smart_playlist_kind() {
  awk '/^enum SmartPlaylistKind: /{ found = 1; print; next }
       found && /^    case /{ print; exit }' "$1"
}
prod_kind="$(extract_smart_playlist_kind QQPlayer/Services/SmartPlaylistStore.swift)"
stub_kind="$(extract_smart_playlist_kind scripts/sync-harness/Stubs.swift)"
if [ -z "$prod_kind" ] || [ -z "$stub_kind" ]; then
  echo "❌ 漂移守卫无法定位 SmartPlaylistKind 声明（生产或桩被改写了？）"
  echo "   生产：QQPlayer/Services/SmartPlaylistStore.swift → '$prod_kind'"
  echo "   桩  ：scripts/sync-harness/Stubs.swift → '$stub_kind'"
  exit 1
fi
if [ "$prod_kind" != "$stub_kind" ]; then
  echo "❌ SmartPlaylistKind 桩已漂移（桩 = scripts/sync-harness/Stubs.swift）"
  echo "   生产：$prod_kind"
  echo "   桩  ：$stub_kind"
  echo "   → 把桩改成与生产逐字同形（case 名 / 顺序 / rawValue / 协议）再重跑。"
  exit 1
fi
echo "✅ 漂移守卫通过：SmartPlaylistKind 桩与生产声明一致"

echo "▶︎ 编译 GRDB 模块桩（生产源码 PairingModels 仅用到两个 Record 协议）"
swiftc -swift-version 5 -emit-module -emit-library -module-name GRDB \
  -emit-module-path "$OUT_DIR/GRDB.swiftmodule" -o "$OUT_DIR/libGRDB.dylib" \
  scripts/sync-harness/GRDBShim.swift 2>&1 | tee "$OUT_DIR/shim.log"
shim_status="${PIPESTATUS[0]}"
if [ "$shim_status" -ne 0 ]; then
  echo "❌ GRDB 模块桩编译失败（详见 $OUT_DIR/shim.log）"
  exit 1
fi

# ── 编译集：自动发现 + 依赖闭包（不再手工枚举）───────────────────────────────
echo "▶︎ 解析编译闭包（自动发现 QQPlayer/Sync/*.swift + 依赖闭包 − 黑名单）"
CLOSURE_ARGS=(--root . --build-dir "$OUT_DIR" --blacklist scripts/sync-harness/blacklist.txt)
[ "$VERBOSE" -eq 1 ] && CLOSURE_ARGS+=(--verbose)
[ "$REFRESH" -eq 1 ] && CLOSURE_ARGS+=(--refresh)
SOURCES_FILE="$OUT_DIR/sources.txt"
if ! python3 scripts/sync-harness/closure_resolver.py "${CLOSURE_ARGS[@]}" > "$SOURCES_FILE"; then
  echo "❌ 编译闭包解析失败（见上方点名信息；编译集 = 自动发现，禁止手工改回清单）"
  exit 1
fi
SOURCES=()
while IFS= read -r line; do
  [ -n "$line" ] && SOURCES+=("$line")
done < "$SOURCES_FILE"
if [ "${#SOURCES[@]}" -eq 0 ]; then
  echo "❌ 闭包解析返回空编译集（$SOURCES_FILE）"
  exit 1
fi
FIXTURE_COUNT=0
for file in "${SOURCES[@]}"; do
  case "$file" in scripts/sync-harness/*) FIXTURE_COUNT=$((FIXTURE_COUNT + 1)) ;; esac
done
PROD_COUNT=$((${#SOURCES[@]} - FIXTURE_COUNT))

echo "▶︎ swiftc 编译 harness（生产源码 $PROD_COUNT 个 + 夹具 $FIXTURE_COUNT 个）"
swiftc -swift-version 5 -I "$OUT_DIR" -L "$OUT_DIR" -lGRDB -o "$BIN" "${SOURCES[@]}" 2>&1 | tee "$OUT_DIR/compile.log"
compile_status="${PIPESTATUS[0]}"
if [ "$compile_status" -ne 0 ]; then
  echo "❌ harness 编译失败（详见 $OUT_DIR/compile.log）"
  exit 1
fi
echo "✅ harness 编译通过 → $BIN"

echo "▶︎ 运行 harness"
DYLD_LIBRARY_PATH="$OUT_DIR" "$BIN"

#!/usr/bin/env bash
# run-mac-window-chrome-tests.sh — macOS 窗口 chrome / 工具栏玻璃的无模拟器断言 harness
#
# 为什么存在（2026-11-23 血例）：macOS 整窗玻璃连踩三个只能靠肉眼发现的回归——
#   ① 侧栏被系统 Liquid Glass（NSGlassEffectView）包住 → 米白面板；
#   ② 为去掉它而「换列」→ 丢 .sidebar behavior → 工具栏右侧分区垮掉，4 个按钮跑到中间；
#   ③ 胶囊/白圆底在冷启动后残留（sharedBackgroundVisibility 只改数据，不重排 item viewer）。
# 本脚本把这些变成自动断言，用户不必再当人肉回归测试机。
#
# 做法：用 swiftc **直编生产源码**（QQPlayer/Mac/MacWindowGlass.swift 与
# MacWindowGlassChrome.swift，**不复制**实现） + scripts/mac-chrome-harness 的夹具，
# 在真实 AppKit 窗口里真跑断言（侧栏可见 glass 数 / 侧栏内容 frame / split item behavior /
# toolbar platter 数 / toggle isBordered / 4 按钮贴右 / 标题不被挤掉 / 10 轮翻转 / 冷启动）。
#
# 覆盖不到的（刻意留白）：
#   - 真机视觉（颜色 / 材质 / 圆角）——harness 只做视图树与几何断言；
#   - SwiftUI `.sharedBackgroundVisibility` 的数据面 → 由
#     QQPlayerTests/MacWindowChromeShapeContractTests.swift 的文本契约锁；
#   - macOS 26 以下的 Liquid Glass 摘除 → 自动 SKIP 并打印，legacy 材质 / chrome / 工具栏用例照跑。
#
# 用法：scripts/run-mac-window-chrome-tests.sh [--verbose]
# 退出码：0 = 全部断言通过；1 = 有失败或编译失败；2 = 参数错误。

set -uo pipefail

cd "$(dirname "$0")/.." || { echo "❌ 无法进入仓库根"; exit 2; }

VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=1 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "❌ 未知参数：${arg}（仅支持 --verbose）"; exit 2 ;;
  esac
done

OUT_DIR="${TMPDIR:-/tmp}/qqp-mac-chrome-harness"
mkdir -p "$OUT_DIR" || { echo "❌ 无法创建构建目录 $OUT_DIR"; exit 1; }

PROD_SOURCES=(
  "QQPlayer/Mac/MacWindowGlass.swift"
  "QQPlayer/Mac/MacWindowGlassChrome.swift"
)
FIXTURE_SOURCES=(
  "scripts/mac-chrome-harness/Stubs.swift"
  "scripts/mac-chrome-harness/HarnessSupport.swift"
  "scripts/mac-chrome-harness/main.swift"
)

for source in "${PROD_SOURCES[@]}" "${FIXTURE_SOURCES[@]}"; do
  if [ ! -f "$source" ]; then
    echo "❌ 缺少源文件：$source（fail-closed，不静默跳过）"
    exit 1
  fi
done

echo "▶︎ swiftc 编译 harness（生产源码 ${#PROD_SOURCES[@]} 个 + 夹具 ${#FIXTURE_SOURCES[@]} 个）"
swiftc -swift-version 5 -Onone -o "$OUT_DIR/mac-chrome-harness" \
  "${PROD_SOURCES[@]}" "${FIXTURE_SOURCES[@]}" 2>&1 | tee "$OUT_DIR/compile.log"
compile_status="${PIPESTATUS[0]}"
if [ "$compile_status" -ne 0 ]; then
  echo "❌ harness 编译失败（详见 $OUT_DIR/compile.log）"
  exit 1
fi
[ "$VERBOSE" -eq 1 ] && echo "✅ harness 编译通过 → $OUT_DIR/mac-chrome-harness"

echo "▶︎ 运行 harness"
"$OUT_DIR/mac-chrome-harness"
exit $?

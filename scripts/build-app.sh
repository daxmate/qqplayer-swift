#!/usr/bin/env bash
#
# build-app.sh — QQPlayer 统一 app 构建入口（契约 v1）
#
# 用法:
#   ./scripts/build-app.sh [all|ios|macos] [--release] [--open] [--help]
#
#   all（默认）  构建 iOS + macOS 两端
#   ios          仅构建 iOS（generic 模拟器目标，免签名，不启动模拟器）
#   macos        仅构建 macOS
#   --release    使用 Release 配置（默认 Debug）
#   --open       构建后打开 QQPlayer.xcodeproj
#   --help       打印本用法
#
# 底层仍走 scripts/xcbuild.sh（共享 SPM 缓存 + 按工作区隔离的 DerivedData + 构建锁）。
# xcbuild.sh / build.sh 保留原用法：前者是底层 xcodebuild 包装（测试也用它），
# 后者额外提供真机安装。本脚本只做统一入口，不复制它们的逻辑，不启动模拟器、
# 不做截图 / UI 自动化。
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="QQPlayer.xcodeproj"
IOS_SCHEME="QQPlayer"
MAC_SCHEME="QQPlayerMac"
IOS_DEST="generic/platform=iOS Simulator"
MAC_DEST="platform=macOS"
APP_NAME="QQPlayer"

CONFIG="Debug"
TARGET="all"
OPEN_AFTER=0

usage() {
  cat <<'EOF'
用法: ./scripts/build-app.sh [all|ios|macos] [--release] [--open] [--help]

  all（默认）  构建 iOS + macOS 两端
  ios          仅构建 iOS（generic 模拟器，免签名，不启动模拟器）
  macos        仅构建 macOS
  --release    使用 Release 配置（默认 Debug）
  --open       构建后打开 QQPlayer.xcodeproj
  --help       打印本用法

底层脚本：scripts/xcbuild.sh（共享 SPM 缓存 / 隔离 DerivedData / 构建锁）
环境变量：QQPLAYER_DD 可覆盖 DerivedData 路径（默认 /tmp/dd-<工作区名>）
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    all|ios|macos) TARGET="$1" ;;
    --release) CONFIG="Release" ;;
    --open) OPEN_AFTER=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "❌ 未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# iOS/macOS 构建必须用 Xcode 自带工具链；环境里的 Homebrew gcc（CC/CXX）会劫持
# SPM 的 C/C++ 依赖编译（与 build.sh 一致）
unset CC CXX 2>/dev/null || true

# 与 scripts/xcbuild.sh 的推导保持一致，仅用于打印产物路径
WORKSPACE_NAME="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
DERIVED="${QQPLAYER_DD:-/tmp/dd-$WORKSPACE_NAME}"

expect_app() { # $1=平台标签 $2=期望路径
  if [ -d "$2" ]; then
    echo "✅ $1 产物：$2"
  else
    echo "❌ 未找到 $1 产物：$2" >&2
    echo "   Build/Products 下的 .app：" >&2
    find "$DERIVED/Build/Products" -maxdepth 2 -type d -name '*.app' >&2 2>/dev/null || true
    return 1
  fi
}

build_ios() {
  echo "=== 构建 iOS（scheme ${IOS_SCHEME} / ${CONFIG}）==="
  scripts/xcbuild.sh build -project "$PROJECT" -scheme "$IOS_SCHEME" \
    -sdk iphonesimulator -destination "$IOS_DEST" \
    -configuration "$CONFIG" CODE_SIGNING_ALLOWED=NO
  expect_app "iOS" "$DERIVED/Build/Products/$CONFIG-iphonesimulator/$APP_NAME.app"
}

build_macos() {
  echo "=== 构建 macOS（scheme ${MAC_SCHEME} / ${CONFIG}）==="
  scripts/xcbuild.sh build -project "$PROJECT" -scheme "$MAC_SCHEME" \
    -destination "$MAC_DEST" \
    -configuration "$CONFIG" CODE_SIGNING_ALLOWED=NO
  expect_app "macOS" "$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
}

echo "▶︎ 目标：$TARGET　配置：$CONFIG　DerivedData：$DERIVED"

case "$TARGET" in
  all) build_ios; build_macos ;;
  ios) build_ios ;;
  macos) build_macos ;;
esac

if [ "$OPEN_AFTER" -eq 1 ]; then
  echo "▶︎ 打开 $PROJECT"
  open "$PROJECT"
fi

echo "🎉 构建完成（$TARGET / $CONFIG）"

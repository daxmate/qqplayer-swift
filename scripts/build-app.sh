#!/usr/bin/env bash
#
# build-app.sh — QQPlayer 统一 app 构建入口（契约 v1）
#
# 用法:
#   ./scripts/build-app.sh [all|ios|macos] [--release] [--arch <native|arm64|x86_64|universal>] [--open] [--help]
#
#   all（默认）  构建 iOS + macOS 两端
#   ios          仅构建 iOS（generic 模拟器目标，免签名，不启动模拟器）
#   macos        仅构建 macOS
#   --release    使用 Release 配置（默认 Debug）
#   --arch AR    指定 macOS 产物的 CPU 架构（默认 native）
#                native    本机架构，行为与旧版完全一致（不追加 ARCHS 参数）
#                arm64     纯 arm64
#                x86_64    纯 Intel（Apple Silicon 上可经 Rosetta 运行）
#                universal arm64 + x86_64 通用二进制
#                只作用于 macOS；目标含 iOS 时 iOS 侧忽略并打印提示。
#                非 native 会覆盖工程里的 ONLY_ACTIVE_ARCH=YES，并把默认 DerivedData
#                路径追加 -<arch> 后缀（显式设置 QQPLAYER_DD 时尊用户值、不加后缀）。
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
ARCH="native"
OPEN_AFTER=0

usage() {
  cat <<'EOF'
用法: ./scripts/build-app.sh [all|ios|macos] [--release] [--arch <native|arm64|x86_64|universal>] [--open] [--help]

  all（默认）  构建 iOS + macOS 两端
  ios          仅构建 iOS（generic 模拟器，免签名，不启动模拟器）
  macos        仅构建 macOS
  --release    使用 Release 配置（默认 Debug）
  --arch AR    指定 macOS 产物 CPU 架构（默认 native = 本机架构，与旧版行为一致）
               native | arm64 | x86_64 | universal；iOS 侧忽略（目标含 iOS 时会提示）
               非 native 使用独立 DerivedData：<工作树根>/build/DerivedData-<arch>
  --open       构建后打开 QQPlayer.xcodeproj
  --help       打印本用法

底层脚本：scripts/xcbuild.sh（共享 SPM 缓存 / 隔离 DerivedData / 构建锁）
环境变量：QQPLAYER_DD 可覆盖 DerivedData 路径（默认 <工作树根>/build/DerivedData）
          QQPLAYER_BUILD_DIR 可覆盖统一产物根目录（默认 <工作树根>/build）
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    all|ios|macos) TARGET="$1" ;;
    --release) CONFIG="Release" ;;
    --arch)
      if [ $# -lt 2 ]; then
        echo "❌ --arch 缺少取值（native|arm64|x86_64|universal）" >&2
        exit 2
      fi
      ARCH="$2"
      shift
      ;;
    --arch=*) ARCH="${1#--arch=}" ;;
    --open) OPEN_AFTER=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "❌ 未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$ARCH" in
  native|arm64|x86_64|universal) ;;
  *)
    echo "❌ 无效的 --arch：${ARCH}（可选 native|arm64|x86_64|universal）" >&2
    exit 2
    ;;
esac

# macOS 目标：非 native 时令 destination 也带上期望架构（实测 platform=macOS 亦可，
# 但带 arch 能避免 Xcode 把 destination 选成本机架构）。
case "$ARCH" in
  x86_64) MAC_DEST="platform=macOS,arch=x86_64" ;;
  arm64) MAC_DEST="platform=macOS,arch=arm64" ;;
  *) MAC_DEST="platform=macOS" ;;
esac

# iOS/macOS 构建必须用 Xcode 自带工具链；环境里的 Homebrew gcc（CC/CXX）会劫持
# SPM 的 C/C++ 依赖编译（与 build.sh 一致）
unset CC CXX 2>/dev/null || true

# 统一产物根：<工作树根>/build（与 scripts/xcbuild.sh 的推导保持一致）
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
BUILD_DIR="${QQPLAYER_BUILD_DIR:-$ROOT/build}"
DERIVED="${QQPLAYER_DD:-$BUILD_DIR/DerivedData}"

# 非 native 构建与原生构建使用不同 DerivedData，避免产物互相覆盖。
# 用户显式设置 QQPLAYER_DD 时尊重其值（不加后缀），并透传给 xcbuild.sh。
if [ "$ARCH" != "native" ] && [ -z "${QQPLAYER_DD:-}" ]; then
  DERIVED="${DERIVED}-${ARCH}"
  export QQPLAYER_DD="$DERIVED"
fi

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

# 成品汇总：复制到 <build>/Products/<sdk>/<Config>/（ditto 保留签名/扩展属性）
publish_product() { # $1=sdk 目录名 $2=源 .app $3=平台标签
  local dest="$BUILD_DIR/Products/$1/$CONFIG/$(basename "$2")"
  mkdir -p "$(dirname "$dest")"
  ditto "$2" "$dest"
  echo "✅ $3 成品：$dest"
}

# 校验 macOS 产物架构；不匹配必须非零退出（expect_app 只看目录是否存在）。
verify_macos_arch() { # $1=.app 路径
  local bin="$1/Contents/MacOS/$APP_NAME"
  if [ ! -f "$bin" ]; then
    echo "❌ 找不到 macOS 可执行文件：${bin}" >&2
    return 1
  fi
  local actual
  actual="$(lipo -archs "$bin" 2>/dev/null || true)"
  echo "ℹ️  macOS 产物架构：${actual:-未知}"
  case "$ARCH" in
    native) return 0 ;;
    x86_64)
      if [ "$actual" != "x86_64" ]; then
        echo "❌ 期望纯 x86_64，实际：${actual:-未知}" >&2
        return 1
      fi
      ;;
    arm64)
      if [ "$actual" != "arm64" ]; then
        echo "❌ 期望纯 arm64，实际：${actual:-未知}" >&2
        return 1
      fi
      ;;
    universal)
      case " $actual " in
        *" arm64 "*) ;;
        *) echo "❌ universal 产物缺少 arm64，实际：${actual:-未知}" >&2; return 1 ;;
      esac
      case " $actual " in
        *" x86_64 "*) ;;
        *) echo "❌ universal 产物缺少 x86_64，实际：${actual:-未知}" >&2; return 1 ;;
      esac
      ;;
  esac
}

build_ios() {
  if [ "$ARCH" != "native" ]; then
    echo "ℹ️  --arch ${ARCH} 仅作用于 macOS，iOS 侧按默认架构构建（忽略该参数）"
  fi
  echo "=== 构建 iOS（scheme ${IOS_SCHEME} / ${CONFIG}）==="
  scripts/xcbuild.sh build -project "$PROJECT" -scheme "$IOS_SCHEME" \
    -sdk iphonesimulator -destination "$IOS_DEST" \
    -configuration "$CONFIG" CODE_SIGNING_ALLOWED=NO
  expect_app "iOS" "$DERIVED/Build/Products/$CONFIG-iphonesimulator/$APP_NAME.app"
  publish_product iphonesimulator "$DERIVED/Build/Products/$CONFIG-iphonesimulator/$APP_NAME.app" "iOS"
}

build_macos() {
  echo "=== 构建 macOS（scheme ${MAC_SCHEME} / ${CONFIG} / arch ${ARCH}）==="
  local archs=""
  case "$ARCH" in
    arm64) archs="arm64" ;;
    x86_64) archs="x86_64" ;;
    universal) archs="arm64 x86_64" ;;
  esac
  if [ -n "$archs" ]; then
    echo "ℹ️  覆盖构建设置：ARCHS=${archs} ONLY_ACTIVE_ARCH=NO"
    scripts/xcbuild.sh build -project "$PROJECT" -scheme "$MAC_SCHEME" \
      -destination "$MAC_DEST" \
      -configuration "$CONFIG" \
      ARCHS="$archs" ONLY_ACTIVE_ARCH=NO
  else
    scripts/xcbuild.sh build -project "$PROJECT" -scheme "$MAC_SCHEME" \
      -destination "$MAC_DEST" \
      -configuration "$CONFIG"
  fi
  expect_app "macOS" "$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
  verify_macos_arch "$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
  publish_product macosx "$DERIVED/Build/Products/$CONFIG/$APP_NAME.app" "macOS"
}

echo "▶︎ 目标：${TARGET}　配置：${CONFIG}　macOS 架构：${ARCH}　DerivedData：${DERIVED}"

case "$TARGET" in
  all) build_ios; build_macos ;;
  ios) build_ios ;;
  macos) build_macos ;;
esac

if [ "$OPEN_AFTER" -eq 1 ]; then
  echo "▶︎ 打开 $PROJECT"
  open "$PROJECT"
fi

echo "🎉 构建完成（$TARGET / ${CONFIG} / macOS 架构 ${ARCH}）"

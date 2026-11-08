#!/usr/bin/env bash
#
# build-app.sh — QQPlayer 统一 app 构建入口（契约 v2）
#
# 用法:
#   ./scripts/build-app.sh [all|ios|macos] [--release] [--arch <native|arm64|x86_64|universal>] [--install] [--open] [--help]
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
#   --install    构建后安装：macOS 覆盖安装到 $QQPLAYER_MAC_INSTALL_DIR/QQPlayer.app 并启动；
#                iOS 真机签名构建 + devicectl 安装 + 启动。双端互不阻断（先 macOS 后 iOS），
#                任一环节失败退出码非 0。不加此参数时只构建、不安装、不启动。
#   --open       构建后打开 QQPlayer.xcodeproj
#   --help       打印本用法
#
# 底层仍走 scripts/xcbuild.sh（共享 SPM 缓存 + 按工作区隔离的 DerivedData + 构建锁）。
# xcbuild.sh 是底层 xcodebuild 包装（测试也用它），本脚本只做统一入口，不复制其逻辑，
# 不启动模拟器、不做截图 / UI 自动化。
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="QQPlayer.xcodeproj"
IOS_SCHEME="QQPlayer"
MAC_SCHEME="QQPlayerMac"
IOS_DEST="generic/platform=iOS Simulator"
MAC_DEST="platform=macOS"
APP_NAME="QQPlayer"
MAC_APP_NAME="QQPlayer"                     # macOS 产物名（用户可见名统一为 QQPlayer）
IOS_BUNDLE_ID="com.daxmate.qqplayer.ios"
MAC_INSTALL_DIR="${QQPLAYER_MAC_INSTALL_DIR:-/Applications}"

CONFIG="Debug"
TARGET="all"
ARCH="native"
OPEN_AFTER=0
INSTALL_AFTER=0

usage() {
  cat <<'EOF'
用法: ./scripts/build-app.sh [all|ios|macos] [--release] [--arch <native|arm64|x86_64|universal>] [--install] [--open] [--help]

  all（默认）  构建 iOS + macOS 两端
  ios          仅构建 iOS（generic 模拟器，免签名，不启动模拟器）
  macos        仅构建 macOS
  --release    使用 Release 配置（默认 Debug）
  --arch AR    指定 macOS 产物 CPU 架构（默认 native = 本机架构，与旧版行为一致）
               native | arm64 | x86_64 | universal；iOS 侧忽略（目标含 iOS 时会提示）
               非 native 使用独立 DerivedData：<工作树根>/build/DerivedData-<arch>
  --install    构建后安装（macOS → 覆盖安装到安装目录并启动；iOS → 真机签名构建 + 安装 + 启动）
               不加 --install 时只构建、不安装、不启动
  --open       构建后打开 QQPlayer.xcodeproj
  --help       打印本用法

底层脚本：scripts/xcbuild.sh（共享 SPM 缓存 / 隔离 DerivedData / 构建锁）
环境变量：QQPLAYER_DD 可覆盖 DerivedData 路径（默认 <工作树根>/build/DerivedData）
          QQPLAYER_BUILD_DIR 可覆盖统一产物根目录（默认 <工作树根>/build）
          QQPLAYER_MAC_INSTALL_DIR 可覆盖 macOS 安装目录（默认 /Applications）
          QQPLAYER_SKIP_LAUNCH=1 跳过安装后的 macOS 启动
          QQPLAYER_IOS_UDID 指定 iOS 真机 UDID（默认自动探测）
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
    --install) INSTALL_AFTER=1 ;;
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
# SPM 的 C/C++ 依赖编译（构建链路统一清掉）
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

# ---- 安装（--install） ------------------------------------------------------
# 说明：安装能力已并入本脚本（契约 v2）。macOS / iOS 两端互不阻断，
# 失败只置标志位、跑完另一端后统一以非 0 退出。

# 探测可用真机（devicectl JSON → scripts/detect-device.py 选设备；判据与理由见该脚本注释）。
# 注意：**不要**只认 tunnelState=connected —— 隧道是按需建立的，可达设备也会报 disconnected，
# 那样会误报「未发现真机」（2026-09-20 事故）。选择逻辑有自测：scripts/detect-device-test.py
detect_udid() {
  local OUT="/tmp/qqplayer-devices.json"
  xcrun devicectl list devices --json-output "${OUT}" >/dev/null 2>&1 || return 1
  python3 scripts/detect-device.py --explain "${OUT}"
}

# 无真机时的排查提示（文案与旧一键脚本一致）
device_hint() {
  echo "   排查：① iPhone 用数据线连本机并在「访达 → 设备」里信任此 Mac"
  echo "         ② iPhone：设置 → 隐私与安全性 → 开发者模式 = 开"
  echo "         ③ 同一 Wi-Fi 下也可用（无需数据线），但设备不能关机"
}

# macOS 覆盖安装：退出旧实例 → 旧 bundle 移到 /tmp（可恢复）→ ditto 拷贝 → 启动
install_mac_app() { # $1=源 .app 路径
  local SRC="$1"
  local DEST="${MAC_INSTALL_DIR}/${MAC_APP_NAME}.app"
  echo "=== 安装 macOS App → ${DEST} ==="
  # 1) 退出运行中的实例（允许失败继续）
  pkill -x "${MAC_APP_NAME}" 2>/dev/null || true
  osascript -e "quit app \"${MAC_APP_NAME}\"" >/dev/null 2>&1 || true
  sleep 1
  # 2) 非破坏性替换：旧 bundle 移到 /tmp（可恢复胜过永久消失，不 rm -rf）
  if [ -e "${DEST}" ]; then
    local OLD="/tmp/${MAC_APP_NAME}-old-$(date +%Y%m%d-%H%M%S).app"
    mv "${DEST}" "${OLD}" || { echo "❌ 无法移走旧 App：${DEST}"; return 1; }
    echo "ℹ️  旧版本已移至：${OLD}（可恢复；确认新版本可用后可自行删除）"
  fi
  # 3) 拷贝新 bundle
  mkdir -p "${MAC_INSTALL_DIR}" || { echo "❌ 无法创建安装目录：${MAC_INSTALL_DIR}"; return 1; }
  ditto "${SRC}" "${DEST}" || { echo "❌ ditto 拷贝失败：${SRC} → ${DEST}"; return 1; }
  echo "✅ 已安装：${DEST}"
  # 4) 启动（QQPLAYER_SKIP_LAUNCH=1 时跳过）
  if [ "${QQPLAYER_SKIP_LAUNCH:-0}" = "1" ]; then
    echo "ℹ️  QQPLAYER_SKIP_LAUNCH=1 —— 跳过启动"
  else
    open "${DEST}" || { echo "❌ 启动失败：${DEST}"; return 1; }
  fi
}

# 安装 macOS：优先用刚构建并汇总到 Products 的产物，兜底 DerivedData / 全盘查找
install_macos() {
  local APP="$BUILD_DIR/Products/macosx/$CONFIG/${MAC_APP_NAME}.app"
  if [ ! -d "$APP" ]; then
    APP="$DERIVED/Build/Products/$CONFIG/${MAC_APP_NAME}.app"
  fi
  if [ ! -d "$APP" ]; then
    local FOUND
    FOUND="$(find "$DERIVED/Build/Products" -maxdepth 2 -type d -name "${MAC_APP_NAME}.app" 2>/dev/null | head -1 || true)"
    if [ -n "$FOUND" ]; then
      echo "⚠️  预期路径未命中，兜底找到：${FOUND}"
      APP="$FOUND"
    fi
  fi
  if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "❌ 未找到 macOS 产物 ${MAC_APP_NAME}.app" >&2
    return 1
  fi
  install_mac_app "$APP"
}

# iOS 安装：真机签名构建 + devicectl 安装 + 启动。
# $1=文案模式：single（仅 iOS，无真机报错）/ dual（双端，无真机提示跳过）
install_ios() {
  local MODE="${1:-single}"
  local UDID="${QQPLAYER_IOS_UDID:-}"
  if [ -z "$UDID" ]; then
    UDID="$(detect_udid)" || UDID=""
  fi
  if [ -z "$UDID" ]; then
    if [ "$MODE" = "dual" ]; then
      echo "⏭️  跳过 iOS：未检测到可用于安装的真机"
    else
      echo "❌ 没有可用于安装的 iOS 真机（上面「跳过 …」每行都说明了一台设备为什么不可用）"
    fi
    device_hint
    return 1
  fi
  echo "=== 真机构建（UDID=${UDID} / ${CONFIG}） ==="
  scripts/xcbuild.sh build -project "$PROJECT" -scheme "$IOS_SCHEME" \
    -destination "id=${UDID}" -allowProvisioningUpdates \
    -configuration "$CONFIG" \
    || { echo "❌ 真机构建失败"; return 1; }
  local APP="$DERIVED/Build/Products/$CONFIG-iphoneos/$APP_NAME.app"
  if [ ! -d "$APP" ]; then
    echo "❌ 未找到真机产物：${APP}" >&2
    return 1
  fi
  echo "=== 安装到真机 ==="
  xcrun devicectl device install app --device "${UDID}" "$APP" \
    || { echo "❌ 安装到真机失败"; return 1; }
  echo "=== 启动 ==="
  xcrun devicectl device process launch --device "${UDID}" "${IOS_BUNDLE_ID}" \
    || { echo "❌ 启动失败"; return 1; }
}

# 构建 + 安装 macOS（构建失败不安装，避免装上一份旧产物）
build_install_macos() {
  build_macos || return 1
  install_macos || return 1
}

echo "▶︎ 目标：${TARGET}　配置：${CONFIG}　macOS 架构：${ARCH}　DerivedData：${DERIVED}"

if [ "$INSTALL_AFTER" -eq 1 ]; then
  INSTALL_FAIL=0
  case "$TARGET" in
    macos) build_install_macos || INSTALL_FAIL=1 ;;
    ios) install_ios single || INSTALL_FAIL=1 ;;
    all)
      # 双端互不阻断：先 macOS，再 iOS
      build_install_macos || INSTALL_FAIL=1
      install_ios dual || INSTALL_FAIL=1
      ;;
  esac
else
  case "$TARGET" in
    all) build_ios; build_macos ;;
    ios) build_ios ;;
    macos) build_macos ;;
  esac
fi

if [ "$OPEN_AFTER" -eq 1 ]; then
  echo "▶︎ 打开 $PROJECT"
  open "$PROJECT"
fi

if [ "${INSTALL_FAIL:-0}" -ne 0 ]; then
  echo "❌ 安装未全部成功（详见上方输出）" >&2
  exit 1
fi

echo "🎉 构建完成（$TARGET / ${CONFIG} / macOS 架构 ${ARCH}）"

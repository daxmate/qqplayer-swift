#!/bin/bash
# QQPlayer 一键构建 / 安装（iOS + macOS）
#
# 用法:
#   ./build.sh              编译 iOS（generic 模拟器，免签名）+ macOS（不安装、不启动）
#   ./build.sh ios          仅编译 iOS（generic 模拟器，免签名）
#   ./build.sh mac          仅编译 macOS
#   ./build.sh install      构建 + 安装 iOS（真机）+ macOS（+ 启动）
#   ./build.sh install ios  仅安装 iOS（真机签名构建 + devicectl 安装 + 启动，team B6FA37AYT5）
#   ./build.sh install mac  仅安装 macOS（构建 + 覆盖安装到 /Applications/QQPlayer.app + 启动）
#   ./build.sh --install    install ios 的别名（旧用法兼容）
#
# 环境变量（可选）:
#   QQPLAYER_MAC_INSTALL_DIR  macOS 安装目录（默认 /Applications；便于自验指向 /tmp）
#   QQPLAYER_SKIP_LAUNCH=1    跳过 macOS 启动（仅影响 macOS 安装分支）
#   QQPLAYER_DD               DerivedData 路径（默认 <仓库>/build/DerivedData）
#   QQPLAYER_BUILD_DIR        统一产物根目录（默认 <仓库>/build）
set -euo pipefail
cd "$(dirname "$0")"

# iOS/macOS 构建必须使用 Xcode 自带工具链；环境里的 CC/CXX（如 Homebrew gcc）会劫持
# SPM C/C++ 依赖编译并报错（gcc 不识别 -target/-fmodules 等参数），强制清掉
unset CC CXX 2>/dev/null || true

# DerivedData 语义与既往一致（iOS 产物路径不变），交给 scripts/xcbuild.sh 统一注入
# 共享 SPM 缓存 + 构建锁（禁止裸 xcodebuild：新路径会重新 clone 全部 21 个依赖）
BUILD_DIR="${QQPLAYER_BUILD_DIR:-$PWD/build}"
export QQPLAYER_DD="${QQPLAYER_DD:-$BUILD_DIR/DerivedData}"
DERIVED="${QQPLAYER_DD}"

IOS_SCHEME="QQPlayer"          # iOS scheme / 产物名
MAC_SCHEME="QQPlayerMac"       # macOS scheme
APP_NAME="QQPlayer"            # iOS 可执行/产物名
MAC_APP_NAME="QQPlayer"       # macOS 可执行/产物名（用户可见名统一为 QQPlayer）
MAC_INSTALL_DIR="${QQPLAYER_MAC_INSTALL_DIR:-/Applications}"
SIM_DEST='generic/platform=iOS Simulator'   # generic 模拟器目标（免签名，不依赖任何模拟器实例）
IOS_BUNDLE_ID="com.daxmate.qqplayer.ios"

# 用法说明（参数校验失败时打到 stderr，退出码 2）
usage() {
  cat >&2 <<'USAGE_EOF'
用法: ./build.sh [子命令] [对象]

编译（不安装、不启动）:
  ./build.sh              编译 iOS（generic 模拟器，免签名）+ macOS
  ./build.sh ios          仅编译 iOS（generic 模拟器，免签名）
  ./build.sh mac          仅编译 macOS

构建 + 安装 + 启动:
  ./build.sh install      安装 iOS（真机）+ macOS
  ./build.sh install ios  仅安装 iOS（真机）
  ./build.sh install mac  仅安装 macOS
  ./build.sh --install    等价 ./build.sh install ios（旧用法兼容）

环境变量:
  QQPLAYER_MAC_INSTALL_DIR  macOS 安装目录（默认 /Applications）
  QQPLAYER_SKIP_LAUNCH=1    跳过 macOS 启动
  QQPLAYER_DD               DerivedData 路径
USAGE_EOF
}

# 探测可用真机（devicectl JSON → scripts/detect-device.py 选设备；判据与理由见该脚本注释）。
# 注意：**不要**只认 tunnelState=connected —— 隧道是按需建立的，可达设备也会报 disconnected，
# 那样会误报「未发现真机」（2026-09-20 事故）。选择逻辑有自测：scripts/detect-device-test.py
detect_udid() {
  local OUT="/tmp/qqplayer-devices.json"
  xcrun devicectl list devices --json-output "${OUT}" >/dev/null 2>&1 || return 1
  python3 scripts/detect-device.py --explain "${OUT}"
}

# 无真机时的排查提示（与既往文案一致）
device_hint() {
  echo "   排查：① iPhone 用数据线连本机并在「访达 → 设备」里信任此 Mac"
  echo "         ② iPhone：设置 → 隐私与安全性 → 开发者模式 = 开"
  echo "         ③ 同一 Wi-Fi 下也可用（无需数据线），但设备不能关机"
}

# 成品汇总：复制到 <build>/Products/<sdk>/<Config>/（ditto 保留签名/扩展属性）
publish_product() { # $1=sdk 目录名 $2=源 .app $3=平台标签
  local dest="${BUILD_DIR}/Products/$1/Debug/$(basename "$2")"
  mkdir -p "$(dirname "${dest}")"
  ditto "$2" "${dest}"
  echo "✅ $3 成品：${dest}"
}

# iOS 编译：generic 模拟器构建（免签名、不需要真机/模拟器实例、不启动模拟器）
build_sim() {
  echo "=== 模拟器构建（generic 目标） ==="
  scripts/xcbuild.sh build -project QQPlayer.xcodeproj -scheme "${IOS_SCHEME}" \
    -destination "${SIM_DEST}" CODE_SIGNING_ALLOWED=NO || { echo "❌ 模拟器构建失败"; return 1; }
  publish_product iphonesimulator "${DERIVED}/Build/Products/Debug-iphonesimulator/${APP_NAME}.app" "iOS 模拟器"
}

# iOS 安装：真机签名构建 + devicectl 安装 + 启动。可选传入已探测到的 UDID。
build_install_ios() {
  local UDID="${1:-}"
  if [ -z "${UDID}" ]; then
    UDID="$(detect_udid)" || UDID=""
  fi
  if [ -z "${UDID}" ]; then
    echo "❌ 没有可用于安装的 iOS 真机（上面「跳过 …」每行都说明了一台设备为什么不可用）"
    device_hint
    return 1
  fi
  echo "=== 真机构建（UDID=${UDID}） ==="
  scripts/xcbuild.sh build -project QQPlayer.xcodeproj -scheme "${IOS_SCHEME}" \
    -destination "id=${UDID}" -allowProvisioningUpdates \
    || { echo "❌ 真机构建失败"; return 1; }
  local APP="${DERIVED}/Build/Products/Debug-iphoneos/${APP_NAME}.app"
  echo "=== 安装到真机 ==="
  xcrun devicectl device install app --device "${UDID}" "${APP}" \
    || { echo "❌ 安装到真机失败"; return 1; }
  echo "=== 启动 ==="
  xcrun devicectl device process launch --device "${UDID}" "${IOS_BUNDLE_ID}" \
    || { echo "❌ 启动失败"; return 1; }
}

# macOS 27 / Xcode 27 起 Metal 工具链是可选组件；缺失时 mlx-swift 的 .metal 文件
# 会在编译中途失败（cannot execute tool 'metal' due to missing Metal Toolchain）。
# 开工前显式检查，给出可执行的修复命令。
require_metal_toolchain() {
  if xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    return 0
  fi
  echo "❌ 缺少 Metal Toolchain（Xcode 27 可选组件），macOS 构建无法编译 mlx-swift 的 Metal 内核" >&2
  echo "   修复：xcodebuild -downloadComponent MetalToolchain" >&2
  echo "   或 Xcode → Settings → Components 安装 Metal Toolchain 后重试" >&2
  return 1
}

# macOS 编译：构建（scheme QQPlayerMac），不安装、不启动
build_mac() {
  require_metal_toolchain || return 1
  echo "=== macOS 构建（scheme ${MAC_SCHEME}） ==="
  scripts/xcbuild.sh build -project QQPlayer.xcodeproj -scheme "${MAC_SCHEME}" \
    -destination 'platform=macOS' || { echo "❌ macOS 构建失败"; return 1; }
  publish_product macosx "${DERIVED}/Build/Products/Debug/${MAC_APP_NAME}.app" "macOS"
}

# macOS 安装：构建 + 覆盖安装到 ${MAC_INSTALL_DIR} + 启动
build_install_mac() {
  build_mac || return 1

  local APP="${DERIVED}/Build/Products/Debug/${MAC_APP_NAME}.app"
  if [ ! -d "${APP}" ]; then
    APP="$(find "${DERIVED}/Build/Products" -maxdepth 2 -type d -name "${MAC_APP_NAME}.app" 2>/dev/null | head -1)"
    if [ -n "${APP}" ]; then
      echo "⚠️  预期路径未命中（${DERIVED}/Build/Products/Debug/），兜底找到：${APP}"
    else
      echo "❌ 未找到 macOS 产物 ${MAC_APP_NAME}.app"
      return 1
    fi
  fi
  install_mac_app "${APP}" || return 1
}

install_mac_app() {
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

# 编译双端（互不阻断，最后汇总退出码）
run_compile_both() {
  local FAIL=0
  build_sim || FAIL=1
  build_mac || FAIL=1
  return "${FAIL}"
}

# 安装双端：两端互不阻断（一端失败另一端仍跑完），最后汇总退出码
run_dual() {
  local FAIL=0
  local UDID=""
  build_install_mac || FAIL=1
  UDID="$(detect_udid)" || UDID=""
  if [ -z "${UDID}" ]; then
    echo "⏭️  跳过 iOS：未检测到可用于安装的真机"
    device_hint
    FAIL=1
  else
    build_install_ios "${UDID}" || FAIL=1
  fi
  return "${FAIL}"
}

# ---- 子命令分发 ----
CMD="${1:-}"
ARG2="${2:-}"
ARG3="${3:-}"

# 多余参数（第 3 个及以后）一律拒绝
if [ -n "${ARG3}" ]; then
  echo "❌ 参数过多：$*" >&2
  usage
  exit 2
fi

EXIT=0
case "${CMD}" in
  "")
    [ -z "${ARG2}" ] || { echo "❌ 不接受参数：${ARG2}" >&2; usage; exit 2; }
    run_compile_both || EXIT=$?
    ;;
  ios)
    [ -z "${ARG2}" ] || { echo "❌ ios 不接受参数：${ARG2}" >&2; usage; exit 2; }
    build_sim || EXIT=$?
    ;;
  mac)
    [ -z "${ARG2}" ] || { echo "❌ mac 不接受参数：${ARG2}" >&2; usage; exit 2; }
    build_mac || EXIT=$?
    ;;
  install)
    case "${ARG2}" in
      "")   run_dual || EXIT=$? ;;
      ios)  build_install_ios || EXIT=$? ;;
      mac)  build_install_mac || EXIT=$? ;;
      *)    echo "❌ 未知安装对象：${ARG2}" >&2; usage; exit 2 ;;
    esac
    ;;
  --install)
    [ -z "${ARG2}" ] || { echo "❌ --install 不接受参数（等价 ./build.sh install ios）" >&2; usage; exit 2; }
    build_install_ios || EXIT=$?
    ;;
  *)
    echo "❌ 未知子命令：${CMD}" >&2
    usage
    exit 2
    ;;
esac

if [ "${EXIT}" -ne 0 ]; then
  echo "❌ 构建/安装未全部成功（退出码 ${EXIT}）"
  exit "${EXIT}"
fi
echo "✅ 完成"

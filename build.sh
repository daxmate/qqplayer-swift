#!/bin/bash
# QQPlayer iOS 原生版一键构建
# 用法:
#   ./build.sh              模拟器构建（免签名，iPhone 17 Pro）
#   ./build.sh --install    真机签名构建 + devicectl 安装 + 启动（需连接 iPhone，team B6FA37AYT5）
set -euo pipefail
cd "$(dirname "$0")"

# iOS 构建必须使用 Xcode 自带工具链；环境里的 CC/CXX（如 Homebrew gcc）会劫持
# SPM C/C++ 依赖编译并报错（gcc 不识别 -target/-fmodules 等参数），强制清掉
unset CC CXX 2>/dev/null || true

DERIVED="build/DerivedData"
SCHEME="QQPlayer"   # scheme 名
APP_NAME="QQPlayer" # 可执行/产物名

# 探测可用真机（devicectl JSON → scripts/detect-device.py 选设备；判据与理由见该脚本注释）。
# 注意：**不要**只认 tunnelState=connected —— 隧道是按需建立的，可达设备也会报 disconnected，
# 那样会误报「未发现真机」（2026-09-20 事故）。选择逻辑有自测：scripts/detect-device-test.py
detect_udid() {
  local OUT="/tmp/qqplayer-devices.json"
  xcrun devicectl list devices --json-output "${OUT}" >/dev/null 2>&1 || return 1
  python3 scripts/detect-device.py --explain "${OUT}"
}

build_sim() {
  echo "=== 模拟器构建 ==="
  xcodebuild -project "QQPlayer.xcodeproj" -scheme "${SCHEME}" \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -derivedDataPath "${DERIVED}" build
}

build_install() {
  local UDID
  UDID="$(detect_udid)" || UDID=""
  if [ -z "${UDID}" ]; then
    echo "❌ 没有可用于安装的 iOS 真机（上面「跳过 …」每行都说明了一台设备为什么不可用）"
    echo "   排查：① iPhone 用数据线连本机并在「访达 → 设备」里信任此 Mac"
    echo "         ② iPhone：设置 → 隐私与安全性 → 开发者模式 = 开"
    echo "         ③ 同一 Wi-Fi 下也可用（无需数据线），但设备不能关机"
    exit 1
  fi
  echo "=== 真机构建（UDID=${UDID}） ==="
  xcodebuild -project "QQPlayer.xcodeproj" -scheme "${SCHEME}" \
    -destination "id=${UDID}" -derivedDataPath "${DERIVED}" \
    -allowProvisioningUpdates build
  local APP
  APP="${DERIVED}/Build/Products/Debug-iphoneos/${APP_NAME}.app"
  echo "=== 安装到真机 ==="
  xcrun devicectl device install app --device "${UDID}" "${APP}"
  echo "=== 启动 ==="
  xcrun devicectl device process launch --device "${UDID}" com.daxmate.qqplayer.ios
}

case "${1:-}" in
  --install) build_install ;;
  *) build_sim ;;
esac
echo "✅ 完成"

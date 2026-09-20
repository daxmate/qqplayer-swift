#!/usr/bin/env python3
"""从 `xcrun devicectl list devices --json-output` 的输出里挑出**可用于构建/安装的 iOS 真机**。

用法：
    xcrun devicectl list devices --json-output /tmp/devs.json
    python3 scripts/detect-device.py /tmp/devs.json              # 成功：stdout 只打印 UDID，退出 0
    python3 scripts/detect-device.py --explain /tmp/devs.json    # 逐台把「跳过原因」打到 stderr

为什么不能只认 tunnelState == "connected"（2026-09-20 真机误报事故）：
    devicectl 的隧道是**按需建立**的。设备完全可达（能装包、能拉崩溃日志）时，list 输出也可能是
    `tunnelState = "disconnected"` —— 实测 iPhone 16 Pro：connected 从未出现，而 build.sh 按它判定，
    直接误报「未发现已连接的真机」，只能绕开探测手工 install。

判据（全部满足才选；**已知坏值才拒，字段缺失一律放行**，避免换 macOS/DeviceKit 版本后变成新的误报）：
    1. connectionProperties.pairingState      已知且 != "paired"          → 跳过（未与这台 Mac 配对）
    2. connectionProperties.tunnelState       已知且 == "unavailable"     → 跳过（设备关机/失联）
    3. hardwareProperties.platform            已知且 != "iOS"             → 跳过（Apple Watch 等）
    4. deviceProperties.developerModeStatus   已知且 == "disabled"        → 跳过（开发构建装不上）

多台同时满足时取第一台（devicectl 按最近使用排序），与旧行为一致。
"""

import json
import sys


def pick_device(data):
    """返回 (udid, name, reasons)；找不到可用设备时 udid 为 None。"""
    reasons = []
    for dev in data.get("result", {}).get("devices", []):
        conn = dev.get("connectionProperties") or {}
        hw = dev.get("hardwareProperties") or {}
        dp = dev.get("deviceProperties") or {}
        name = dp.get("name") or hw.get("marketingName") or dev.get("identifier") or "?"

        pairing = conn.get("pairingState")
        tunnel = conn.get("tunnelState")
        platform = hw.get("platform")
        devmode = dp.get("developerModeStatus")
        udid = hw.get("udid")

        if not udid:
            reasons.append((name, "输出里没有 udid"))
        elif pairing and pairing != "paired":
            reasons.append((name, f'未与这台 Mac 配对（pairingState={pairing}）'))
        elif tunnel == "unavailable":
            reasons.append((name, "不可达（tunnelState=unavailable：关机 / 不在同一网络）"))
        elif platform and platform != "iOS":
            reasons.append((name, f"非 iOS 设备（platform={platform}）"))
        elif devmode == "disabled":
            reasons.append((name, "未开启开发者模式（设置 → 隐私与安全性 → 开发者模式）"))
        else:
            return udid, name, reasons

    return None, None, reasons


def main(argv):
    explain = "--explain" in argv
    args = [a for a in argv[1:] if a != "--explain"]
    if len(args) != 1:
        print("用法: python3 scripts/detect-device.py [--explain] <devicectl-json 路径>", file=sys.stderr)
        return 2

    try:
        with open(args[0]) as fh:
            data = json.load(fh)
    except Exception as exc:  # 文件缺失 / JSON 损坏
        print(f"读取 devicectl 输出失败：{exc}", file=sys.stderr)
        return 1

    udid, name, reasons = pick_device(data)
    if explain:
        for who, why in reasons:
            print(f"  跳过 {who}：{why}", file=sys.stderr)
    if not udid:
        print("没有可用于安装的 iOS 真机", file=sys.stderr)
        return 1

    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

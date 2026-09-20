#!/usr/bin/env python3
"""`scripts/detect-device.py` 的选择判据自测（纯 stdlib，无需真机、无需 devicectl）。

跑法：python3 scripts/detect-device-test.py

fixture 全部取自 2026-09-20 真机实测输出的字段形状：
  - iPhone 16 Pro：pairingState=paired / tunnelState=disconnected（**可达但隧道未建立**，旧判据在这里误报）
  - Apple Watch Series 9：platform=watchOS / tunnelState=unavailable
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "detect-device.py"


def device(identifier, *, udid="00008140-001639913E42801C", name="dax's iPhone",
           pairing="paired", tunnel="disconnected", platform="iOS", devmode="enabled"):
    """造一台设备；传 None 表示该字段在输出里不存在。"""
    conn = {"authenticationType": "manualPairing", "transportType": "localNetwork"}
    if pairing is not None:
        conn["pairingState"] = pairing
    if tunnel is not None:
        conn["tunnelState"] = tunnel
    hw = {"deviceType": "iPhone", "productType": "iPhone17,1", "marketingName": "iPhone 16 Pro"}
    if udid is not None:
        hw["udid"] = udid
    if platform is not None:
        hw["platform"] = platform
    dp = {"name": name, "osVersionNumber": "26.6.2"}
    if devmode is not None:
        dp["developerModeStatus"] = devmode
    return {"identifier": identifier, "connectionProperties": conn,
            "hardwareProperties": hw, "deviceProperties": dp}


def run(devices):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump({"result": {"devices": devices}}, fh)
        path = fh.name
    proc = subprocess.run([sys.executable, str(SCRIPT), "--explain", path],
                          capture_output=True, text=True)
    return proc.returncode, proc.stdout.strip(), proc.stderr


CASES = [
    # (用例名, 设备列表, 期望退出码, 期望 stdout)
    ("可达但隧道未建立（2026-09-20 误报事故）：应选中",
     [device("A", udid="IPHONE-UDID")], 0, "IPHONE-UDID"),

    ("只有 Apple Watch：应拒绝",
     [device("W", udid="WATCH-UDID", name="张超的Apple Watch", platform="watchOS",
             tunnel="unavailable", devmode="disabled")], 1, ""),

    ("手表在前、iPhone 在后：应跳过手表选 iPhone",
     [device("W", udid="WATCH-UDID", name="Watch", platform="watchOS", tunnel="unavailable"),
      device("A", udid="IPHONE-UDID")], 0, "IPHONE-UDID"),

    ("设备不可达（tunnelState=unavailable）：应拒绝",
     [device("A", udid="IPHONE-UDID", tunnel="unavailable")], 1, ""),

    ("未配对（pairingState=unpaired）：应拒绝",
     [device("A", udid="IPHONE-UDID", pairing="unpaired")], 1, ""),

    ("开发者模式明确关闭：应拒绝",
     [device("A", udid="IPHONE-UDID", devmode="disabled")], 1, ""),

    ("隧道已连接（旧判据路径）：应选中",
     [device("A", udid="IPHONE-UDID", tunnel="connected")], 0, "IPHONE-UDID"),

    ("字段缺失（换 DeviceKit 版本）：不应变成新误报",
     [device("A", udid="IPHONE-UDID", pairing=None, tunnel=None, platform=None, devmode=None)],
     0, "IPHONE-UDID"),

    ("无 udid 字段：应拒绝",
     [device("A", udid=None)], 1, ""),

    ("设备列表为空：应拒绝",
     [], 1, ""),
]


def main():
    failures = []
    for name, devices, want_code, want_out in CASES:
        code, out, err = run(devices)
        ok = (code == want_code and out == want_out)
        print(f"{'✅' if ok else '❌'} {name}")
        if not ok:
            failures.append(name)
            print(f"   期望 exit={want_code} stdout={want_out!r}")
            print(f"   实际 exit={code} stdout={out!r}")
            if err:
                print(f"   stderr: {err.strip()}")

    # 被拒绝时必须解释原因（build.sh 会把 stderr 直接展示给用户）
    code, out, err = run([device("W", udid="WATCH-UDID", name="Watch", platform="watchOS")])
    if code == 1 and "watchOS" in err:
        print("✅ 拒绝时 stderr 给出原因（含 platform=watchOS）")
    else:
        print("❌ 拒绝时未解释原因")
        print(f"   stderr: {err.strip()!r}")
        failures.append("拒绝原因诊断")

    print()
    if failures:
        print(f"❌ {len(failures)}/{len(CASES) + 1} 个用例失败：" + "、".join(failures))
        return 1
    print(f"✅ 全部 {len(CASES) + 1} 个用例通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())

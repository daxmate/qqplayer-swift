# NOTICE

## 项目来源声明

**QQPlayer (iOS)** 是基于 **Cosmos Music Player** 的衍生作品（fork），遵循 **GNU General Public License v3.0**。

- **原作者**: Raphael Boullay Le Fur（GitHub: [clquwu](https://github.com/clquwu)）
- **原项目**: [Cosmos Music Player](https://github.com/clquwu/Cosmos-Music-Player)
- **原项目许可**: GPL-3.0（本仓库保留完整 LICENSE 文本）

## 修改说明

在 QQPlayer v1.2.4 基础上进行了以下修改与扩展：

1. **品牌化**：应用名称改为 QQPlayer，bundle identifier 改为 `com.daxmate.qqplayer.ios`，替换应用图标
2. **签名**：使用 QQPlayer 开发者的 Apple Developer 签名（team B6FA37AYT5）
3. 后续功能扩展（跟唱模式 / AB 循环 / 倍速播放 / 局域网主机同步等）见 README 与提交历史

## 许可

本衍生作品整体以 **GPL-3.0** 许可发布。任何分发（含 App Store 上架）必须：

- 保留本 NOTICE 与 LICENSE 文件
- 提供完整源代码（本仓库即源代码）
- 保持 GPL-3.0 许可不变

## 上游附加许可（GPLv3 §7 — Apple App Store 分发）

本仓库通过 Apple App Store 分发 iOS 版本。为此，上游版权人 **Raphael Boullay Le Fur**（Cosmos Music Player 作者）已就本项目的 GPLv3 **§7 additional permission** 请求作出书面同意（2026-09-14）：允许 QQPlayer 及其衍生作品通过 Apple App Store 分发，不受与 GPL-3.0 冲突的平台条款限制。

- 凭据原文、当事人与范围： [`docs/compliance/upstream-permission.md`](docs/compliance/upstream-permission.md)
- 该附加许可**不改变**本仓库的整体 GPL-3.0 许可，也不免除源码公开义务

## 第三方数据（非代码）

简繁字形归一使用的映射表是 **OpenCC** 项目的数据文件（Apache-2.0，[BYVoid/OpenCC](https://github.com/BYVoid/OpenCC)），以 Swift 字面量形式内联在源码里，不是运行时依赖：

| 文件 | 数据源 | 用途 |
|---|---|---|
| `QQPlayer/Services/SimplifiedTraditionalMap.swift` | `STCharacters.txt` | 简→繁（显示层繁体方向） |
| `QQPlayer/Services/TraditionalToSimplifiedMap.swift` | `TSCharacters.txt` | 繁→简（显示层简体方向；生成脚本 `scripts/gen-traditional-to-simplified.py`） |

两份表都只用于**显示层**字形归一，不改写数据库里的原始 tag。

## 独立项目

桌面端 QQPlayer（FastAPI 后端 + Web 前端）为独立项目，与本仓库无代码衍生关系，其许可不受本仓库影响。

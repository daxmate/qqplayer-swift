# 上游授权凭据 —— GPLv3 §7 附加许可（Apple App Store 分发）

> 本文件是本仓库分发 iOS 版（App Store）所依赖的**上游版权人授权凭据**。请勿删除或修改引文原文。

## 一、当事人与授权范围

| 项目 | 内容 |
|---|---|
| 授权人（版权人） | **Raphael Boullay Le Fur** — GitHub [`clquwu`](https://github.com/clquwu) · 邮箱 `raphaelboullaylefur@proton.me` |
| 上游项目 | [Cosmos Music Player](https://github.com/clquwu/Cosmos-Music-Player)（GPL-3.0，上游版权人；83 次提交中 82 次为其本人） |
| 被授权项目 | **QQPlayer**（本仓库 `daxmate/qqplayer-swift`）及其衍生作品 |
| 授权内容 | GPLv3 **§7 additional permission**：允许通过 **Apple App Store** 分发，不受与 GPL-3.0 冲突的平台条款（DRM 包装、设备数限制、Apple 单方下架权等）限制 |
| 授权形式 | 电子邮件回复（回复我们 2026-09-14 发出的书面请求） |
| 授权时间 | **2026-09-14 19:49（Asia/Shanghai）** |
| 我方请求主题 | `Additional permission request under GPLv3 §7 — QQPlayer, a GPL-3.0 fork of Cosmos Music Player` |

## 二、授权人回复原文（逐字转录）

```
Hi thanks for taking the time to ask me. Of course I don't have an issue with that
and will modify the gnu licence slightly so other apps doesn't have this issue.
Good luck on your fork it seems intersting 👍

Sent from Proton Mail for Android
```

**中文大意**：感谢你花时间来问我。我当然对此没有异议，并且我会略微修改 GPL 许可文本，让其他 app 不再遇到这个问题。祝你的 fork 顺利，看起来挺有意思 👍

## 三、凭据解读与边界

1. **指向明确**：该回复的邮件主题即为我们的 §7 附加许可请求（点名 QQPlayer），"that" 指向该请求本身 → 构成版权人对该请求的**明示同意**。
2. **覆盖范围**：覆盖 Cosmos Music Player 中由 Raphael Boullay Le Fur 持有的全部版权。上游另一位贡献者（`mariana0pachon`）仅有一次 README 文档改动，不涉及代码版权。
3. **不改变 GPL 义务**：本附加许可仅解除"App Store 分发条款与 GPL-3.0 §10 冲突"这一项限制；本仓库整体仍为 GPL-3.0，**LICENSE / NOTICE / 完整对应源码继续公开**。
4. **非法律意见**：本文档为工程侧的合规凭据归档与事实陈述，不构成法律意见；重大商业决策建议咨询执业律师。
5. **时效性说明**：本 fork 基于 Cosmos Music Player **1.2.4**，该版本 LICENSE 无任何例外条款，因此这份授权对本仓库仍然必要（上游后续放松许可不会自动回溯覆盖 1.2.4 的衍生作品）。

## 四、待补强（TODO）

- [ ] **归档原始邮件全文**（`.eml` 或完整截图）到本目录，并与本文档并存 —— 本文档目前为逐字转录，原始邮件是最强证据。
- [ ] **跟进上游 LICENSE 修改**：授权人表示将"略微修改 GPL 许可文本"（在其仓库加入类似例外）。若落地，记录其 **commit SHA + 日期**并在本文件与 `NOTICE.md` 追加引用（公开、可验证，强于私人邮件）。
- [ ] （可选）回信请授权人对一句可引用的措辞作确认，使凭据从口语化回复升级为可直接引用的许可语句。

## 五、变更记录

| 日期 | 事件 |
|---|---|
| 2026-09-14 | 我们以邮件发出 §7 附加许可请求（含背景一页纸） |
| 2026-09-14 19:49 | 版权人邮件回复：无异议，并计划略改上游 GPL 文本 |
| 2026-09-15 | 本凭据文档落库，`NOTICE.md` 增加引用 |

# 歌词时间轴自动对齐（核心层）

把「有一堆歌词行、时间戳不准或干脆没有」的歌，用 Apple SpeechAnalyzer 识别出的
词级时间轴反推每行的起止时间，结果写进 aligned 歌词库。**不改歌词文本**，
只换每行的时间戳。

实现全在 `QQPlayer/Services/LyricsAlignment/`：

| 文件 | 职责 |
| --- | --- |
| `LyricAlignmentTypes.swift` | `AsrToken` / `AlignedLyricLine` / `LyricAlignmentReport` / `LyricAlignmentError` |
| `LyricAlignmentTextNormalizer.swift` | 比较前的归一化（NFKC、去空白/标点/符号、小写、繁→简） |
| `LyricAlignmentAligner.swift` | 纯逻辑对齐（字符级单调 DP、偏移、插值、单调化），不 import Speech |
| `LyricsSpeechEngine.swift` | `LyricsSpeechEngine` 协议 + `AppleSpeechLyricsEngine`（iOS 26 / macOS 26） |
| `LyricAlignmentService.swift` | 编排：取歌词行 → 认语言 → 转写 → 对齐 → 落库；语言判定纯函数也在这里 |

## 算法

1. **归一化**：NFKC → 小写 → 去空白/标点/符号（emoji 一并丢）→ 中文做繁→简。
   繁→简复用项目唯一数据源 `DisplayScriptNormalizer.toSimplified`（OpenCC TSCharacters），
   不另建映射表：两套映射会让显示字形与对齐归一化漂移。
2. **字符流**：歌词按行切成归一化字符序列（每个字符记住行号）；ASR token 也归一化，
   字符时间在 token 内按等分线性摊派（长 token 的行首/行尾更准）。
3. **单调 DP**（Needleman-Wunsch，全局）：匹配 +1 / 错配 −0.5 / gap −0.6。
   有原时间先验时启用**窄带**：只允许落在「该行期望时间 ±8s」内，
   期望时间按「本行先验 + 行内字符位置 × 行跨度」摊派，防止跨段错配。
4. **每行判定**：`similarity = 命中字符数 / 行有效字符数`；
   行长 ≥ 2 时 `similarity >= 0.6` 算命中；1 字符行只有那一个字精确命中才算。
5. **未命中行的兜底**：
   - 先估**全局常数偏移** = 命中行（ASR 时间 − 原时间）的中位数；
     样本 ≥ 3 行且 MAD < 0.4s 时，未命中行用「原时间 + 偏移」；
   - 否则在前后锚点之间**按字符数线性插值**。
6. **单调化**：逐行 `start >= 上一行 end`，并且全部夹在 `[0, duration]`；
   行最短 0.2s。没有任何一行命中 → 抛 `alignmentFailed`。

## 阈值一览

| 参数 | 值 | 为什么 |
| --- | --- | --- |
| 行相似度门槛 | 0.6 | 4 首歌实测：真命中行 ≥ 0.8，噪声行 ≤ 0.4，0.6 留足中间带 |
| 低质判据 | 覆盖率 0.45 + 锚点 3 行 | 长行密集的中文歌行命中率天然偏低；实测 46.7% 行命中但覆盖率 0.61、45 行偏差 ≤0.88s，不应误判 |
| 先验窄带 | ±8s | 单行通常 3–8s；±8s 容得下整行，又挡住相邻段落 |
| 偏移可用 MAD | < 0.4s | 偏移如果是整体平移，各行残差应集中在 0 附近 |
| 偏移最少样本 | 3 行 | 2 行的「中位数」没有抗噪能力 |
| 每字估时 | 0.22s | 无先验时行跨度兜底（中文慢歌经验值） |

## 落库

- 位置：`AlignedLyricsStore`（iOS `Documents/lyrics-aligned/{stableId}.json`，
  macOS `<App Support>/QQPlayerMac/lyrics-aligned`）——**不另建目录**，对齐结果也参与局域网同步。
- 写入内容：`Lyrics`，`plainLyrics` / `translation` / `roman` / `source` 原样保留，
  只替换 `syncedLyrics` 的 timestamp。
- 展示优先级（`LyricsManager.getLyrics`）：手动指定 > **aligned** > 内存缓存 > 磁盘缓存 > 内嵌/网络。

## 系统门槛

- `SpeechAnalyzer` 需要 **iOS 26 / macOS 26**；更低版本抛 `unsupportedSystem`，**不崩**，功能不可用。
- 首次使用某语言要下载模型（20–40s，需联网，进度回调 0…0.15）；模型不可用 → `assetInstallFailed`。
- 音频**必须落文件**再喂 analyzer：内部统一 `AVURLAsset + AVAssetReader
  （outputSettings = 16k/1ch/Int16 LPCM）→ 16k 单声道 Int16 WAV`
  （`NSTemporaryDirectory()/lyric-align-<UUID>.wav`，用完即删），
  再走 `start(inputAudioFile:finishAfterFile:)`。
  ⚠️ 别用 `AVAudioFile` 逐块读源音频：真实 4 分钟 mp3 上 macOS 27.2 抛
  `-39 eofErr`、macOS 26.6 抛 `_GenericObjCError.nilError`（短音频能过，长音频必挂）。
  ⚠️ 把 PCM 逐块塞进 `AsyncStream<AnalyzerInput>` 会在 macOS 26.6 上于
  `Speech.SpeechRecognizerWorker.preRunRecognition()` 崩 `EXC_BREAKPOINT`（不可捕获），
  2026-11-16 已实测证伪旧方案。

## 已知限制

- **重复 hook**：同文本多次出现靠「位置单调 + 先验窄带」区分；没有先验的纯文本歌词遇到完全重复的行，
  只能按顺序分配，可能整体提前/延后一行。
- **纯音乐段 / 长间奏**：没有 ASR 词，时间只能靠邻位插值，可能偏早或偏晚。
- **伴奏、和声、Live 版**：识别文本与歌词差异大时覆盖率掉，报告会给低质告警（覆盖率 <45% 或命中 <3 行）；
  低于门槛就不该覆盖原时间（调用方看 `coverage` / `warnings` 决定是否采纳）。
- **单字符行**：只要求那一个字命中，弱锚点可能被相似发音的字骗到；影响限于该行本身。
- **翻译/罗马音**：本层不参与匹配（只跟随原文行的时间）。

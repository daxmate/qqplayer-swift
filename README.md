# QQPlayer 🎵

> **fork 声明**：本项目基于 [Cosmos Music Player](https://github.com/clquwu/Cosmos-Music-Player)（GPL-3.0，作者 Raphael Boullay Le Fur）二次开发，详见 [NOTICE.md](NOTICE.md)。本仓库整体以 GPL-3.0 发布。

QQPlayer 是一款 **iOS + macOS 双平台高品质音乐播放器**，专为发烧友与外语学习者打造。

- 支持 FLAC、WAV、M4A、MP3、Opus、OGG、DSD（DoP / PCM 转换）、DSF 等格式
- 内建图形均衡器、ReplayGain 音量标准化、双源歌词、跟唱练习（倍速 / AB 循环）
- iOS 端深度整合 Apple 生态：iCloud Drive / 本地双存储、CarPlay、Siri、主屏幕小组件
- macOS 原生版（QQPlayerMac）提供桌面级体验：本地曲库扫描、在线搜索下载（网易云 / 歌曲海 + 夸克网盘）、标签刮削（MusicBrainz）、迷你模式与桌面歌词窗

---

## 平台矩阵

| 平台 | 形态 | 版本 | 系统要求 |
|------|------|------|----------|
| 📱 iOS | App Store「QQPlayer」（iPhone / iPad，付费买断·无内购） | **1.0.0** | iOS 18.5+ |
| 🖥️ macOS | QQPlayerMac 原生应用（仓库内 target，自行构建） | 随仓库迭代 | macOS 13.0+ |

- **iOS 与 macOS 共享同一套 Core 逻辑**（数据库、播放引擎、歌词 / 跟唱、均衡器、元数据解析、本地化），两平台行为一致、同步演进。
- 仓库：<https://github.com/daxmate/qqplayer-swift>（原 qqplayer-ios，2026-08-30 更名）

---

## 功能 ✨

### 🎧 双平台共享（Core）

**音频播放**
- 高品质无损播放：FLAC、WAV、M4A、MP3、Opus、OGG、DSD（DoP / PCM）、DSF
- **双引擎架构**：AVAudioEngine 原生引擎 + SFBAudioEngine（Opus / OGG / DSD 等格式解码与元数据读写），按格式自动路由
- **ReplayGain**：自动音量归一化，听感一致
- **图形均衡器**：内置预设 + 自定义滑杆编辑 + 手动 / GraphicEQ 文本编辑，实时生效
- 内嵌封面读取：FLAC / MP3 / WAV / M4A / DSF 元数据封面提取与缓存

**歌词与跟唱**
- 双源歌词：网易云（eapi 协议，中文翻译双行）+ LRCLIB，自动择优，手动搜索指定后持久化
- 跟唱模式：逐句练习、句末自动暂停、倍速 0.5x–2.0x（变速不变调）、单句循环 / AB 区间循环、点击歌词跳转
- 歌词缓存（TTL 7 天），离线秒出

**音乐管理**
- GRDB（SQLite）曲库：歌手 / 专辑 / 曲目 / 歌单 / 播放历史，文件指纹（stableId）幂等索引
- 智能歌单：由播放历史驱动（最近添加 / 最近播放 / 常听排行 / 年代分组）
- 播放顺序四态（顺序 / 单曲 / 列表循环 / 随机）、收藏、睡眠定时器
- 中文体验：歌手简繁归一（日文假名免疫）、繁体中文本地化

**工程**
- 共享 Core 层：45 个 A 类服务 / 模型直接共享，16 个 iOS 专属 B 类以 `#if os(iOS)` 隔离
- **600+ 自动化测试**（Swift Testing）+ GitHub Actions CI（lint/format + iOS 单测 + macOS 构建与资源断言）
- 5 语言本地化：简体中文 / 繁体中文 / English / Français / Русский

---

### 📱 iOS（App Store 版）

**🎤 跟唱练习**
- 全屏歌词双击切换跟唱模式：逐句练习、每句播完自动暂停（可开关）
- 倍速变速 0.5x–2.0x、单句循环 / AB 区间循环、上一句 / 下一句 / 点句跳转
- 跟唱控制条常驻歌词全屏页

**📝 歌词系统**
- 双源候选（网易云 eapi 含中文翻译双行 + LRCLIB）自动择优，可手动指定并一键恢复自动匹配
- 三行迷你歌词窗（当前句高亮），点击 / 左滑进入全屏歌词页（自动滚动、背景光晕）
- 搜索缓存本地持久化（TTL 7 天）

**📊 智能歌单**
- 自动歌单卡片 + 详情页，年代分组（50s ~ 20s），完整播放历史埋点驱动

**🎛️ 播放体验**
- 全屏播放页：封面 + 歌词 + 控制区弹性布局，下拉关闭，左缘横滑切歌
- 折叠控制容器：进度条与播放键常驻，上滑展开更多控制
- 合并透明控制区：播放顺序 / 歌单 / 输出源
- 深色模式开关（可手动覆盖系统外观）
- 中断恢复：来电 / 其他 App 打断播放后，从实际播放位置继续

**🚗 CarPlay**
- 原生 CarPlay 支持（entitlement 已启用）：标签页导航、正在播放界面、专辑封面、手机与车机播放状态实时同步、界面完整本地化

**🎧 均衡器与音频**
- 10 段常用预设 + 自定义滑杆编辑器（新增）
- GraphicEQ 文本 / 手动编辑，多套配置保存切换
- ReplayGain、内嵌封面、后台播放

**💡 功能发现系统（新增）**
- 首次使用气泡提示 + 帮助中心 + 新功能（WhatsNew）弹窗，上手零门槛

**📚 音乐库管理**
- 双存储：iCloud Drive（跨设备同步）或本地 Documents，可混用
- 智能索引自动发现音乐，离线优先

**👤 歌手信息**
- Spotify + Discogs 双源（可选 API key，见「依赖 📦」），歌手生平、照片，缓存离线可用，支持「歌手不对？」切换来源

**🎤 Siri**
- AppIntents + 意图扩展：支持「播放我的音乐 / 收藏 / 歌单 / 指定歌曲」等命令，名称模糊匹配（示例：*"Hey Siri, play my favorites on QQPlayer"* / *"Dis Siri, joue mes favoris sur QQPlayer"*）

**🌍 国际化与存储**
- 5 语言本地化；iCloud / 本地双存储灵活混用；无网络完整可用（本地文件）

**🧩 系统集成**
- 主屏幕小组件（PlayerWidget）、分享扩展（Share）、CarPlay、Siri

---

### 🖥️ macOS（QQPlayerMac 原生版）

> 纯 SwiftUI 原生桌面应用，与 iOS 共享 Core。默认曲库目录 `~/Music/QQPlayer`，可添加任意外部文件夹。

**📂 本地曲库**
- 本地文件夹扫描 + 索引（FileManager 全扫），设置页管理多个曲库文件夹，默认目录始终在扫
- **FSEvents 实时监控**：文件夹增删改自动重扫（去抖 2s），新增歌曲即播
- **iCloud Drive dataless 文件处理**：跳过未落地文件 + 预触发批量下载实体化 + 下载完成自动补扫，索引不被云端文件卡死
- 文件类型设置（chips 多选，按启用格式过滤，取消格式自动移出索引不删文件）
- 索引中增量刷新（新解析的歌陆续出现）、扫描诊断日志（`~/Library/Logs/QQPlayerMac/scan.log`）
- **拖入导入**：拖文件到窗口或歌单行即导入并加入歌单
- **多选批量管理**：⌘ / ⇧ 多选 + 右键批量「移到废纸篓」（`FileManager.trashItem`，可恢复），删除联动清理歌单 / 收藏引用与播放队列（当前播放被删自动续播）

**🎧 播放**
- SFBAudioEngine 全格式播放（Opus / OGG / DSD→PCM / FLAC 等），DSD 曲目播放
- **播放页频谱可视化**（FFT 实时分析）与歌词面板同屏
- 恢复播放：启动后从上次断点续播（不自动播放）
- 媒体键桥接（MPRemoteCommandCenter / MPNowPlayingInfoCenter）
- 倍速、跟唱、AB 循环与 iOS 一致（KaraokeController 共享）

**📝 歌词**
- 歌词面板常驻（当前行高亮 + 自动居中，点击行跳转 / 设 AB 终点）
- 歌词搜索页（双源候选手动指定 / 恢复自动）、歌词设置（字号 / 译文行 / 整体延迟校准）
- 歌词是 App 第一重要功能，不提供隐藏入口

**🎛️ 均衡器（EQ）**
- 引擎级接线（AVAudioEngine + SFB 双链路），10 段滑杆编辑器 + 手动参数式编辑器（0–16 段 / 频率 / Q 值）+ GraphicEQ 文本导入，导出即复制

**🔍 在线搜索下载（macOS 独有）**
- 网易云在线客户端（共享 eapi 层，与 iOS 歌词同一套加密协议）：搜索 → 播放直链 / 下载
- **歌曲海（Gequhai）** 搜索源 + **夸克网盘** 直链下载：二维码扫码登录、分享链接解析、音质挑选
- 源切换（网易云 / 歌曲海），下载编排 `.part` 原子落盘 → 自动入曲库（重名自动递增序号）
- **SearchAnything 全屏搜索**（⌘K）：本地歌曲 / 在线下载 / 歌手 / 专辑 / 设置分类一处直达
- 设置「下载」分类：音质档位、下载目录

**🏷️ 标签刮削（macOS 独有）**
- 右键「编辑标签 / 刮削」：MusicBrainz（recording 降级链）+ 网易云双源候选，点选即用（含封面）
- 字段：标题 / 歌手 / 专辑 / 年份（网易云惰性补全）/ 风格 / 曲目号 / 专辑歌手，重命名模板（`{artist}/{title}`…，自动去重与子目录）
- 写标签引擎基于 SFBAudioEngine 原生元数据写入（MP3 / M4A / FLAC / OGG / Opus），原子写落盘不损坏文件
- 批量刮削：设置页一键整库或选区批量，高置信度自动写入（100 首上限）
- genre 全链路：解析器读取 → 数据库落库 → 展示 / 编辑

**🪟 窗口与交互**
- 三栏布局（侧边栏 / 列表 / 内容区），歌单详情内容区内嵌（非弹窗）
- **迷你模式 v2**：主窗工具栏一键切迷你播放器 + **桌面歌词窗**（主窗 ⇄ 迷你互斥，歌词开关 / 封面点击返回主窗 / 跟随 App 强调色）
- 播放队列面板：可拖排、删除、点行跳转，重排即落盘、冷启动恢复
- 快捷键：表驱动定义 + 设置页**录制 UI**（Space / ← → / ⌘← → / R / F / G / A / B / [ ] 等，冲突检测）
- 自动歌单 4 卡 + 年代 drill-down；歌单管理（新建 / 重命名 / 删除 / 右键添加）
- 侧边栏搜索（歌曲 / 专辑 / 歌手 / 歌单分组）+ 双击播放（macOS 原生 primaryAction）
- 列表交互：列头三态排序、定位当前播放、右键菜单补全
- 主题三态（浅 / 深 / 跟随系统）+ 强调色 6 预设（全局 NSApp 生效）
- 设置窗口系统化（Settings scene，⌘,），左侧分类导航；封面 artwork 全接入（专辑 / 歌单 / 搜索行 + `cover.jpg` 兜底）
- 帮助中心 / 新功能弹窗（WhatsNew）/ 首次提示气泡
- 运行时日志落盘（`~/Library/Logs/QQPlayerMac/stdout.log` 等），问题可直接读日志定位

---

## 技术架构 🏗️

```
QQPlayerApp.swift（iOS 入口）      QQPlayerMacApp.swift（macOS 入口）
        │                                  │
        └──────────► 共享 Core ◄───────────┘
   （Services / Models / Helpers，45 A 类直接共享 + 16 B 类 #if os(iOS)）
        │
        ├── iOS 专属：Views/（SwiftUI）、CarPlaySceneDelegate、PlayerWidget / Share / SiriIntentsExtension
        └── macOS 专属：Mac/（35 个视图与窗口文件，经 target 白名单编译）
```

### 双入口
- **QQPlayerApp.swift**：iOS 入口，编排初始化、iCloud 状态机、Siri / CarPlay / 小组件
- **QQPlayerMacApp.swift**：macOS 入口（含 `Settings` scene）

### 核心组件（服务层单例 + NotificationCenter 事件总线，轻 MVVM）
- **PlayerEngine**：AVAudioEngine 高级播放内核（后台播放、无缝预加载、ReplayGain、EQ 接入、NowPlaying / 远程控制、播放状态持久化、CarPlay 协同）；macOS 分支遇 Opus / OGG / DSD 委托 SFB 引擎，双引擎统一桥接
- **SFBAudioEngineManager**：SFBAudioEngine 封装——Opus / Vorbis / DSD 解码、DSD→PCM / DoP、EQ 处理图附加、元数据读写
- **DatabaseManager**：GRDB 数据访问层——曲库 CRUD + 逐列 ALTER 迁移 + 搜索（归一化分词）+ 去重合并 + 歌单 / 收藏 / 播放历史
- **LibraryIndexer**：曲库扫描与索引——iOS 用 NSMetadataQuery（iCloud），macOS 用 FileManager 目录扫描 + FSEvents 监控；元数据解析（时长 / 采样率 / 位深 / ReplayGain / 封面 / genre）
- **KaraokeController**：跟唱决策（句级推进、倍速、单句循环、AB 区间、句末自动暂停、延迟校准）——共享纯逻辑 + iOS 震动反馈隔离
- **LyricsManager / LyricsSearch / LyricsParsing**：歌词内嵌提取（FLAC Vorbis / ID3 USLT+SYLT / DSF）、网易云 eapi + LRCLIB 在线获取、磁盘缓存
- **NeteaseOnlineClient**：网易云共享客户端（eapi 加密 / 搜索 / 直链 / 歌曲详情补年份）——iOS 歌词与 macOS 在线下载共用同一层
- **QuarkClient / GequhaiClient**（macOS）：夸克网盘扫码登录与直链解析、歌曲海搜索（web 桌面版 provider 移植）
- **TagWriterService / TagRenameLogic / MusicBrainzClient / ScrapeLogic**（macOS）：标签刮削写回（SFBAudioEngine 原生写入 + 原子落盘 + 改名模板）
- **EQManager**：图形 EQ——预设管理、运行时频率 / 增益应用到双引擎
- **StateManager**：iCloud + 本地状态同步（收藏 / 歌单 / 播放器状态），原子写、损坏文件隔离
- **ArtworkManager**：封面提取（内嵌 / 文件头解析）+ 内存 + 磁盘缓存
- **CloudDownloadManager / FileCleanupManager**（iOS）：iCloud 文件按需落地与一致性清理
- **HybridMusicAPI / SpotifyAPI / DiscogsAPI**（iOS）：歌手资料——Spotify 优先、Discogs 兜底 + 磁盘缓存
- **AudioMetadataParser**：FLAC / MP3 / WAV / M4A / DSF 分域解析（含 genre、MP4 空 covr 清理）

### 数据库结构（GRDB / SQLite，迁移式演进）
核心表：`artist`（歌手）、`album`（专辑，含年份 / 专辑歌手）、`track`（曲目：文件指纹 stableId、时长 / 采样率 / 位深 / 声道、路径、ReplayGain、genre、内嵌封面标记）、`favorite`（收藏）、`playlist` / `playlist_item`（歌单与有序条目）、`play_history`（播放历史，驱动智能歌单）。曲库以文件 SHA-256 指纹（stableId）幂等索引，重命名 / 移动文件可自愈迁移。

### 平台隔离约定
- iOS 专属能力（AVAudioSession、UIKit、CarPlay、WidgetKit、AppIntents、iCloud）以 `#if os(iOS)` 收敛在共享文件内或独立文件中
- macOS target 通过显式文件白名单（membershipExceptions）只编译 Mac/ + 共享 Core，iOS 视图不进入 macOS 构建

### 测试与 CI
- QQPlayerTests 54 个测试文件，覆盖共享 Core 与双平台决策逻辑（数据库、歌词、跟唱、EQ、刮削、在线客户端、迷你模式状态机、快捷键决策、格式解析等）
- CI（GitHub Actions）：swiftlint + swiftformat → iOS 模拟器 `xcodebuild test` → macOS `QQPlayerMac` 构建 + 产物资源断言

---

## 安装与构建 🚀

### 环境要求
- **Xcode** 16+（推荐 Xcode 26+；项目使用 folder-synchronized groups 与 Swift 6 严格并发，日常开发与 CI 均基于 Xcode 26）
- **Git**
- iOS 端：有效的 Apple 开发者账号（iCloud / CarPlay / Siri 能力签名）与真机（iCloud 功能需要）

### 📱 iOS（App Store 版同源）

```bash
git clone git@github.com:daxmate/qqplayer-swift.git
cd qqplayer-swift
```

1. 打开 `QQPlayer.xcodeproj`，选择 **QQPlayer** scheme
2. 选择你的开发团队（签名需要：iCloud 容器 `iCloud.com.daxmate.qqplayer.ios`、App Group `group.com.daxmate.qqplayer.ios`、CarPlay / Siri entitlements）
3. 真机运行（iOS 18.5+）；单测可 `⌘U` 或命令行 `xcodebuild test -scheme QQPlayer`
4. **添加音乐**（二选一或混用）：
   - iCloud Drive：文件放入「iCloud Drive → QQPlayer」
   - 本地：文件放入「我的 iPhone → QQPlayer」（应用内「文件」导入亦可）
5. 首次启动自动扫描索引，即可开听

> 可选：歌手信息使用 Spotify / Discogs 时配置 API key（见下）。

### 🖥️ macOS（QQPlayerMac）

1. 打开 `QQPlayer.xcodeproj`，选择 **QQPlayerMac** scheme，直接 Run（无需开发者账号；应用非沙盒，直接读取本地文件夹）
2. 默认扫描 `~/Music/QQPlayer`（首次启动自动创建），把音乐放进去即自动入曲库；也可以在 **设置 → 音乐库** 添加外部文件夹，或直接把文件**拖入窗口 / 歌单行**导入
3. 在线下载：工具栏云下载按钮（网易云 / 歌曲海；夸克源首次需扫码登录）；标签刮削：曲库列表右键「编辑标签 / 刮削」

> 命令行构建：`xcodebuild build -scheme QQPlayerMac -derivedDataPath build/DerivedDataMac`（先 `unset CC CXX` 避免 Homebrew gcc 劫持 SPM 编译）。

### 🔑 环境变量（全部可选）

复制 `.env.template` 为 `.env` 并填入所需凭据；`.env` 需随构建加入 App bundle（或使用 Xcode 环境变量）。以下 key **全部可选**——未配置不会导致崩溃：歌手网络资料自动降级（缓存仍可用），其余功能不受影响：

```bash
SPOTIFY_CLIENT_ID=
SPOTIFY_CLIENT_SECRET=
DISCOGS_CONSUMER_KEY=
DISCOGS_CONSUMER_SECRET=
```

---

## 依赖 📦

### Swift 包
- **SFBAudioEngine**（sbooth，0.13.0）：Opus / OGG / DSD 等格式解码、DSD→PCM / DoP、元数据读写（含标签刮削写回引擎）
- **GRDB.swift**：SQLite 数据访问（曲库 / 歌单 / 播放历史）

### 系统框架
SwiftUI、Combine、AVFoundation / AVFAudio、UIKit（iOS）/ AppKit（macOS）、MediaPlayer（macOS 媒体键）、CarPlay（iOS）、Intents / AppIntents（iOS）、WidgetKit（iOS）、UniformTypeIdentifiers、CryptoKit、ImageIO

### 在线服务（按功能启用，无强制 key）
| 服务 | 用途 | 平台 | API Key |
|------|------|------|---------|
| 网易云音乐（eapi） | 同步歌词（含中文翻译）、在线搜索下载源 | 双平台 | 无 |
| LRCLIB | 歌词兜底源 | 双平台 | 无 |
| MusicBrainz + Cover Art Archive + iTunes Search | 标签刮削候选源 | macOS | 无 |
| 歌曲海（Gequhai） | 在线搜索源（结果指向夸克分享） | macOS | 无 |
| 夸克网盘 | 在线下载直链（扫码登录） | macOS | 无 |
| Spotify / Discogs | iOS 歌手资料（双源 + 缓存） | iOS | **可选** |

---

## 目录结构 📂

```
QQPlayer.xcodeproj            # 工程（QQPlayer iOS / QQPlayerMac 双 target 与 scheme）
QQPlayer/
├── QQPlayerApp.swift         # iOS 入口
├── QQPlayerMacApp.swift      # macOS 入口（Settings scene）
├── CarPlaySceneDelegate.swift / CarPlay+Playback.swift
├── ContentView.swift
├── Mac/                      # macOS UI（三栏、播放页、迷你模式、在线搜索、刮削编辑器等 35 文件）
├── Services/                 # 共享 Core：播放引擎 / 歌词 / 跟唱 / EQ / 索引 / 在线客户端 / 刮削等
├── Models/                   # 共享数据模型（Database / Settings / State / SFB）
├── Views/                    # iOS SwiftUI 视图（Library / Player / Playlists / Artists / Albums / Utility）
├── ViewModels/               # TutorialViewModel 等
├── Helpers/                  # EnvironmentLoader / LocalizationHelper / ObjCExceptionCatcher
├── Resources/                # 5 语言本地化（zh-Hans / zh-Hant / en / fr / ru）
├── Assets.xcassets
└── QQPlayer.entitlements
PlayerWidget/                 # iOS 主屏幕小组件
Share/                        # iOS 分享扩展
SiriIntentsExtension/         # iOS Siri 意图扩展
QQPlayerTests/                # Swift Testing 单测（54 文件，含 Fixtures 与 Mock）
QQPlayerSiriTests/            # Siri 集成测试（需 Xcode 27 SDK，CI 已豁免）
scripts/                      # 工程工具（add-test-file.py / add-grdb-to-tests.py / gen-zh-hant.py / pbxproj-membership.py / git-hooks）
.github/workflows/ci.yml      # CI：lint/format + iOS 单测 + macOS 构建与资源断言
LICENSE / NOTICE.md / PRIVACY.md
```

---

## 参与贡献 🤝

欢迎贡献代码、翻译与 issue 反馈！

- **分支流程**：从 `main` 建 `feat/xxx` 或 `fix/xxx` 分支 → 提交 → PR 合入 `main`（CI 必须绿）
- **提交信息**：conventional commits——`feat(scope): 描述` / `fix(scope): 描述` / `docs` / `refactor` / `test` / `chore`（scope 如 `mac`、`ios`、`lyrics`、`carplay`）
- **代码风格**：提交前跑 `swiftlint lint` 与 `swiftformat --lint .`（双 target 都须通过）
- **测试**：共享逻辑与双平台决策逻辑必须配 Swift Testing 单测；新测试文件用 `python3 scripts/add-test-file.py <文件>` 注册进 QQPlayerTests target；涉及共享 Services 新文件时同步登记 QQPlayerMac target 文件白名单（pbxproj membershipExceptions）与 iOS 侧（synchronized folder 自动包含）
- **改动范围**：macOS 新 UI 文件放 `QQPlayer/Mac/`；iOS 专属放 `Views/` 或扩展 target；共享逻辑放 `Services/`
- **本地化**：新 UI 文案补全 5 语言 key（zh-Hans / zh-Hant / en / fr / ru）
- 注意：GitHub Actions 的 iOS 单测在模拟器运行；涉及 iCloud / CarPlay / 真机行为请在真机验证并在 PR 描述注明

---

## 安全与隐私 🔒

- **本地播放器**：无账号系统、无广告 SDK、无统计分析、无第三方追踪、无数据收集
- **音乐文件不离开设备**：仅存储在设备本地或你自己的 iCloud Drive（由 Apple 服务同步，适用 Apple 隐私政策）
- **网络请求仅发最小必要信息**：播放歌曲并请求歌词 / 刮削时，向第三方服务（网易云、LRCLIB、MusicBrainz 等）发送**歌曲标题与歌手名**用于匹配，结果仅保存在本地
- **API Key**：通过环境变量注入（可选），不硬编码、不上传
- **离线优先**：本地文件与歌词缓存完全离线可用
- 完整隐私政策（中英双语，App Store 提交版本）见 **[PRIVACY.md](PRIVACY.md)**

---

## 常见问题 🔧

**iOS：看不到导入的音乐？**
检查文件位置（iCloud Drive → QQPlayer 或 我的 iPhone → QQPlayer）、格式是否为支持的音频，并确认 iCloud 已登录（iCloud 文件首次需下载落地）。

**macOS：曲库是空的？**
确认音乐在曲库文件夹（默认 `~/Music/QQPlayer`）或已添加的外部文件夹内；可在设置中「立即扫描」或查看 `~/Library/Logs/QQPlayerMac/scan.log`。

**macOS：下载歌曲失败？**
查看面板红字原因——会员 / VIP / 版权受限歌曲（网易云）无可用源属正常；夸克源需先扫码登录。

**歌词不显示 / 显示原文无翻译？**
先手动搜索指定歌词（搜索页），或检查网络；网易云头部带 credits 的歌词会被识别为纯歌词页。

**歌手信息空白？（iOS）**
网络歌手资料需要 Spotify / Discogs API key（可选配置）；未配置时无网络档案，不影响播放与曲库。

**报告问题**：请说明平台与版本（iOS / macOS、App 版本号）、复现步骤、预期与实际行为；macOS 可附 `~/Library/Logs/QQPlayerMac/` 下的日志。

---

## 致谢 🎨

- **上游项目**：[Cosmos Music Player](https://github.com/clquwu/Cosmos-Music-Player) 及其作者 [@clquwu](https://github.com/clquwu)（Raphael Boullay Le Fur）——本项目基于其 GPL-3.0 开源代码二次开发，fork 与修改声明见 [NOTICE.md](NOTICE.md)
- **歌词 API**：[LRCLIB](https://github.com/tranxuanthang/lrclib)（作者 tranxuanthang）
- **音频引擎**：[SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine)（作者 sbooth）
- **数据层**：[GRDB.swift](https://github.com/groue/GRDB.swift)（作者 groue）
- 元数据与资料服务：MusicBrainz、Cover Art Archive、Discogs、Spotify——我们与这些服务无任何经济关联，仅为提供更好的使用体验

---

## 作者与联系 👥

- **维护者：daxmate**（<https://github.com/daxmate>）
- 问题、需求与建议：请在仓库提交 **issue**（<https://github.com/daxmate/qqplayer-swift/issues>）
- 上游作者联系方式见 [NOTICE.md](NOTICE.md)（仅供上游项目相关事宜）

---

## 许可证 📄

本项目基于 **GNU GPL-3.0** 许可发布，详见 [LICENSE](LICENSE) 与 [NOTICE.md](NOTICE.md)。

---

**祝你享受 QQPlayer 带来的高品质音乐体验！** 🎵✨

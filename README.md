# QQPlayer 🎵

> **fork 声明**：本项目基于 [Cosmos Music Player](https://github.com/clquwu/Cosmos-Music-Player)（GPL-3.0，作者 Raphael Boullay Le Fur）二次开发，详见 [NOTICE.md](NOTICE.md)。本仓库整体以 GPL-3.0 发布。

QQPlayer 是一款 **iOS + macOS 双平台高品质音乐播放器**，专为发烧友与外语学习者打造。

- 支持 FLAC、WAV、M4A、MP3、Opus、OGG、DSD（DoP / PCM 转换）、DSF 等格式
- 内建图形均衡器、ReplayGain 音量标准化、双源歌词、跟唱练习（倍速 / AB 循环）
- **局域网配对与同步**：Mac 与 iPhone 扫码配对、端到端加密会话、音乐文件分块传输与校验、播放数据与对齐歌词随歌同步
- iOS 端深度整合 Apple 生态：本地沙盒音乐库、CarPlay、Siri、主屏幕小组件
- macOS 原生版（QQPlayerMac）提供桌面级体验：本地曲库扫描、在线搜索下载（网易云 / 歌曲海 + 夸克网盘，aria2 下载引擎）、标签刮削（MusicBrainz）、迷你模式与桌面歌词窗

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
- 共享 Core 层：**132 个服务 / 模型文件直接共享给双平台**（`Services` / `Models` / `Helpers` / `Sync` 共 136 个，其中 132 个进 macOS 构建：117 个无平台分支 + 15 个含 `#if os(iOS)` 隔离段），4 个 iOS 专属 Core 文件（沙盒迁移执行器、中断恢复策略、iOS 同步浏览 / 被动应答）不进 macOS 构建
- **936 个自动化测试用例**（86 个测试文件 / 100 个 suite，Swift Testing）+ GitHub Actions CI（lint/format + iOS 单测 + macOS 构建与资源断言 + 编译警告零容忍）
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
- **本地沙盒存储**：音乐统一放在 App 沙盒 `Documents`（「文件」App 可见，可直接拖入 / Share 扩展导入），启动自动扫描索引
- **iCloud → 沙盒一次性迁移**：首次启动自动把旧 iCloud 容器里的存量音乐实体化复制到本地沙盒，按内容指纹（`content_hash`）去重、幂等可断点，迁完切索引
- 智能索引自动发现音乐，完全离线可用（无需 iCloud 登录）

**👤 歌手信息**
- Spotify + Discogs 双源（可选 API key，见「依赖 📦」），歌手生平、照片，缓存离线可用，支持「歌手不对？」切换来源

**🎤 Siri**
- AppIntents + 意图扩展：支持「播放我的音乐 / 收藏 / 歌单 / 指定歌曲」等命令，名称模糊匹配（示例：*"Hey Siri, play my favorites on QQPlayer"* / *"Dis Siri, joue mes favoris sur QQPlayer"*）

**🌍 国际化与存储**
- 5 语言本地化；音乐存本地沙盒（无需 iCloud 登录）；无网络完整可用（本地文件）

**🧩 系统集成**
- 主屏幕小组件（PlayerWidget）、分享扩展（Share）、CarPlay、Siri
- 局域网同步：设置 →「同步」扫码配对 Mac、管理已配对主机（详见下文「局域网配对与同步」）

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
- **歌曲海（Gequhai）** 搜索源 + **夸克网盘** 直链下载：二维码扫码登录、会话保活（`__puus`）、分享链接解析、音质挑选
- 源切换（网易云 / 歌曲海），下载编排 `.part` 原子落盘 → 自动入曲库（重名自动递增序号）
- **下载引擎**：内置 HTTP（URLSession）或 **aria2 JSON-RPC**（本机 daemon，RPC 地址 / Secret 可配），引擎不可用时自动降级内置 HTTP；支持限速（MB/s，0 = 不限速）
- **下载进度圆环**：行尾实时进度（总长未知时转圈），网易云 / 歌曲海统一
- **搜索历史**：两源合并列表（上限 10，同词去重置顶），点历史项 = 填词 + 切源 + 立即搜索
- **SearchAnything 全屏搜索**（⌘K）：本地歌曲 / 在线下载 / 歌手 / 专辑 / 设置分类一处直达
- 设置「下载」分类：网易云音质档位、歌曲海音质（MP3 / FLAC）、下载引擎与 aria2 参数、限速（落盘目录固定为曲库文件夹）

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
- 设置窗口系统化（Settings scene，⌘,），左侧分类导航（含「同步」分类：本机二维码 / 已配对设备 / 配对批准）；封面 artwork 全接入（专辑 / 歌单 / 搜索行 + `cover.jpg` 兜底）
- 帮助中心 / 新功能弹窗（WhatsNew）/ 首次提示气泡
- 运行时日志落盘（`~/Library/Logs/QQPlayerMac/stdout.log` 等），问题可直接读日志定位

---

## 局域网配对与同步 🔗

> Mac 与 iPhone 之间不经云端的点对点同步：扫码配对、端到端加密、音乐与播放数据双向补齐——全部在你自己的局域网内完成。

**角色与拓扑**

```
macOS QQPlayer（主机 / 内容源）        iOS QQPlayer（移动端）
├─ 曲库 ~/Music/QQPlayer          ├─ 本地沙盒 Documents 曲库
├─ 内嵌同步服务（App 运行即在听）    ├─ 同步客户端（活跃时自动回连）
└─ 本地数据库（真源）              └─ 本地数据库（同 schema）
```

- 一台 iPhone 可配对多台 Mac，每台主机独立同步；同步的发起方恒为 Mac（移动端为被动端）
- 协议层（帧编解码 / 配对状态机 / 对账 / 变更日志）是双平台共享的纯逻辑代码，macOS 与 iOS 同一套契约

**配对**

- 每端首次启动生成长期 **Ed25519 身份密钥**（私钥存 Keychain），**Device ID = 公钥 SHA-256 指纹**（可读短码展示）
- **扫码为主路径**：Mac「设置 → 同步」展示二维码（含主机名 / Device ID / 公钥 / 一次性 nonce）→ iPhone 扫码并确认 → **Mac 弹窗人工批准** → 双向落信任记录
- **手动输入备选**：Mac 显示分组 Device ID 文本，iPhone 手动输入走同一握手流程
- TOFU 信任模型：无密码、无 CA、离线可用；撤销配对 = 删除对方信任记录，之后连接验指纹失败即拒

**发现**

- Bonjour / mDNS 服务类型 `_qqplayer-sync._tcp`（广播设备名 + 协议版本，**不广播完整 Device ID**）
- 广播内容仅用于发现与展示，真实身份在握手中以配对记录里的公钥 pinning 校验

**加密会话**

- 握手：双方各生成临时 **X25519** 密钥对 + 各自 Ed25519 长期签名 → 验证对端签名与指纹 → **X25519 ECDH + HKDF-SHA256** 派生双向会话密钥 → 业务帧一律 **ChaCha20-Poly1305** 加密（AAD = 帧头，nonce 为方向计数器）
- 帧格式：`QQP1 | 长度(4B) | type(1B) | flags(1B) | payload`（单帧上限 16MB，越界拒绝）
- 由此覆盖局域网窃听、中间人、冒充已配对设备、重放等威胁

**文件同步**

- **跨端歌曲身份 = 文件内容 SHA-256（`content_hash`）**（本地 `stableId` 是路径哈希，跨端不一致，不能作对账键）；入库时计算一次，老库首次启动后台惰性回填
- 流程：manifest（相对路径 / 大小 / mtime / content_hash）对账 → 取「缺失或内容不同」的条目 → 分块传输 → 校验 → 入库；支持**两个方向**（Mac 推送到设备 / 从设备下载回 Mac，把手机导入的内容取回）
- 传输：256KB 分块停等 + `.part` 原子落盘 + **断点续传**（offset 对齐续写）+ **整文件 SHA-256 校验**（不符即删除重传）；路径越界与软链逃逸一律拒绝
- **同步集合 = 用户显式选择的歌单 / 歌曲**，不做全库自动镜像（移动端容量有限）

**数据同步**

- **播放数据双向同步（LWW）**：收藏、播放历史 / 次数（智能歌单数据源）、歌单结构等走本地变更日志（outbox）+ per-peer 游标，增量对账、`updated_at` 大者胜
- **仅同步两端共有的歌**（以 `content_hash` 配对），**跟歌走**——推 / 拉歌曲时把这首歌的播放数据一并带过去
- **不传播删除**：任一端删除歌曲 / 取消收藏 / 删歌单都只在本地生效，同步只做「补齐缺失 + 内容不同则更新」，**永不跨端删文件或数据**
- **对齐歌词随歌同步**：仅 `aligned`（对齐产物）类型歌词参与同步，以 `@lyrics/{content_hash}.json` 命名空间随歌复制；手动指定与网络缓存歌词默认不同步

**平台入口与权限**

- macOS：设置 →「同步」——本机设备名 / Device ID / 二维码、已配对设备管理与撤销、配对请求批准卡
- iOS：设置 →「同步」——扫码配对 / 手动输入主机 ID / 已配对主机管理
- iOS 需**本地网络权限**：`NSLocalNetworkUsageDescription` 文案 + `NSBonjourServices`（`_qqplayer-sync._tcp`）已随 App 声明（macOS 版非沙盒，无需额外授权）

---

## 技术架构 🏗️

```
QQPlayerApp.swift（iOS 入口）      QQPlayerMacApp.swift（macOS 入口）
        │                                  │
        └──────────► 共享 Core ◄───────────┘
   （Services / Models / Sync / Helpers，132 文件直接共享：117 无分支 + 15 #if os(iOS)）
        │
        ├── iOS 专属：Views/（SwiftUI）、CarPlaySceneDelegate、PlayerWidget / Share / SiriIntentsExtension
        └── macOS 专属：Mac/（41 个视图与窗口文件，经 target 白名单编译）
```

### 双入口
- **QQPlayerApp.swift**：iOS 入口，编排初始化、沙盒存量迁移、Siri / CarPlay / 小组件（iCloud 状态机已退役）
- **QQPlayerMacApp.swift**：macOS 入口（含 `Settings` scene）

### 核心组件（服务层单例 + NotificationCenter 事件总线，轻 MVVM）
- **PlayerEngine**：AVAudioEngine 高级播放内核（后台播放、无缝预加载、ReplayGain、EQ 接入、NowPlaying / 远程控制、播放状态持久化、CarPlay 协同）；macOS 分支遇 Opus / OGG / DSD 委托 SFB 引擎，双引擎统一桥接
- **SFBAudioEngineManager**：SFBAudioEngine 封装——Opus / Vorbis / DSD 解码、DSD→PCM / DoP、EQ 处理图附加、元数据读写
- **DatabaseManager**：GRDB 数据访问层——曲库 CRUD + 逐列 ALTER 迁移 + 搜索（归一化分词）+ 去重合并 + 歌单 / 收藏 / 播放历史
- **LibraryIndexer**：曲库扫描与索引——**两平台统一用 FileManager 目录枚举**（iOS 扫沙盒 `Documents`，macOS 扫曲库目录 + FSEvents 监控）；元数据解析（时长 / 采样率 / 位深 / ReplayGain / 封面 / genre）
- **KaraokeController**：跟唱决策（句级推进、倍速、单句循环、AB 区间、句末自动暂停、延迟校准）——共享纯逻辑 + iOS 震动反馈隔离
- **LyricsManager / LyricsSearch / LyricsParsing**：歌词内嵌提取（FLAC Vorbis / ID3 USLT+SYLT / DSF）、网易云 eapi + LRCLIB 在线获取、磁盘缓存
- **NeteaseOnlineClient**：网易云共享客户端（eapi 加密 / 搜索 / 直链 / 歌曲详情补年份）——iOS 歌词与 macOS 在线下载共用同一层
- **QuarkClient / GequhaiClient**（macOS）：夸克网盘扫码登录与直链解析、歌曲海搜索（web 桌面版 provider 移植）
- **TagWriterService / TagRenameLogic / MusicBrainzClient / ScrapeLogic**（macOS）：标签刮削写回（SFBAudioEngine 原生写入 + 原子落盘 + 改名模板）
- **EQManager**：图形 EQ——预设管理、运行时频率 / 增益应用到双引擎
- **StateManager**：本地状态 JSON（收藏 / 歌单 / 播放器状态）原子写、损坏文件隔离（iCloud 镜像层已退役，DB 为单一事实源）
- **ArtworkManager**：封面提取（内嵌 / 文件头解析）+ 内存 + 磁盘缓存
- **FileCleanupManager**（iOS）：磁盘删除 / 收录格式变更后的曲库一致性清理
- **SandboxMusicMigrator**（iOS）：iCloud 容器 → 沙盒 Documents 的一次性存量迁移（计划器纯逻辑 + 执行器，幂等可断点）；旧的 iCloud 按需落地管理器 `CloudDownloadManager` 已随沙盒改造退役

- **HybridMusicAPI / SpotifyAPI / DiscogsAPI**（iOS）：歌手资料——Spotify 优先、Discogs 兜底 + 磁盘缓存
- **AudioMetadataParser**：FLAC / MP3 / WAV / M4A / DSF 分域解析（含 genre、MP4 空 covr 清理）

**局域网同步（`Sync/`，双平台共享协议层）**
- **SyncIdentity / DeviceID / DeviceStore**：Ed25519 长期身份（私钥存 Keychain）、公钥 SHA-256 指纹 Device ID、配对记录持久化（`sync_device`）
- **PairingStateMachine / SyncPairingFlow**：配对状态机与扫码 / 手输两条流程（协议版本 / 指纹 / 一次性 nonce 校验全在状态机内）
- **SyncPeerSession / SyncFrame / SyncCrypto**：长度前缀帧协议、X25519 ECDH + HKDF-SHA256 握手、双向 ChaCha20-Poly1305 会话加密
- **SyncListener / SyncBrowser**：Host 侧 NWListener + Bonjour 广播、Client 侧 mDNS 浏览与回连
- **SyncFileSender / SyncFileReceiver / SyncFileChecksum**：分块停等传输、断点续传、SHA-256 整文件校验
- **SyncManifestGenerator / SyncManifestReconciler**：manifest 生成与对账纯逻辑（集合过滤 / 跨端路径映射）
- **SyncChangeLogStore / SyncLWWReconcile / SyncChangeLogDeletionPolicy**：变更日志（`sync_outbox`）+ per-peer 游标（`sync_cursor`）、LWW 对账、「删除不传播」的单一事实源
- **SyncAlignedLyrics / SyncLyricsReceiver**：`aligned` 歌词线上命名空间（`@lyrics/{content_hash}.json`）与随歌安装
- **SyncLibraryPushController / SyncLibraryPullController / SyncCollectionSyncCoordinator**：发起端（Mac）推送 / 拉取控制器与选中集合的补齐编排
- **SyncPlaybackCarryPlan / SyncPlaybackCarryPeer**：播放数据「跟歌走」的计划器与执行
- **SyncLocalLibraryProvider / MacSyncLibraryHost / SyncLibraryFetchResponder**：曲库事实 → 协议应答的装配层（越界 / 软链一律拒读）

### 数据库结构（GRDB / SQLite，迁移式演进）
核心表：`artist`（歌手）、`album`（专辑，含年份 / 专辑歌手）、`track`（曲目：文件指纹 stableId、**跨端内容指纹 content_hash**、时长 / 采样率 / 位深 / 声道、路径、ReplayGain、genre、内嵌封面标记）、`favorite`（收藏）、`playlist` / `playlist_item`（歌单与有序条目）、`play_history`（播放历史，驱动智能歌单）。

局域网同步相关表：`sync_device`（已配对设备信任记录）、`sync_outbox`（本地变更日志，LWW 键 = entity + row_key）、`sync_cursor`（per-peer 游标）、`sync_pending_change`（引用未就位时挂起、入库后重放的变更）。曲库以文件 SHA-256 指纹（stableId）幂等索引，重命名 / 移动文件可自愈迁移；跨端对账则按内容指纹 `content_hash`（老库首次启动惰性回填，并建索引）。

### 平台隔离约定
- iOS 专属能力（AVAudioSession、UIKit、CarPlay、WidgetKit、AppIntents）以 `#if os(iOS)` 收敛在共享文件内或独立文件中；iCloud 相关链路已退役（仅保留一次性存量迁移读取）
- macOS target 通过显式文件白名单（membershipExceptions，去重后 178 个文件条目）只编译 Mac/ + 共享 Core，iOS 视图不进入 macOS 构建

### 测试与 CI
- QQPlayerTests：**83 个测试文件 / 936 个用例 / 100 个 suite**，覆盖共享 Core 与双平台决策逻辑（数据库、歌词、跟唱、EQ、刮削、在线客户端、迷你模式状态机、快捷键决策、格式解析、局域网同步全链等）
- 无模拟器 harness：`scripts/run-local-sync-tests.sh` 用 `swiftc` 直编生产源码（Sync 纯逻辑 + 扫描器）真跑断言，覆盖帧编解码 / 路径解析 / 应答器计划 / 控制器状态机 / 端到端场景
- CI（GitHub Actions）三个环节：① swiftlint + swiftformat ② iOS 模拟器 `xcodebuild test`（936 用例）③ macOS `QQPlayerMac` 构建 + 产物资源断言；两个 job 均带**编译警告零容忍**检测 step
- 本地提交钩子（`scripts/git-hooks/pre-commit`）同样拦截增量编译警告，不等 CI

---

## 安装与构建 🚀

### 环境要求
- **Xcode** 16+（推荐 Xcode 26+；项目使用 folder-synchronized groups 与 Swift 6 严格并发，日常开发与 CI 均基于 Xcode 26）
- **Git**
- iOS 端：有效的 Apple 开发者账号（CarPlay / Siri 能力签名）与真机
- 依赖已锁定：`QQPlayer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` 已入库，SPM 版本可复现构建

### 📱 iOS（App Store 版同源）

```bash
git clone git@github.com:daxmate/qqplayer-swift.git
cd qqplayer-swift
```

1. 打开 `QQPlayer.xcodeproj`，选择 **QQPlayer** scheme
2. 选择你的开发团队（签名需要：App Group `group.com.daxmate.qqplayer.ios`、CarPlay / Siri entitlements）
3. 真机运行（iOS 18.5+）
4. **添加音乐**（二选一）：
   - 应用内「文件」导入 / Share 扩展导入（推荐）
   - 直接放「文件」App → 我的 iPhone → QQPlayer → Documents 目录
5. 首次启动自动扫描沙盒并索引，即可开听；若旧版本曾用 iCloud 存音乐，首次启动会自动迁移到本地沙盒（幂等可断点）

> 可选：歌手信息使用 Spotify / Discogs 时配置 API key（见下）。

### 🖥️ macOS（QQPlayerMac）

1. 打开 `QQPlayer.xcodeproj`，选择 **QQPlayerMac** scheme，直接 Run（无需开发者账号；应用非沙盒，直接读取本地文件夹）
2. 默认扫描 `~/Music/QQPlayer`（首次启动自动创建），把音乐放进去即自动入曲库；也可以在 **设置 → 音乐库** 添加外部文件夹，或直接把文件**拖入窗口 / 歌单行**导入
3. 在线下载：工具栏云下载按钮（网易云 / 歌曲海；夸克源首次需扫码登录）；标签刮削：曲库列表右键「编辑标签 / 刮削」

> **命令行构建（推荐统一入口）**：`scripts/xcbuild.sh` 已固化共享 SPM 缓存（`-clonedSourcePackagesDirPath`）与按工作区隔离的 DerivedData（`/tmp/dd-<工作区名>`，可用 `QQPLAYER_DD` 覆盖），避免每次新路径重新 clone 全部依赖：
>
> ```bash
> scripts/xcbuild.sh build -scheme QQPlayerMac -destination 'platform=macOS'
> scripts/xcbuild.sh build-for-testing -scheme QQPlayer -destination 'generic/platform=iOS Simulator'   # 单测构建
> scripts/xcbuild.sh test -scheme QQPlayer -destination 'platform=iOS Simulator,name=iPhone 17 Pro'      # 单测执行
> ```
>
> 若不用该脚本，直接跑 `xcodebuild` 时记得自己补 `-derivedDataPath`；另：构建前 `unset CC CXX` 可避免 Homebrew gcc 劫持 SPM 的 C/C++ 依赖编译（`build.sh` 已内置）。

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
> 版本已由锁定文件 `QQPlayer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` 锁定（共 21 个包，含 SFBAudioEngine 的各类解码器 xcframework 子依赖），换机器 / CI 构建可复现。

- **SFBAudioEngine**（sbooth，0.13.0）：Opus / OGG / DSD 等格式解码、DSD→PCM / DoP、元数据读写（含标签刮削写回引擎）
- **GRDB.swift**（groue，6.29.3）：SQLite 数据访问（曲库 / 歌单 / 播放历史 / 同步变更日志）

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
├── Mac/                      # macOS UI（三栏、播放页、迷你模式、在线搜索、刮削编辑器、同步中心等 41 文件）
├── Services/                 # 共享 Core：播放引擎 / 歌词 / 跟唱 / EQ / 索引 / 在线客户端 / 刮削 / aria2 等 80 文件
├── Sync/                     # 局域网配对与同步协议层（48 文件：帧 / 加密 / 配对 / manifest / 文件传输 / 变更日志 / 歌词）
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
QQPlayerTests/                # Swift Testing 单测（83 测试文件 + Fixtures/Mock，936 用例）
QQPlayerSiriTests/            # Siri 集成测试（需 Xcode 27 SDK，CI 已豁免）
scripts/                      # 工程工具（xcbuild.sh 统一构建入口 / add-test-file.py / add-grdb-to-tests.py / gen-zh-hant.py /
                              #   pbxproj-membership.py / run-local-sync-tests.sh / sync-harness / git-hooks）
.env.template                 # 可选 API Key 模板（复制为 .env）
build.sh                      # iOS 一键构建 / 真机安装脚本
.github/workflows/ci.yml      # CI：lint/format + iOS 单测 + macOS 构建与资源断言（含编译警告零容忍）
LICENSE / NOTICE.md / PRIVACY.md
```

---

## 参与贡献 🤝

欢迎贡献代码、翻译与 issue 反馈！

- **分支流程**：从 `main` 建 `feat/xxx` 或 `fix/xxx` 分支 → 提交 → PR 合入 `main`（CI 必须绿）
- **提交信息**：conventional commits——`feat(scope): 描述` / `fix(scope): 描述` / `docs` / `refactor` / `test` / `chore`（scope 如 `mac`、`ios`、`lyrics`、`carplay`）
- **代码风格**：提交前跑 `swiftlint lint` 与 `swiftformat --lint .`（双 target 都须通过）
- **测试**：共享逻辑与双平台决策逻辑必须配 Swift Testing 单测；新测试文件用 `python3 scripts/add-test-file.py <文件>` 注册进 QQPlayerTests target；涉及共享 Services 新文件时同步登记 QQPlayerMac target 文件白名单（pbxproj membershipExceptions）与 iOS 侧（synchronized folder 自动包含）
- **改动范围**：macOS 新 UI 文件放 `QQPlayer/Mac/`；iOS 专属放 `Views/` 或扩展 target；共享逻辑放 `Services/`；局域网同步协议层放 `Sync/`（双平台共享，注意线上帧类型 10–13 已冻结、新增从 14 起）
- **本地验证**：构建统一走 `scripts/xcbuild.sh`（共享 SPM 缓存 + 隔离 DerivedData）；同步纯逻辑改动可先跑 `scripts/run-local-sync-tests.sh` 无模拟器真跑断言
- **本地化**：新 UI 文案补全 5 语言 key（zh-Hans / zh-Hant / en / fr / ru）
- 注意：GitHub Actions 的 iOS 单测在模拟器运行；涉及局域网同步 / CarPlay / 真机行为请在真机验证并在 PR 描述注明

---

## 安全与隐私 🔒

- **本地播放器**：无账号系统、无广告 SDK、无统计分析、无第三方追踪、无数据收集
- **音乐文件不离开设备**：iOS 端存于 App 本地沙盒（iCloud 容器链路已退役），macOS 端就是你自己的曲库文件夹
- **局域网同步**：Mac 与 iPhone 之间直接点对点传输，不经任何中转服务器；配对靠扫码 + Ed25519 指纹，会话全程 X25519 ECDH + ChaCha20-Poly1305 加密，密钥只在两台设备上
- **网络请求仅发最小必要信息**：播放歌曲并请求歌词 / 刮削时，向第三方服务（网易云、LRCLIB、MusicBrainz 等）发送**歌曲标题与歌手名**用于匹配，结果仅保存在本地
- **API Key**：通过环境变量注入（可选），不硬编码、不上传
- **离线优先**：本地文件与歌词缓存完全离线可用
- 完整隐私政策（中英双语，App Store 提交版本）见 **[PRIVACY.md](PRIVACY.md)**

---

## 常见问题 🔧

**iOS：看不到导入的音乐？**
确认文件在「文件」App → 我的 iPhone → QQPlayer（或经应用内导入 / 分享导入）；再确认格式是否受支持。旧版放在 iCloud 的音乐会在首次启动时自动迁移到本地沙盒，请保持 App 在前台等迁移完成。

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

//
//  MacSyncView.swift
//  QQPlayer
//
//  局域网同步（S2/M6；2026-09-26 批 B1「拆 Pane + 顶层两页」）macOS **同步中心主体**
//  （QQPlayerMac target only）：`MacSyncCenterView` 的 `Form` 内渲染的全部内容。
//
//  顶层两页（用户 2026-09-26 拍板；分段控件切换，**同一时刻只渲染一页**）：
//   · 「设备」（低频/配置）：待批准请求 · 本机身份与二维码 · 连接状态（含「允许局域网连接」开关）·
//     已配对设备列表（在线态 / 最后在线 / 撤销配对）· 本次同步目标
//   · 「同步」：顶部分段切换「传歌 / 播放数据」，两流**永不共用一屏**（跨端续播开关归本页）
//
//  拆法（批 B1 硬约束 R1「拆 View 不拆模型」）：一个状态模型 + 三份呈现 ——
//  `SyncHostCenter` 与各 ViewModel（`MacSyncRunViewModel` / `MacSyncContentModel` /
//  `MacSyncDataViewModel`）**一行不动**，只拆视图。三块 Pane 各自独立成文件：
//   · `SyncDevicePane.swift` → 「设备」页
//   · `SyncTracksPane.swift` → 「同步」页（分段控件 + 传歌流）
//   · `SyncDataPane.swift`  → 播放数据流（= 原 F 数据同步区）
//  原分区文件（`+Connection` / `+Content` / `+Run`）继续承载各分区本体（A 并入设备页）。
//
//  ⚠️ 为什么 Pane 是「本类型的 extension」而不是独立 struct：三个 ViewModel 仍是
//  `ObservableObject`（`@Observable` 迁移尚未覆盖它们），子视图要拿到**活的**重绘就必须写
//  `@ObservedObject` / `@StateObject`——而 `ObservationMigrationContractTests` 是**按
//  (文件, 标记) 的棘轮**（新增 (文件, 标记) 即红，方向只许减不许增）。把 Pane 写成
//  extension 是唯一「零新增标记、零行为改变」的拆法（也正合 R1：唯一实现保在模型层，
//  唯一的是**状态**、不是视图）。
//
//  ⚠️ 状态归属：两页的**全部 `@State` / `@StateObject` 都留在本文件**（唯一观察者），
//  页切换只切渲染内容、不卸载本类型 ⇒ ViewModel 生命周期与拆分前逐字一致
//  （页切换不会丢在途传输结果、不打断对端清单加载）。
//
//  纪律：本文件**只做展示**——能不能开始 / 现在什么阶段 / 进度多少 / 结果怎么算，
//  全部来自 `MacSyncRunViewModel` + `MacSyncContentModel` + `MacSyncDataViewModel` +
//  `SyncDeviceListModel` + `SyncUIState` / `SyncUIDirectionContent`（纯逻辑，有单测）。
//  View 里不写判断。
//
//  ⚠️ 历史（2026-09-18 前）：曾要求「macOS 13 兼容：不使用 macOS 14+ API（`onChange` 单参数闭包、
//  不用 `ContentUnavailableView`）」。同日部署目标提到 14.0，此约束解除；
//  文件内的 `onChange` 已改为两参数签名。新增代码仍以「不引入 macOS 15+ API」为惯例。
//

import AppKit
import SwiftUI

/// 同步中心顶层页（2026-09-26 批 B1；分段控件切换，同一时刻只渲染一页）。
enum MacSyncPage: Hashable {
    /// 设备页（低频/配置：待批准请求 / 身份与二维码 / 连接状态 / 已配对设备 / 局域网开关）。
    case device
    /// 同步页（分段切「传歌 / 播放数据」）。
    case sync
}

/// 「同步」页的两个流（分段控件切换；同一时刻只渲染一个，两流永不共用一屏）。
enum MacSyncFlow: Hashable {
    /// 传歌（文件传输：方向 / 内容 / 执行 / 结果）。
    case tracks
    /// 播放数据（收藏 / 播放历史 / 歌单结构）。
    case data
}

/// 同步中心主体（在 `MacSyncCenterView` 的 `Form` 内渲染）。
struct MacSyncRunSection: View {
    /// 2026-09-20 批 6-8：中心迁 `@Observable` ⇒ 视图侧改**组合根环境注入**（读属性即按需重绘）。
    /// 两个入口（设置页 `MacSyncSettingsView` / 工具栏面板 `MacSyncCenterView`）共用本视图。
    @Environment(SyncHostCenter.self) private var envHostCenter
    /// App 强调色（读环境值，与主窗同源；macOS 上 `Color.accentColor` 跟随系统强调色而非
    /// App tint——2026-09-05 已统一，本文件 2026-09-11 新增时复发，见 M1）
    @Environment(\.appAccentColor) var accentColor
    /// 执行侧（阶段 / 进度 / 结果）。
    @StateObject var model: MacSyncRunViewModel
    /// 内容侧（方向 / 内容源 / 选项 / 选择集）。
    @StateObject var content: MacSyncContentModel
    /// 数据同步侧（S2-T12：收藏 / 播放历史 / 歌单结构）。
    @StateObject var dataModel: MacSyncDataViewModel
    /// 运行时装配自检事实（L5：本端声明的能力真的装配上了吗；缺口 = 0 时面板空态）。
    /// 2026-09-20 批 6-8：迁 `@Observable` ⇒ 环境注入（非 private：`SyncDataPane.swift` 分区文件要用）。
    @Environment(SyncWiringFactsStore.self) var wiringFacts
    /// F2 对齐歌词补发轮的事实（连接就绪自动跑的那一轮；nil = 本次连接还没跑过）。
    @Environment(MacLyricsResendFactsStore.self) var lyricsFacts

    // MARK: - 顶层页与流（2026-09-26 批 B1）

    /// 当前顶层页（设备 / 同步）。初值由入口给定（设置页 = 设备；工具栏面板 = 同步）。
    @State var page: MacSyncPage
    /// 「同步」页当前流（传歌 / 播放数据）。
    @State var flow: MacSyncFlow = .tracks

    // MARK: - 设备页状态（原 `MacSyncCenterView`；拆分后仍由本类型持有 = 唯一观察者）

    @State var identity: SyncIdentity?
    @State var identityError: String?
    @State var qrPayload: PairQRPayload?
    @State var qrImage: NSImage?
    @State var devices: [PeerDevice] = []
    @State var devicesError: String?
    /// 待撤销配对的设备（nil = 无待确认删除）
    @State var pendingUnpair: PeerDevice?

    /// 设备区选中项（= 本次同步目标；**读**：唯一来源是持久化的 `DeleteSettings.syncTargetDeviceID`）。
    /// 批 B2：选择**持久化**（重启后仍记得）；写入一律走 `selectTargetDevice(_:)`
    /// （唯一写入口：归一 → 持久化 → 推进闸门）。

    /// 设备存储（设备页读写；与拆分前同款：视图层持有）。
    let deviceStore = DeviceStore()

    // MARK: - 同步页状态（原 `MacSyncRunSection`）

    /// 全曲库二次确认（Q4 决策：全库必须确认）。
    @State var showLibraryWideConfirm = false
    /// 「重新对账」二次确认（身份缺口包：重置两端游标 = 重新拉一遍，不可无声执行）。
    @State var showResetCursorsConfirm = false
    /// 二次确认文案里的规模（弹框时现算）。
    @State var libraryWidePreview: SyncUISelectionSummary = .empty
    /// E 结果区「详情」展开态（默认折叠；视图本地态，不持久化）。
    @State var showFileResultDetail = false
    /// F 数据同步结果「详情」展开态（同上）。
    @State var showDataResultDetail = false
    /// 本页设置读写（跨端续播开关；与 MacSettingsView 同做法：load → 改 → save）。
    @State var deleteSettings = DeleteSettings.load()
    /// 单曲搜索防抖任务。
    @State var searchTask: Task<Void, Never>?

    /// 发起方显式传入的中心实例（`init(hostCenter:)`；nil = 用环境值）。
    private let injectedHostCenter: SyncHostCenter?
    /// 本视图实际使用的中心：**显式传入优先**，否则环境值（保留 init 注入语义，与环境注入并存）。
    var hostCenter: SyncHostCenter { injectedHostCenter ?? envHostCenter }

    /// 本机展示名（QR hostName 字段；Bonjour 友好名优先，回落到进程主机名）
    var hostName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// ⚠️ 默认值是 `nil` 而不是 `.shared`：View 的 init 是非隔离上下文，
    /// 默认实参里直接引用 `@MainActor` 的 `.shared` 会报隔离错报（Swift 6 下是错误）
    /// （与两个 ViewModel 同一处理）。
    /// 2026-09-20 批 6-8：参数**保留**（调用方可传实例），只是不再用它建 `ObservedObject` ——
    /// 观察走环境注入；`hostCenter` 计算属性 = 显式传入 ?? 环境值。
    /// 注：三个 view model 仍在 init 里用 `hostCenter ?? .shared` 建（init 读不到环境值）；
    /// 组合根注入的就是同一个 `.shared`，两个入口传入的也是环境值 → 三处同一个实例。
    @MainActor
    init(hostCenter: SyncHostCenter? = nil, initialPage: MacSyncPage = .sync) {
        let center = hostCenter ?? .shared
        let contentModel = MacSyncContentModel(hostCenter: center)
        injectedHostCenter = hostCenter
        _page = State(initialValue: initialPage)
        _content = StateObject(wrappedValue: contentModel)
        _model = StateObject(wrappedValue: MacSyncRunViewModel(hostCenter: center, content: contentModel))
        _dataModel = StateObject(wrappedValue: MacSyncDataViewModel(hostCenter: center))
    }

    var body: some View {
        Group {
            pagePicker
            switch page {
            case .device:
                devicePane
            case .sync:
                syncPage
            }
        }
        .onAppear {
            model.onAppear()
            deleteSettings = DeleteSettings.load()
            loadIdentityIfNeeded()
            // 监听生命周期归 SyncHostCenter（App 启动即常驻）；本视图只挂控制面回调。
            // ⚠️ 单槽回调：整个 App 仅此一处挂接（两个入口共用本视图）。
            // 审计 M4：槽位不再捕获本 View 值（struct）——修复前 `{ [self] in reloadDevices() }`
            // 形成 单例 → 闭包 → View 副本 → 单例 的强引用环（每开一次面板滞留一份 View
            // 及其 qrImage 位图/设备数组），且面板关闭后槽位仍指向已卸载副本，回调会写
            // 一个不再安装到视图上的 @State（静默无效）。改发无状态通知，订阅方是活视图。
            hostCenter.onDevicesChanged = {
                NotificationCenter.default.post(name: .macSyncDevicesChanged, object: nil)
            }
            reloadDevices()
            // 展示首张 QR（identity 就绪才生成；nonce 注册见 refreshQR）
            refreshQR()
        }
        .onDisappear {
            searchTask?.cancel()
            content.onDisappear()
            model.onDisappear()
            dataModel.onDisappear()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macSyncDevicesChanged)) { _ in
            reloadDevices()
        }
        // 连接状态变化（移动端连上/断开）→ 重算在线态与默认选中
        .onChange(of: hostCenter.connectedPeer?.peerID) { _, _ in
            syncTargetSelection()
        }
        .alert(
            "sync_load_failed_title".localized,
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button(Localized.ok) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "sync_run_library_confirm_title".localized,
            isPresented: $showLibraryWideConfirm,
            titleVisibility: .visible
        ) {
            Button("sync_run_library_confirm_action".localized) {
                content.setLibraryWide()
            }
            Button(Localized.cancel, role: .cancel) {}
        } message: {
            Text(
                "sync_run_library_confirm_message".localized(
                    with: libraryWidePreview.sizeText,
                    libraryWidePreview.trackCount
                )
            )
        }
        .confirmationDialog(
            "sync_run_data_reset_confirm_title".localized,
            isPresented: $showResetCursorsConfirm,
            titleVisibility: .visible
        ) {
            Button("sync_run_data_reset_confirm_action".localized) {
                // 批 B2：显式传「所选设备」（不再由 `MacSyncDataViewModel` 自己读 connectedPeer）
                dataModel.resetCursorsForPeer(targetDeviceID ?? "")
            }
            Button(Localized.cancel, role: .cancel) {}
        } message: {
            Text("sync_run_data_reset_confirm_message".localized)
        }
        .confirmationDialog(
            "sync_unpair_confirm_title".localized,
            isPresented: Binding(
                get: { pendingUnpair != nil },
                set: { if !$0 { pendingUnpair = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingUnpair
        ) { device in
            Button("sync_unpair".localized, role: .destructive) {
                unpair(device)
            }
            Button(Localized.cancel, role: .cancel) {}
        } message: { device in
            Text("sync_unpair_confirm_message".localized(with: SyncDeviceList.displayName(device)))
        }
    }

    /// 顶层页分段控件（设备 / 同步）。文案复用既有 key（`sync_devices_section` / `sync_run_panel_title`）。
    private var pagePicker: some View {
        Picker("", selection: $page) {
            Text("sync_devices_section".localized).tag(MacSyncPage.device)
            Text("sync_run_panel_title".localized).tag(MacSyncPage.sync)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - 设备页数据（原 `MacSyncCenterView`，2026-09-26 批 B1 随状态一并迁来）

    func loadIdentityIfNeeded() {
        guard identity == nil else { return }
        do {
            identity = try SyncIdentityStore().loadOrCreateIdentity()
        } catch {
            identityError = error.localizedDescription
        }
    }

    /// 生成新 nonce + 载荷并重绘二维码（每次调用换一张新码）。
    /// S2 接线：新码的 sessionNonce 同步注册进运行中的监听器（不注册则
    /// 客户端带签名 nonce 回连时验签无源 → 配对必被拒）。
    /// 监听器未运行（开关关闭 / 启动失败）时静默忽略（与旧行为一致）。
    @MainActor
    func refreshQR() {
        guard let identity else { return }
        let payload = PairQRPayloadFactory.make(
            hostName: hostName,
            identity: identity,
            sessionNonce: SyncSessionNonce.makeNew()
        )
        do {
            let json = try SyncQRCodec.encode(payload)
            qrPayload = payload
            qrImage = SyncQRImageFactory.make(from: json)
            hostCenter.registerQRNonce(nonceBase64: payload.sessionNonce)
        } catch {
            identityError = error.localizedDescription
        }
    }

    func reloadDevices() {
        do {
            devices = try deviceStore.all()
        } catch {
            devicesError = error.localizedDescription
        }
        syncTargetSelection()
    }

    /// 设备区选中项（= 本次同步目标）。批 B2：持久化在既有偏好入口 `DeleteSettings` 里
    /// （重启后仍记得所选设备；空串 = 未选）。判定一律走 `SyncDeviceListModel`（纯逻辑）。
    var targetDeviceID: String? {
        deleteSettings.syncTargetDeviceID.isEmpty ? nil : deleteSettings.syncTargetDeviceID
    }

    /// 选中一台设备（**唯一写入口**）：归一 → 写持久化 → 推进闸门。
    /// 传 nil 清空选择（不删任何记录，只是「没选目标」）。
    func selectTargetDevice(_ peerID: String?) {
        let normalized = SyncDeviceTargetSelection(peerID: peerID).peerID
        if normalized != targetDeviceID {
            deleteSettings.syncTargetDeviceID = normalized ?? ""
            deleteSettings.save()
        }
        syncTargetSelection()
    }

    /// 「连上的 ≠ 所选」提示里的**一键改用**：把选择改成当前连上的那台。
    /// 选择从哪来仍是决策层的事（`SyncDeviceListModel.adoptingConnectedPeer`）。
    func adoptConnectedTarget() {
        let adopted = SyncDeviceTargetSelection(peerID: targetDeviceID).adoptingConnectedPeer(in: deviceRows)
        selectTargetDevice(adopted.peerID)
    }

    /// 设备列表 / 连接状态 / 选择变化后重算选中（在线优先、原选中仍在则保持），
    /// 并把「唯一决策」的结果推给两个执行侧（传歌 / 数据）—— 连同目标在线态构成同步闸门。
    func syncTargetSelection() {
        let rows = deviceRows
        let reconciled = SyncDeviceTargetSelection(peerID: targetDeviceID).reconciled(in: rows)
        if reconciled.peerID != targetDeviceID {
            // 原选中已撤销配对（或从未选过）→ 回落到默认（在线那台 / 未选）并持久化
            deleteSettings.syncTargetDeviceID = reconciled.peerID ?? ""
            deleteSettings.save()
        }
        let status = reconciled.status(in: rows)
        // 批 B2 收尾：目标状态不再镜像到两个 ViewModel —— 传歌侧经 `updateSyncTarget` 落进其私有
        // 镜像并刷新闸门；数据侧的派生/动作点由视图直接传 `syncTargetStatus`（见 `SyncDataPane`）。
        model.updateSyncTarget(status)
    }

    func unpair(_ device: PeerDevice) {
        do {
            try deviceStore.remove(peerID: device.peerID)
            reloadDevices()
        } catch {
            devicesError = error.localizedDescription
        }
    }
}

#Preview("设备页") {
    Form {
        MacSyncRunSection(initialPage: .device)
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 720)
    // Preview 是组合根之外的第二个合法装配点（App 根注入不覆盖画布）→ 显式装配（批 6-8）。
    // 实例取自 `MacSyncPreviewEnvironment`（非视图层 helper）⇒ 视图文件里不留 `.shared` 直连。
    .environment(MacSyncPreviewEnvironment.hostCenter)
    .environment(MacSyncPreviewEnvironment.wiringFacts)
    .environment(MacSyncPreviewEnvironment.lyricsResendFacts)
}

#Preview("同步页") {
    Form {
        MacSyncRunSection(initialPage: .sync)
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 720)
    .environment(MacSyncPreviewEnvironment.hostCenter)
    .environment(MacSyncPreviewEnvironment.wiringFacts)
    .environment(MacSyncPreviewEnvironment.lyricsResendFacts)
}

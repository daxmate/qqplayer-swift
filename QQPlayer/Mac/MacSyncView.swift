//
//  MacSyncView.swift
//  QQPlayer
//
//  M6（T3，2026-09-11；T10 2026-09-12 方向优先改造）macOS「同步」页 —— **同步操作区**
//  （QQPlayerMac target only）：
//  A 连接状态区 / B 方向区（T10 新增，面板第一屏）/ C 内容选择区（随方向切数据源）/
//  D 执行区 / E 结果区（最近一次）/ F 数据同步区（S2-T12，2026-09-13）。
//
//  F 数据同步区（S2-T12）：**播放数据**（收藏 / 播放历史 / 歌单结构）的独立动作入口
//  ——与文件传输无关（不选方向、不选歌），一次 = 推本端增量 + 拉对端增量；
//  驱动与账目全在 `MacSyncDataViewModel` + `SyncDataSyncCoordinator`（共享 Core）。
//
//  T10 的用户反馈（2026-09-12）：「我明明是从 iPhone 上下载，但是显示的内容是本地的
//  曲库」→ 本文件把**方向**提到内容之前：未选方向时内容区只显示引导，选定后内容
//  面板整体切到对应一端（上传 = 本端 Mac；下载 = 对端 iPhone）。
//
//  与 `MacSyncSettingsView` 的分工：那个文件是同步页的**壳**（配对批准卡 / 本机身份
//  与二维码 / 已配对设备），本文件只补上「真的把歌同步过去」的操作面，由前者在
//  `Form` 内渲染（`MacSyncRunSection`）。⚠️ 新增内容一律放这里。
//
//  纪律：本文件**只做展示**——能不能开始 / 现在什么阶段 / 进度多少 / 结果怎么算，
//  全部来自 `MacSyncRunViewModel` + `MacSyncContentModel` + `SyncUIState` /
//  `SyncUIDirectionContent`（纯逻辑，有单测）。View 里不写判断。
//
//  ⚠️ 历史（2026-09-18 前）：曾要求「macOS 13 兼容：不使用 macOS 14+ API（`onChange` 单参数闭包、
//  不用 `ContentUnavailableView`）」。同日部署目标提到 14.0，此约束解除；
//  文件内的 `onChange` 已改为两参数签名。新增代码仍以「不引入 macOS 15+ API」为惯例。
//

import SwiftUI

/// 同步操作区（在 `MacSyncSettingsView` 的 `Form` 内渲染）。
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
    /// 2026-09-20 批 6-8：迁 `@Observable` ⇒ 环境注入（非 private：`MacSyncView+Run.swift` 分区文件要用）。
    @Environment(SyncWiringFactsStore.self) var wiringFacts
    /// F2 对齐歌词补发轮的事实（连接就绪自动跑的那一轮；nil = 本次连接还没跑过）。
    @Environment(MacLyricsResendFactsStore.self) var lyricsFacts
    /// 发起方显式传入的中心实例（`init(hostCenter:)`；nil = 用环境值）。
    private let injectedHostCenter: SyncHostCenter?
    /// 本视图实际使用的中心：**显式传入优先**，否则环境值（保留 init 注入语义，与环境注入并存）。
    var hostCenter: SyncHostCenter { injectedHostCenter ?? envHostCenter }

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

    /// ⚠️ 默认值是 `nil` 而不是 `.shared`：View 的 init 是非隔离上下文，
    /// 默认实参里直接引用 `@MainActor` 的 `.shared` 会报隔离错报（Swift 6 下是错误）
    /// （与两个 ViewModel 同一处理）。
    /// 2026-09-20 批 6-8：参数**保留**（调用方可传实例），只是不再用它建 `ObservedObject` ——
    /// 观察走环境注入；`hostCenter` 计算属性 = 显式传入 ?? 环境值。
    /// 注：三个 view model 仍在 init 里用 `hostCenter ?? .shared` 建（init 读不到环境值）；
    /// 组合根注入的就是同一个 `.shared`，两个入口传入的也是环境值 → 三处同一个实例。
    @MainActor
    init(hostCenter: SyncHostCenter? = nil) {
        let center = hostCenter ?? .shared
        let contentModel = MacSyncContentModel(hostCenter: center)
        injectedHostCenter = hostCenter
        _content = StateObject(wrappedValue: contentModel)
        _model = StateObject(wrappedValue: MacSyncRunViewModel(hostCenter: center, content: contentModel))
        _dataModel = StateObject(wrappedValue: MacSyncDataViewModel(hostCenter: center))
    }

    var body: some View {
        Group {
            connectionSection
            directionSection
            selectionSection
            runSection
            resultSection
            dataSection
        }
        .onAppear {
            model.onAppear()
            deleteSettings = DeleteSettings.load()
        }
        .onDisappear {
            searchTask?.cancel()
            content.onDisappear()
            model.onDisappear()
            dataModel.onDisappear()
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
                dataModel.resetCursorsForPeer()
            }
            Button(Localized.cancel, role: .cancel) {}
        } message: {
            Text("sync_run_data_reset_confirm_message".localized)
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
    }

}

#Preview {
    Form {
        MacSyncRunSection()
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 720)
    // Preview 是组合根之外的第二个合法装配点（App 根注入不覆盖画布）→ 显式装配（批 6-8）。
    // 实例取自 `MacSyncPreviewEnvironment`（非视图层 helper）⇒ 视图文件里不留 `.shared` 直连。
    .environment(MacSyncPreviewEnvironment.hostCenter)
    .environment(MacSyncPreviewEnvironment.wiringFacts)
    .environment(MacSyncPreviewEnvironment.lyricsResendFacts)
}

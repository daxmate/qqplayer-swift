//
//  MacSyncPreviewEnvironment.swift
//  QQPlayer
//
//  局域网同步（S2）macOS 视图 `#Preview` 的**装配入口**（批 6-8，方案 A，2026-09-20）。
//
//  为什么存在：批 6-8 把同步视图的状态源上收为环境注入（`@Environment(T.self)`）后，
//  `#Preview` 不继承 App 场景环境（画布不是组合根），必须自己装配真实例。若在视图文件里
//  逐行写 `.environment(X.shared)`，直连单例棘轮（`ViewSharedSingletonContractTests`）会按
//  「视图文件新增直连」变红——每处 preview 注入 = 预算 +1，3 个视图 × 3 个对象 = +9，
//  属**反向上涨**，账本口径不允许抬基线放行（`shared-singleton-budget-plan.md` §5.2 两条路
//  里的 (a)：把取实例这一步挪出视图层）。
//
//  做法：视图文件只写 `.environment(MacSyncPreviewEnvironment.hostCenter)`，
//  「取真实例」这一步收在本文件。**本文件必须留在视图层之外**——棘轮口径是
//  `isViewLayerFile`：`QQPlayer/Views/**` 全部 ⊕ 源码里声明了视图类型的文件；
//  本文件两条都不命中（在 `QQPlayer/Mac/` 下、且不声明视图类型）。
//
//  ⚠️ 所以本文件**不得**出现视图声明标记（一旦出现，口径就把本文件判成视图层，
//  等于把 +9 从视图文件挪到本文件，问题只是换了个位置）。因此这里只暴露**实例**，
//  不提供「已经装配好的视图」这类返回值——包装视图必然要写视图声明标记。
//  ⚠️ 同样地：注释里也不要出现那两个标记的字面量，判定是**源码文本包含**，注释一并计入。
//
//  实例来源：三个对象的实例全仓只有一个（`private init` + `static let shared`），
//  组合根（`QQPlayerMacApp` 两个场景根）注入的就是它们 ⇒ preview 拿到的与真机运行的是
//  同一个实例，零行为变化（本仓铁律：预览只是第二个装配点，不引入第二种实例来源）。
//

import Foundation

/// macOS 同步视图 `#Preview` 的装配入口（只暴露实例，不包装视图——理由见文件头）。
///
/// `@MainActor`：三个对象本体都是 `@MainActor`（`static let shared` 亦然），
/// `#Preview` 的构建闭包也在主线程上下文 ⇒ 取用同隔离域，不需要 `await`。
@MainActor
enum MacSyncPreviewEnvironment {
    /// App 级 Host 监听中心（设置页「同步」与工具栏同步面板共用这一个实例）。
    static var hostCenter: SyncHostCenter { .shared }
    /// 接线自检事实（`MacSyncRunSection` 的消费点之一）。
    static var wiringFacts: SyncWiringFactsStore { .shared }
    /// 歌词补发事实（`MacSyncRunSection` 的消费点之一）。
    static var lyricsResendFacts: MacLyricsResendFactsStore { .shared }
}

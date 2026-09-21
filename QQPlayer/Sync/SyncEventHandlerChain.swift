//
//  SyncEventHandlerChain.swift
//  QQPlayer
//
//  E2（2026-09-21）：自 `SyncPeerSession+Frames.swift` 拆出的「会话事件分发链」子系统
//  （槽位常量 + 挂接句柄 + 分发链 + 注册表 + 槽位挂接门面）。**纯搬家**：正文逐字相同。
//

import Foundation

// MARK: - 会话事件分发链（修 🟡F1：链上任一 handler 释放不得让其它 handler 收不到事件）

/// 槽位名（每条会话一个槽位一条链）。
enum SyncSessionEventSlot {
    /// `session.onApplicationFrame`（ready 后业务帧）
    static let applicationFrame = "applicationFrame"
    /// `session.onClosed`（会话关闭）
    static let closed = "closed"
}

/// 链挂接句柄：`detach()` 摘除自己那一项（幂等；**随持有者释放自动摘除**，无需"保活池"）。
final class SyncEventHandlerToken: @unchecked Sendable {
    private let lock = NSLock()
    private var removal: (() -> Void)?

    init(removal: @escaping () -> Void) {
        self.removal = removal
    }

    /// 摘除（幂等）。摘除后链上其它 handler 照常收到事件。
    func detach() {
        lock.lock()
        let action = removal
        removal = nil
        lock.unlock()
        action?()
    }

    deinit {
        detach()
    }
}

/// 会话事件分发链：把此前**各 peer 各自复制一份**的"把自己挂进 `session.onApplicationFrame` /
/// `onClosed` 闭包链"收敛成单一实现，并修掉它的释放语义缺陷。
///
/// 旧写法（本仓库此前 7 处同构复制）：
/// ```swift
/// priorAppHandler = session.onApplicationFrame
/// session.onApplicationFrame = { [weak self] frame in
///     guard let self, self.forwardingEnabled else {
///         self?.priorAppHandler?(frame)   // ← self 已释放：什么也不做，prior 永远收不到帧
///         return
///     }
///     self.handleInboundFrame(frame)
///     self.priorAppHandler?(frame)
/// }
/// ```
/// 后果（🟡F1）：链上任一 peer 释放 → **挂接更早的 handler 在本次会话余下时间全部收不到帧**
/// （整段静默失效，不报错）。生产触发点：`SyncCollectionSyncCoordinator` 计划完成 /
/// 失败 / 超时即 `manifestPeer = nil`，链头释放后更早挂接的 `SyncChangeLogPeer` 等收不到帧
/// ——拉取方向"跟歌走"的 `change_log_push` 应答被丢弃 → 播放数据永不落库、游标永不推进。
///
/// 新语义（链结构与释放语义）：
/// - 每个 (会话, 槽位) **一条链**，槽位里只装**一个**稳定分发闭包（首次挂接时装一次）；
///   此后所有挂接都是往链里加一项，彼此无关；
/// - 链项 = (owner 弱持有, handler 强持有)：owner 被释放 → 该项静默并在下次分发前摘除，
///   **其余 handler 照常收到事件**（F1 的修复点）；
/// - 分发顺序与旧链一致：后挂接的先处理，最后是会话原有 handler（调用方注释里的"先己后彼"）；
/// - `SyncEventHandlerToken.detach()` 摘除自己的项：**与其它项的增删顺序无关**（不依赖
///   "自己是不是链头"，也不会误拆后挂的链）；token 释放即摘除，链长度只随存活 handler 数增长；
/// - 强持有语义：槽位闭包强持有链（会话活着 = 链活着）；链只**弱**持有会话
///   （避免 会话 → 闭包 → 链 → 会话 环）；链项强持有 handler、弱持有 owner。
final class SyncEventHandlerChain<Event>: @unchecked Sendable {
    typealias Handler = (Event) -> Void

    /// 链项：owner 弱持有（释放即静默），handler 强持有。
    private final class Entry {
        weak var owner: AnyObject?
        let handler: Handler

        init(owner: AnyObject, handler: @escaping Handler) {
            self.owner = owner
            self.handler = handler
        }
    }

    private let lock = NSLock()
    /// 所属会话（弱持有：仅用于注册表归属与回收，不参与分发）。
    private weak var session: AnyObject?
    /// 挂接顺序（先挂在前 → 分发时倒序）。
    private var entries: [Entry] = []
    /// 会话槽位原有 handler（链尾，最后调用）。
    private let baseHandler: Handler?

    private init(session: AnyObject, baseHandler: Handler?) {
        self.session = session
        self.baseHandler = baseHandler
    }

    /// 会话槽位访问器（读当前 handler / 装分发闭包）。
    struct SlotAccess {
        let readCurrent: @Sendable () -> Handler?
        /// 装分发闭包（参数是链对象：闭包参数默认非逃逸，存不进 `@Sendable` 槽位属性）。
        let install: @Sendable (SyncEventHandlerChain<Event>) -> Void
    }

    /// 把 handler 挂到 (会话, 槽位) 的链上；返回可摘除句柄。
    /// 链不存在时先 `readCurrent()` 取会话原有 handler 作链尾，再 `install()` 装分发闭包。
    static func attach(
        owner: AnyObject,
        session: AnyObject,
        slot: String,
        access: SlotAccess,
        handler: @escaping Handler
    ) -> SyncEventHandlerToken {
        let chain = SyncEventHandlerChainRegistry.chain(session: session, slot: slot, eventType: Event.self) {
            let created = SyncEventHandlerChain<Event>(session: session, baseHandler: access.readCurrent())
            access.install(created)
            return created
        }
        let entry = Entry(owner: owner, handler: handler)
        chain.append(entry)
        return SyncEventHandlerToken { [weak chain] in
            chain?.remove(entry)
        }
    }

    /// 当前链项数（诊断/测试用）。
    var handlerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private func append(_ entry: Entry) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    private func remove(_ entry: Entry) {
        lock.lock()
        entries.removeAll { $0 === entry }
        lock.unlock()
    }

    /// 装进会话槽位的分发闭包（`@Sendable`：槽位属性是 `@Sendable` 类型——会话队列调用，见交办）。
    func dispatcher() -> @Sendable (Event) -> Void {
        { event in self.dispatch(event) }
    }

    /// 倒序调用存活链项，最后调用会话原有 handler。
    /// 调用 handler **不持锁**（handler 内可能摘除/挂接其它 handler、甚至释放 peer）。
    private func dispatch(_ event: Event) {
        lock.lock()
        entries.removeAll { $0.owner == nil } // owner 已释放 → 摘除（链长度只随存活 handler 增长）
        let handlers = entries.map(\.handler)
        let base = baseHandler
        lock.unlock()
        for handler in handlers.reversed() {
            handler(event)
        }
        base?(event)
    }
}

/// 链注册表：按 (会话, 槽位, 事件类型) 唯一持有链。
/// 会话先于链释放时惰性回收（链只被槽位闭包强持有 → 会话没了链就没了）。
enum SyncEventHandlerChainRegistry {
    /// 注册表存储：`static let` 不可变绑定 + `@unchecked Sendable` 箱体
    /// （Swift 6 严格并发不允许 nonisolated 的全局可变静态属性）。
    private final class Store: @unchecked Sendable {
        var chains: [String: WeakChain] = [:]
    }

    private static let lock = NSLock()
    private static let store = Store()

    private final class WeakChain {
        weak var value: AnyObject?

        init(_ value: AnyObject) {
            self.value = value
        }
    }

    static func chain<Event>(
        session: AnyObject,
        slot: String,
        eventType: Any.Type,
        make: () -> SyncEventHandlerChain<Event>
    ) -> SyncEventHandlerChain<Event> {
        let key = "\(ObjectIdentifier(session))|\(slot)|\(ObjectIdentifier(eventType))"
        lock.lock()
        defer { lock.unlock() }
        // 回收：会话/槽位闭包已释放的链
        var chains = store.chains.filter { $0.value.value != nil }
        if let existing = chains[key]?.value as? SyncEventHandlerChain<Event> {
            return existing
        }
        // 首次挂接：创建 + 装槽位（在锁内做，避免并发挂接出现两条链互相覆盖槽位）。
        let created = make()
        chains[key] = WeakChain(created)
        store.chains = chains
        return created
    }
}

/// peer/session 组件的槽位挂接门面：一次挂接应用帧 / 关闭两个槽位，统一走分发链。
/// 用法：`attachment = SyncSessionAttachment(session: session, owner: self) { [weak self] frame in ... }`
/// 释放 `attachment`（或本实例释放）即自动摘除；也可显式 `detach()`。
final class SyncSessionAttachment: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [SyncEventHandlerToken] = []

    init(
        session: SyncPeerSession,
        owner: AnyObject,
        onFrame: (@Sendable (SyncFrame) -> Void)? = nil,
        onClosed: (@Sendable (SyncSessionCloseReason) -> Void)? = nil
    ) {
        if let onFrame {
            tokens.append(SyncEventHandlerChain.attach(
                owner: owner,
                session: session,
                slot: SyncSessionEventSlot.applicationFrame,
                access: SyncEventHandlerChain<SyncFrame>.SlotAccess(
                    readCurrent: { session.onApplicationFrame },
                    install: { session.onApplicationFrame = $0.dispatcher() }
                ),
                handler: onFrame
            ))
        }
        if let onClosed {
            tokens.append(SyncEventHandlerChain.attach(
                owner: owner,
                session: session,
                slot: SyncSessionEventSlot.closed,
                access: SyncEventHandlerChain<SyncSessionCloseReason>.SlotAccess(
                    readCurrent: { session.onClosed },
                    install: { session.onClosed = $0.dispatcher() }
                ),
                handler: onClosed
            ))
        }
    }

    /// 摘除全部挂接（幂等）。
    func detach() {
        lock.lock()
        let current = tokens
        tokens = []
        lock.unlock()
        current.forEach { $0.detach() }
    }

    deinit {
        detach()
    }
}

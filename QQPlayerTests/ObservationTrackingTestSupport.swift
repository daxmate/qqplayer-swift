//
//  ObservationTrackingTestSupport.swift
//  QQPlayerTests
//
//  `withObservationTracking` 观测口径的**唯一入口**（2026-09-25 立）。
//  测试代码里**禁止裸用** `withObservationTracking`（白名单只有本文件），由
//  `ObservationTrackingShapeContractTests.swift` 静态守护。
//
//  为什么需要它 —— 2026-09-25 实测的**假阴性**：
//  写「读路径有没有写被观察状态」的断言时，最自然的写法是把被测的读**整个放进**
//  `withObservationTracking` 的 apply 闭包。这个写法是**假绿**的：
//
//  ❌ 错法（实测：把「读路径写 inFlight」的旧实现注回去，断言**仍然全绿**）
//      var observableMutations = 0
//      withObservationTracking {
//          for _ in 0 ..< 5 {                                  // ← 被测的读全在 apply 里
//              _ = store.albumFacts(forAlbumId: 5)
//          }
//      } onChange: {
//          observableMutations += 1
//      }
//      #expect(observableMutations == 0)                       // ← 永远绿（假阴性）
//
//  原因：`onChange` **不会**在 apply 闭包执行期间触发 —— apply 里那些读只是**建立观测依赖**，
//  依赖只有在**之后的写入**才会回报。读路径一边读一边写（旧实现写 `inFlight`）这件事，
//  因此被彻底漏掉。
//
//  ✅ 对法（先建追踪、**再**执行被测操作）
//      let observableMutations = ObservationTrackingProbe.mutationCount(
//          whenTracking: {                                         // phase 1：只做那次读（建追踪）
//              _ = store.albumFacts(forAlbumId: 5)                 // 真实 SwiftUI body 求值的那一次
//          },
//          thenRunning: {                                          // phase 2：被测操作
//              for _ in 0 ..< 5 { _ = store.albumFacts(forAlbumId: 5) }
//          }
//      )
//      #expect(observableMutations == 0, "读路径写了被观察状态")
//
//  顺序写进了**签名**：两个闭包各有明确职责（`whenTracking` = 建追踪的那次读、
//  `thenRunning` = 被测操作），把读挪回 phase 1 只会让 `thenRunning` 变成空闭包 —— 一眼可疑。
//  自证用例 `reversedOrderCollapsesToZero` 实测：顺序调错（读全在 phase 1、phase 2 为空）
//  计数塌成 0，即「断言真的会假阴性」。
//
//  本文件取代原先散在 `MacLibraryFactsStoreTests.swift` 里的私有 `MutationCounter`
//  —— 同一语义只留一处（「共享语义唯一入口」纪律）。
//

import Foundation
import Observation
import Testing

/// 观测口径的唯一入口。
@MainActor
enum ObservationTrackingProbe {
    /// 返回 phase 2（`thenRunning`）期间被观测状态变更（`onChange`）的触发次数。
    ///
    /// - Parameters:
    ///   - trackingReads: **phase 1** —— SwiftUI body 会做的那次读；只做读，用来建立观测依赖。
    ///   - body: **phase 2** —— 被测操作（读或写）。它触碰到的、在 phase 1 被读过的被观察状态，
    ///     一旦发生变更就会在这里触发 `onChange`。
    /// - Returns: phase 2 期间 `onChange` 的触发次数（0 = 没有写被观察状态）。
    static func mutationCount(
        whenTracking trackingReads: @MainActor () -> Void,
        thenRunning body: @MainActor () -> Void
    ) -> Int {
        let counter = ObservableMutationCounter()
        withObservationTracking {
            trackingReads()
        } onChange: {
            counter.increment()
        }
        body()
        return counter.count
    }
}

/// 可观察状态变更计数器（`onChange` 是 `@Sendable`，不能捕获并写局部 `var` → 带锁引用盒子）。
final class ObservableMutationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - 自证（合成 @Observable，不依赖生产代码）

/// 合成：读路径**读也写**被观察状态（旧实现形态 —— 未命中就写 `inFlight`）。
@Observable
private final class SyntheticWriteOnReadStore {
    private(set) var observed = 0
    private var hits = 0

    /// 「读路径」：先读被观察状态（建立依赖的那次读），再写它（旧实现的副作用）。
    func readPathWithSideEffect() -> Int {
        if observed < 0 { return 0 } // 读：注册观测依赖
        observed += 1 // 写：旧实现的「渲染期写入」
        hits += 1
        return hits
    }
}

/// 合成：读路径**只读不写**（正确实现形态）。
@Observable
private final class SyntheticPureReadStore {
    private(set) var observed = 0

    func readPath() -> Int {
        observed // 只读
    }
}

@MainActor
@Suite("withObservationTracking 观测口径入口自证（合成 @Observable，不依赖生产代码）")
struct ObservationTrackingProbeSelfTests {
    @Test("★ 读就写被观察状态 → 计数必须 ≥ 1（错法会漏掉它）")
    func writeOnReadIsDetected() {
        let object = SyntheticWriteOnReadStore()
        let mutations = ObservationTrackingProbe.mutationCount(
            whenTracking: { _ = object.readPathWithSideEffect() },
            thenRunning: {
                for _ in 0 ..< 5 { _ = object.readPathWithSideEffect() }
            }
        )
        #expect(mutations >= 1, "读路径写了被观察状态，计数却没起来 —— 口径失效")
    }

    @Test("★ 读不写 → 必须 = 0（防假阳性）")
    func pureReadIsZero() {
        let object = SyntheticPureReadStore()
        let mutations = ObservationTrackingProbe.mutationCount(
            whenTracking: { _ = object.readPath() },
            thenRunning: {
                for _ in 0 ..< 5 { _ = object.readPath() }
            }
        )
        #expect(mutations == 0, "只读的实现不该触发 onChange")
    }

    @Test("★ 顺序调错（被测的读全进 phase 1、phase 2 为空）→ 计数塌成 0 = 断言真的会假阴性")
    func reversedOrderCollapsesToZero() {
        let object = SyntheticWriteOnReadStore()
        // 复刻 2026-09-25 的错法：把整段被测的读放进 apply 闭包（此处 = phase 1），
        // phase 2 什么都不做。旧写法下这就是「断言永远绿」的形态。
        let mutations = ObservationTrackingProbe.mutationCount(
            whenTracking: {
                for _ in 0 ..< 5 { _ = object.readPathWithSideEffect() }
            },
            thenRunning: {}
        )
        #expect(mutations == 0, "顺序调错时的假阴性形态（0）—— 正是本入口要防的")
    }
}

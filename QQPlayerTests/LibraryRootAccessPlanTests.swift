//  LibraryRootAccessPlanTests.swift
//  QQPlayerTests
//
//  曲库根授权判定防回归（MAS 批 2B，2026-10-29）。
//
//  被锁定的口径：`LibraryRootAccessState` 只回答「现在能不能真正读到用户想要的根」。
//  · 书签命中（路径一致 + 作用域已开）→ granted；
//  · 没有书签但目录本来可读（未沙盒开发构建 / 容器内目录）→ granted；
//  · 书签存在但指向别的目录（设置换了位置）→ 只能靠「可读」兜底，否则 needsAuthorization；
//  · 书签路径一致但作用域没开（沙盒下书签失效）→ 不能当 granted，必须回引导页。
//
//  真正把「读不到」当 granted 的后果不是报错而是**静默空库**（用户以为丢歌），
//  所以四条分支都要钉住。
//

import Foundation
import Testing

@testable import QQPlayer

struct LibraryRootAccessPlanTests {
    private let desired = "/Users/test/Music/QQPlayer"

    @Test("书签命中 + 作用域已开 → 已授权（与目录是否可读无关）")
    func bookmarkHitGrants() {
        let state = LibraryRootAccessPlan.decide(
            desiredRootPath: desired,
            bookmarkRootPath: desired,
            bookmarkScopeActive: true,
            rootIsReadable: false
        )
        #expect(state == .granted)
    }

    @Test("书签路径尾斜杠/多余分隔符不影响命中")
    func bookmarkPathIsNormalized() {
        let state = LibraryRootAccessPlan.decide(
            desiredRootPath: desired + "/",
            bookmarkRootPath: "/Users/test/Music/./QQPlayer",
            bookmarkScopeActive: true,
            rootIsReadable: false
        )
        #expect(state == .granted)
    }

    @Test("书签路径一致但作用域没开 → 需要授权（沙盒里读不到就是读不到）")
    func inactiveScopeNeedsAuthorization() {
        let state = LibraryRootAccessPlan.decide(
            desiredRootPath: desired,
            bookmarkRootPath: desired,
            bookmarkScopeActive: false,
            rootIsReadable: false
        )
        #expect(state == .needsAuthorization)
    }

    @Test("书签指向别的目录 + 目录可读 → 已授权（未沙盒 / 容器内目录兜底）")
    func readableRootWithoutMatchingBookmarkGrants() {
        let state = LibraryRootAccessPlan.decide(
            desiredRootPath: desired,
            bookmarkRootPath: "/Volumes/NAS/Music",
            bookmarkScopeActive: true,
            rootIsReadable: true
        )
        #expect(state == .granted)
    }

    @Test("书签指向别的目录 + 目录不可读 → 需要重新授权")
    func staleBookmarkNeedsAuthorization() {
        let state = LibraryRootAccessPlan.decide(
            desiredRootPath: desired,
            bookmarkRootPath: "/Volumes/NAS/Music",
            bookmarkScopeActive: true,
            rootIsReadable: false
        )
        #expect(state == .needsAuthorization)
    }

    @Test("没有书签 + 目录不可读 → 需要授权（沙盒首启）")
    func noBookmarkUnreadableNeedsAuthorization() {
        let state = LibraryRootAccessPlan.decide(
            desiredRootPath: desired,
            bookmarkRootPath: nil,
            bookmarkScopeActive: false,
            rootIsReadable: false
        )
        #expect(state == .needsAuthorization)
    }
}

//
//  LibraryGlassBackdropTests.swift
//  QQPlayerTests
//
//  库列表页「封面毛玻璃底」的纯逻辑 / 形状契约（不依赖 UI、不做截图或模拟器视觉自检）：
//    1. 生效判定矩阵：开关开 + 有当前曲目 + 有封面 + 未开「降低透明度」才生效，其余任一回落；
//    2. 四页接入契约：所有歌曲 / 专辑 / 艺人 / 歌单四页都走同一个容器
//       `ArtworkGlassScreenBackground`，且装饰底节点 `ScreenSpecificBackgroundView(screen: …)` 原地保留；
//    3. 唯一实现契约：模糊层 `ArtworkBlurBackground` 只允许出现在共享组件与 Mac 窗口玻璃里
//       （页面不得自己拼第二份）；雾面 / 暗角数值只在共享组件里出现一次。
//
//  fail-closed：文件读不到 = 红，绝不静默通过。
//

import Foundation
@testable import QQPlayer
import Testing

private enum GlassBackdropContract {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 唯一视觉实现（雾面 / 暗角数值唯一来源）
    static let sharedComponentPath = "QQPlayer/Views/Utility/ArtworkGlassBackdrop.swift"

    /// 允许直接构造模糊层的文件：共享组件 + macOS 窗口玻璃（整窗玻璃数值独立，本批不动）
    static let blurLayerOwners: Set<String> = [
        sharedComponentPath,
        "QQPlayer/Mac/MacWindowGlass.swift",
    ]

    /// 4 个列表页 + 各自的装饰底屏型
    static let libraryPages: [(path: String, screen: String)] = [
        ("QQPlayer/Views/Library/LibraryScreens.swift", ".allSongs"),
        ("QQPlayer/Views/Albums/AlbumViews.swift", ".albums"),
        ("QQPlayer/Views/Artists/ArtistsScreen.swift", ".artists"),
        ("QQPlayer/Views/Playlists/PlaylistsScreen.swift", ".playlists"),
    ]

    /// 播放页（纯抽取：内联的雾面 / 暗角已迁到共享组件）
    static let playerPagePath = "QQPlayer/Views/Player/PlayerView.swift"

    static func read(_ relativePath: String) -> String? {
        try? String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 剥掉 `//` 行注释：注释里提到实现名不算「用了」（与既有的形状契约同口径）
    static func stripped(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let range = line.range(of: "//") else { return line }
                return line[line.startIndex ..< range.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// 递归枚举 `QQPlayer/` 下的 .swift 文件（相对仓库根路径）
    static func swiftFiles() -> [String] {
        let root = repositoryRoot.appendingPathComponent("QQPlayer")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var result: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = url.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
            result.append(relative)
        }
        return result.sorted()
    }
}

// MARK: - 生效判定矩阵

struct LibraryGlassActivationTests {
    @Test("开关开 + 有当前曲目 + 有封面 + 未开降低透明度 ⇒ 玻璃生效")
    func activeWhenAllConditionsMet() {
        #expect(ArtworkGlassScreenActivation.isActive(
            hasCurrentTrack: true,
            hasArtwork: true,
            isEnabled: true,
            reduceTransparency: false
        ))
    }

    @Test("开关关 ⇒ 回落（装饰底照常显示）")
    func fallsBackWhenDisabled() {
        #expect(!ArtworkGlassScreenActivation.isActive(
            hasCurrentTrack: true,
            hasArtwork: true,
            isEnabled: false,
            reduceTransparency: false
        ))
    }

    @Test("首启未播放（无当前曲目）⇒ 回落")
    func fallsBackWithoutCurrentTrack() {
        #expect(!ArtworkGlassScreenActivation.isActive(
            hasCurrentTrack: false,
            hasArtwork: true,
            isEnabled: true,
            reduceTransparency: false
        ))
    }

    @Test("当前曲目无封面 ⇒ 回落")
    func fallsBackWithoutArtwork() {
        #expect(!ArtworkGlassScreenActivation.isActive(
            hasCurrentTrack: true,
            hasArtwork: false,
            isEnabled: true,
            reduceTransparency: false
        ))
    }

    @Test("系统「降低透明度」⇒ 回落")
    func fallsBackWhenReduceTransparency() {
        #expect(!ArtworkGlassScreenActivation.isActive(
            hasCurrentTrack: true,
            hasArtwork: true,
            isEnabled: true,
            reduceTransparency: true
        ))
    }

    @Test("与唯一判定入口 PlayerGlassBackground 结论一致（不另写一套）")
    func matchesSingleEntryPoint() {
        for enabled in [true, false] {
            for artwork in [true, false] {
                for reduce in [true, false] {
                    let expected = PlayerGlassBackground.isActive(
                        isEnabled: enabled,
                        hasArtwork: artwork,
                        reduceTransparency: reduce
                    )
                    #expect(ArtworkGlassScreenActivation.isActive(
                        hasCurrentTrack: true,
                        hasArtwork: artwork,
                        isEnabled: enabled,
                        reduceTransparency: reduce
                    ) == expected)
                }
            }
        }
    }
}

// MARK: - 四页接入契约

struct LibraryGlassPageContractTests {
    @Test("四个列表页都通过共享容器接入玻璃底，装饰底节点原地保留")
    func allLibraryPagesUseSharedContainer() {
        for page in GlassBackdropContract.libraryPages {
            guard let source = GlassBackdropContract.read(page.path) else {
                Issue.record("列表页读不到（fail-closed）：\(page.path)")
                continue
            }
            let stripped = GlassBackdropContract.stripped(source)
            #expect(stripped.contains("ArtworkGlassScreenBackground {"), "\(page.path) 未接入共享玻璃容器")
            #expect(
                stripped.contains("ScreenSpecificBackgroundView(screen: \(page.screen))"),
                "\(page.path) 的装饰底节点被改动或删除（应保留 ScreenSpecificBackgroundView(screen: \(page.screen))）"
            )
        }
    }

    @Test("页面不得自己拼玻璃层（雾面 / 暗角 / 模糊都只在共享组件里）")
    func pagesDoNotComposeGlassLayer() {
        for page in GlassBackdropContract.libraryPages {
            guard let source = GlassBackdropContract.read(page.path) else {
                Issue.record("列表页读不到（fail-closed）：\(page.path)")
                continue
            }
            let stripped = GlassBackdropContract.stripped(source)
            #expect(!stripped.contains("ArtworkBlurBackground("), "\(page.path) 直接构造了模糊层")
            #expect(!stripped.contains("startRadius: 180"), "\(page.path) 自己画了暗角")
            #expect(!stripped.contains("opacity(0.36)"), "\(page.path) 自己加了雾面")
        }
    }

    @Test("播放页改为调用共享组件（纯抽取，不再内联雾面 / 暗角）")
    func playerPageUsesSharedBackdrop() {
        guard let source = GlassBackdropContract.read(GlassBackdropContract.playerPagePath) else {
            Issue.record("播放页读不到（fail-closed）：\(GlassBackdropContract.playerPagePath)")
            return
        }
        let stripped = GlassBackdropContract.stripped(source)
        #expect(stripped.contains("ArtworkGlassBackdrop(artwork:"), "播放页未复用共享玻璃底")
        #expect(!stripped.contains("startRadius: 180"), "播放页仍内联暗角（应只在共享组件里）")
        #expect(!stripped.contains("opacity(0.36)"), "播放页仍内联雾面（应只在共享组件里）")
    }
}

// MARK: - 唯一实现契约

struct GlassBackdropSingleImplementationTests {
    @Test("模糊层只允许共享组件与 macOS 窗口玻璃构造（禁止第二实现）")
    func blurLayerHasSingleOwner() {
        var offenders: [String] = []
        for relative in GlassBackdropContract.swiftFiles() {
            guard let source = GlassBackdropContract.read(relative) else {
                Issue.record("源码读不到（fail-closed）：\(relative)")
                continue
            }
            guard GlassBackdropContract.stripped(source).contains("ArtworkBlurBackground(") else { continue }
            if !GlassBackdropContract.blurLayerOwners.contains(relative) {
                offenders.append(relative)
            }
        }
        #expect(offenders.isEmpty, "以下文件绕过了共享玻璃底直接构造模糊层：\(offenders)")
    }

    @Test("雾面 / 暗角数值只在共享组件出现一次（macOS 整窗玻璃数值独立）")
    func scrimAndVignetteLiveInOneFile() {
        var vignetteOwners: [String] = []
        for relative in GlassBackdropContract.swiftFiles() {
            guard let source = GlassBackdropContract.read(relative) else {
                Issue.record("源码读不到（fail-closed）：\(relative)")
                continue
            }
            let stripped = GlassBackdropContract.stripped(source)
            if stripped.contains("startRadius: 180"), stripped.contains("endRadius: 760") {
                vignetteOwners.append(relative)
            }
        }
        #expect(vignetteOwners == [GlassBackdropContract.sharedComponentPath], "暗角数值应只在共享组件里：\(vignetteOwners)")
    }

    @Test("共享组件仍在位（删掉 = 契约失效）")
    func sharedComponentExists() {
        #expect(GlassBackdropContract.read(GlassBackdropContract.sharedComponentPath) != nil)
    }
}

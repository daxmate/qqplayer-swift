//
//  Stubs.swift — harness 编译桩（**不参与 App target 编译**）
//
//  只为让生产源码 `QQPlayer/Mac/MacWindowGlass.swift` 能独立编译：该文件里的
//  `MacWindowGlass` 视图引用了窗口底（`ArtworkBlurBackground` + `ArtworkImage`），
//  而它们的生产实现落在 App target 的其它文件、牵连整套 SwiftUI 依赖链。
//  这两个符号**只用于「铺窗口底」的绘制，与任何断言无关**；桩只要编译通过即可。
//
//  ⚠️ fail-closed：桩与生产签名漂移 → swiftc 直接编译失败（脚本 exit 1），绝不静默跳过。
//

import SwiftUI

/// 生产 `ArtworkImage` 的最小同形桩（本 harness 不渲染封面）。
struct ArtworkImage: Equatable {}

/// 生产 `ArtworkBlurBackground` 的最小同形桩（本 harness 不用它做视觉判定）。
struct ArtworkBlurBackground: View {
    let artwork: ArtworkImage?
    let cacheKey: String?

    var body: some View { Color.clear }
}

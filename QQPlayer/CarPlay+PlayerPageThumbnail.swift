//
//  CarPlay+PlayerPageThumbnail.swift
//  QQPlayer
//
//  播放页页头缩略图绘制（封面 aspect-fill + 占位 + 底部进度条/时间文案）。
//  CarPlay 列表模板没有滑块，进度只能自绘进封面里；这段从 CarPlay+PlayerPage.swift
//  拆出（2026-11-09，结构预算 600 行上限：原文件因降频改造涨到 629 行）。
//

// target: ios-only

import UIKit

extension CarPlayPlayerPageController {
    // MARK: - 封面绘制

    /// 页头缩略图：封面（或占位）+ 底部进度条与时间文案。
    /// CarPlay 列表模板没有滑块/进度控件，进度只能自绘进封面里（只读，不可拖动）。
    func headerThumbnail(artwork: UIImage?, progress: CarPlayPlayerPageProgress?) -> UIImage {
        let side = playerPageThumbnailSide
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            if let artwork {
                drawAspectFill(artwork, in: rect)
            } else {
                drawPlaceholderFill(in: rect)
            }
            if let progress {
                drawProgressFooter(progress, in: rect)
            }
        }
    }

    /// 封面未就绪时的占位填充（页头条目要求缩略图非空）
    private func drawPlaceholderFill(in rect: CGRect) {
        UIColor.systemGray5.setFill()
        UIRectFill(rect)

        guard let note = UIImage(systemName: "music.note")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: rect.width * 0.3, weight: .medium)
        ) else { return }
        let noteRect = CGRect(
            x: rect.midX - note.size.width / 2,
            y: rect.midY - note.size.height / 2,
            width: note.size.width,
            height: note.size.height
        )
        note.withTintColor(.systemGray3, renderingMode: .alwaysOriginal).draw(in: noteRect)
    }

    /// 底部压暗 + 进度条 + 「已播 / 总长」：任何封面上都读得清
    private func drawProgressFooter(_ progress: CarPlayPlayerPageProgress, in rect: CGRect) {
        let side = rect.width
        let footerHeight = side * 0.22
        let footer = CGRect(x: 0, y: rect.maxY - footerHeight, width: side, height: footerHeight)
        UIColor.black.withAlphaComponent(0.42).setFill()
        UIRectFill(footer)

        let inset = side * 0.08
        let barHeight = side * 0.03
        let trackRect = CGRect(x: inset, y: footer.minY + footerHeight * 0.58, width: side - inset * 2, height: barHeight)
        UIColor.white.withAlphaComponent(0.28).setFill()
        UIBezierPath(roundedRect: trackRect, cornerRadius: barHeight / 2).fill()

        // 跑过的部分：至少留一个圆点，起始处也看得见
        let filledWidth = min(max(trackRect.width * CGFloat(progress.fraction), barHeight), trackRect.width)
        UIColor.white.setFill()
        UIBezierPath(
            roundedRect: CGRect(x: trackRect.minX, y: trackRect.minY, width: filledWidth, height: barHeight),
            cornerRadius: barHeight / 2
        ).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: side * 0.08, weight: .semibold),
            .foregroundColor: UIColor.white,
        ]
        let textY = footer.minY + footerHeight * 0.12
        (progress.elapsedText as NSString).draw(at: CGPoint(x: inset, y: textY), withAttributes: attributes)

        let totalText = progress.totalText as NSString
        let totalWidth = totalText.size(withAttributes: attributes).width
        totalText.draw(at: CGPoint(x: rect.maxX - inset - totalWidth, y: textY), withAttributes: attributes)
    }
}

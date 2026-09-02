//
//  MacLyricsView.swift
//  QQPlayer
//
//  macOS lyrics panel: synchronized scrolling, karaoke mode with
//  speed / single-line loop / AB loop controls (KaraokeControlBar).
//  QQPlayerMac target only — kept out of the iOS target via pbxproj
//  membership exceptions.
//

import SwiftUI

struct MacLyricsView: View {
    let lyrics: Lyrics?
    let currentTime: TimeInterval
    let isLoading: Bool
    /// 歌词搜索入口（播放页 sheet 弹出 MacLyricsSearchView）
    let onLyricsSearch: () -> Void

    @ObservedObject private var karaoke = KaraokeController.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            // 对齐 iOS LyricsView：跟唱控制条常驻底部，无论歌词状态（加载中/纯文本/无歌词）都显示
            if karaoke.isKaraokeOn {
                Divider()
                KaraokeControlBar(accentColor: .accentColor)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(
                            colors: [.clear, Color.black.opacity(0.35)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.30), Color.black.opacity(0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        // 页面级双击：跟唱模式开关（对齐 iOS LyricsView——highPriority 双击优先，
        // 行单击等双击判定失败后才触发；快速双击 = 切换模式且不触发行跳转）
        .highPriorityGesture(
            TapGesture(count: 2)
                .onEnded {
                    karaoke.toggleKaraokeMode()
                }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("lyrics".localized, systemImage: "quote.bubble")
                .font(.headline)
            Spacer()
            Button(action: onLyricsSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("lyrics_search_title".localized)
            // 无关闭按钮：歌词常驻显示（2026-09-02 用户拍板：歌词是本 APP 第一重要功能）
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack {
                Spacer()
                ProgressView("lyrics_loading".localized)
                Spacer()
            }
        } else if let lyrics {
            if lyrics.isInstrumental {
                emptyState("instrumental_no_lyrics".localized)
            } else if !lyrics.syncedLyrics.isEmpty {
                syncedView(lyrics.syncedLyrics)
            } else if !lyrics.plainLyrics.isEmpty {
                plainView(lyrics.plainLyrics)
            } else {
                emptyState("no_lyrics".localized)
            }
        } else {
            emptyState("no_lyrics".localized)
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text(text)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Synced lyrics

    private func syncedView(_ lines: [LyricsLine]) -> some View {
        let activeIndex = LyricTiming.activeLineIndex(time: currentTime, in: lines)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        VStack(spacing: 2) {
                            Text(line.text)
                                .font(.system(size: 15))
                                .foregroundColor(index == activeIndex ? .white : .secondary)
                                .fontWeight(index == activeIndex ? .semibold : .regular)
                                .multilineTextAlignment(.center)
                                .id(index)
                            if let translation = line.translation, !translation.isEmpty {
                                Text(translation)
                                    .font(.system(size: 12))
                                    .foregroundColor(index == activeIndex ? .white.opacity(0.85) : Color.secondary.opacity(0.7))
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        // 对齐 iOS LyricsView：仅跟唱模式响应，决策统一走 clickLine
                        // （无 AB → 播放该句；等选终点 → 设 B；区间内 → 跳到该句播放）
                        // 普通 onTapGesture：页面级 highPriorityGesture 双击优先，
                        // 单击等双击窗口判定失败后触发（与 iOS 结构一致）
                        .onTapGesture {
                            guard karaoke.isKaraokeOn else { return }
                            KaraokeController.shared.clickLine(index: index)
                        }
                        .scaleEffect(index == activeIndex ? 1.06 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: activeIndex)
                        // 对齐 iOS LyricsView：AB 激活时端点行加 accentColor 小圆点
                        .overlay(alignment: .trailing) {
                            if let ab = karaoke.abLoop, karaoke.isKaraokeOn,
                               index == ab.a || index == ab.b {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 7, height: 7)
                                    .padding(.trailing, 26)
                            }
                        }
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 24)
            }
            .onChange(of: activeIndex) { newIndex in
                guard let newIndex else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onAppear {
                if let activeIndex {
                    proxy.scrollTo(activeIndex, anchor: .center)
                }
            }
        }
    }

    // MARK: - Plain lyrics

    private func plainView(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
    }
}

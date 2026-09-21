//  MacTagEditorView.swift
//  QQPlayer
//
//  标签编辑/刮削 sheet（web TagEditorModal.vue + /api/tags 移植，E1 刮削批 2026-09）。
//  实现：S4（UI 批）。用户已拍板形态：sheet 弹窗。
//
//  功能契约（web TagEditorModal + /api/tags 语义对齐）：
//  - 打开即自动刮削：等价 POST /api/tags/scrape → 候选分组展示
//    （netease[] / musicbrainz[] 分节；行：标题/歌手/专辑/封面缩略/年份/时长；
//    来源 badge；MB 候选带 track/genre/album_artist 尽力值）
//  - 初始表单值：从文件现读（AudioMetadataParser——文件才是真源，DB 可能旧，
//    避免保存时把文件真值覆盖成 DB 旧值）；专辑 year 用 track.albumId →
//    DB Album.year 兜底（文件解析无 year 时）
//  - 点选候选 → 填充表单（可再编辑）；网易云候选且表单 year 空 →
//    静默调 albumYear 补年份（等价 POST /api/tags/album-year，不阻塞不报错）
//  - 表单字段：title/artist/album/year/genre/track/album_artist + 封面区
//    （当前内嵌封面 MacArtworkThumbnail 预览 + 点选候选后「使用候选封面」
//    （下载 coverURL 得 Data 暂存）+「移除封面」）+ 重命名开关（默认：当前
//    文件名与模板渲染结果一致才 ON，否则 OFF；ON 时展示渲染目标名实时预览）
//  - 保存语义：表单非空文本才进 request（空 = 不写该字段，TagWriterService
//    语义）；coverData 只在用户选了候选封面时给；removeCover 用户点了才给
//  - 保存 = TagWriterService.writeTags → renamed 时 AppCoordinator.moveTrack
//    迁移引用 → 通知刷新（LibraryFolderContentChanged 一次性）→ 成功反馈；
//    播放队列中该曲目改名 → 队列/当前曲目路径跟随（不打断播放）
//  - 错误处理：TagWriterError.unsupportedFormat → 弹提示「该格式不支持写标签」；
//    写失败 → 红字真实原因（errorDescription）；moveTrack 抛错也要呈现
//    （文件已改名但 DB 迁移失败，提示用户重扫）
//  - 入口：MacTrackListView 右键菜单第 8 项「编辑标签/刮削」（单曲）
//
//  ⚠️ 与 web 差异（Mac 拍板）：重命名是可开关的（web 保存总是按模板改名）；
//  封面：点选候选即自动采用（web 同语义，2026-09-06 对齐修正）
//
//  QQPlayerMac target only。

import AppKit
import SwiftUI

struct MacTagEditorView: View {
    /// 分片：跨文件可见（原 private）
    @Environment(PlayerEngine.self) var playerEngine
    /// 分片：跨文件可见（原 private）
    @Environment(AppCoordinator.self) var appCoordinator
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    /// 分片：跨文件可见（原 private）
    @Environment(\.appAccentColor) var appAccentColor
    /// 分片：跨文件可见（原 private）
    @Environment(\.dismiss) var dismiss
    /// 分片：跨文件可见（原 private）
    @Environment(LibraryIndexer.self) var libraryIndexer

    /// 编辑目标（右键的那首歌；值拷贝，保存期间不依赖外部变化）
    let track: Track

    // MARK: 封面状态（keep = 不动文件现有封面）
    /// 分片：跨文件可见（原 private）
    enum CoverState {
        case keep
        case replace(Data)
        case remove
    }

    // MARK: 表单（与文件标签现读值同步；空 = 不写该字段）
    /// 分片：跨文件可见（原 private）
    @State var formTitle = ""
    /// 分片：跨文件可见（原 private）
    @State var formArtist = ""
    /// 分片：跨文件可见（原 private）
    @State var formAlbum = ""
    /// 分片：跨文件可见（原 private）
    @State var formYear = ""
    /// 分片：跨文件可见（原 private）
    @State var formGenre = ""
    /// 分片：跨文件可见（原 private）
    @State var formTrack = ""
    /// 分片：跨文件可见（原 private）
    @State var formAlbumArtist = ""
    /// 分片：跨文件可见（原 private）
    @State var coverState: CoverState = .keep

    // MARK: 刮削状态
    /// 分片：跨文件可见（原 private）
    @State var scrapeState: ScrapeState = .idle
    /// 分片：跨文件可见（原 private）
    @State var scrapeQuery = ""
    /// 分片：跨文件可见（原 private）
    @State var neteaseCandidates: [ScrapeCandidate] = []
    /// 分片：跨文件可见（原 private）
    @State var musicbrainzCandidates: [ScrapeCandidate] = []
    /// 当前点选候选的封面 URL（「使用候选封面」的下载源）
    /// 分片：跨文件可见（原 private）
    @State var selectedCoverURL: URL?

    // MARK: 重命名（模板来自设置 scraping.renameTemplate；默认关——文件名
    // 与模板渲染结果一致时才默认开，避免打开弹窗误触发改名）
    /// 分片：跨文件可见（原 private）
    @State var renameEnabled = false
    /// 分片：跨文件可见（原 private）
    @State var renameTemplate = TagWriterService.defaultRenameTemplate

    // MARK: 保存
    /// 分片：跨文件可见（原 private）
    @State var saving = false
    /// 分片：跨文件可见（原 private）
    @State var savedFlash = false
    /// 分片：跨文件可见（原 private）
    @State var saveError: String?
    /// 分片：跨文件可见（原 private）
    @State var showUnsupportedAlert = false
    /// 分片：跨文件可见（原 private）
    @State var renamePreviewText = ""

    // MARK: 文件解析（初始表单值；避免反复重扫文件）
    /// 分片：跨文件可见（原 private）
    @State var initialMetadata: AudioMetadata?
    @State private var loadFailed = false

    /// 刮削状态机（idle → searching → done/failed）
    /// 分片：跨文件可见（原 private）
    enum ScrapeState: Equatable {
        case idle
        case searching
        case done
        case failed(String)
    }

    private let scrapeTaskKey = "scrape"
    /// 分片：跨文件可见（原 private）
    @State var activeTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Body

    var body: some View {
        VStack(spacing: DesignTokens.space0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
        .task { await loadAndAutoScrape() }
        .onDisappear {
            activeTasks.values.forEach { $0.cancel() }
        }
        .alert("tag_editor_format_unsupported".localized, isPresented: $showUnsupportedAlert) {
            Button("ok".localized, role: .cancel) {}
        }
        .overlay(alignment: .bottom) {
            if savedFlash {
                HStack(spacing: DesignTokens.space6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("tag_editor_saved".localized)
                        .font(.callout)
                }
                .padding(.vertical, DesignTokens.space8)
                .padding(.horizontal, DesignTokens.space16)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, DesignTokens.space48)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignTokens.space8) {
            Image(systemName: "tag")
                .foregroundColor(appAccentColor)
            Text("tag_editor_title".localized)
                .font(.headline)
            Text(" · " + URL(fileURLWithPath: track.path).lastPathComponent)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignTokens.space16)
        .padding(.top, DesignTokens.space12)
        .padding(.bottom, DesignTokens.space10)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.space12) {
                mainEditor
                scrapeRow
                candidatesSection
                renameSection
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(DesignTokens.space16)
        }
    }

    /// 封面预览 + 表单（web tag-main 布局）
    private var mainEditor: some View {
        HStack(alignment: .top, spacing: DesignTokens.space12) {
            coverColumn
            formColumn
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("cancel".localized) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                save()
            } label: {
                HStack(spacing: DesignTokens.space4) {
                    if saving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("save".localized)
                }
                .frame(minWidth: 70)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave || saving)
        }
        .padding(.horizontal, DesignTokens.space16)
        .padding(.vertical, DesignTokens.space10)
    }

    // MARK: - 初始加载 + 自动刮削

    /// 打开即自动刮削：先解析文件标签填表单（真源），再自动刮削一次
    private func loadAndAutoScrape() async {
        await loadInitialValues()
        await runScrape()
    }

    /// 初始表单值：从文件现读（AudioMetadataParser）；year 缺失 → DB Album.year 兜底
    private func loadInitialValues() async {
        let url = URL(fileURLWithPath: track.path)
        let metadata: AudioMetadata?
        do {
            metadata = try await AudioMetadataParser.parseMetadata(from: url)
            loadFailed = false
        } catch {
            metadata = nil
            loadFailed = true
        }
        initialMetadata = metadata
        formTitle = metadata?.title ?? ""
        formArtist = metadata?.artist ?? ""
        formAlbum = metadata?.album ?? ""
        formGenre = AudioMetadataParser.normalizedGenre(metadata?.genre) ?? ""
        if let trackNumber = metadata?.trackNumber {
            formTrack = String(trackNumber)
        }
        formAlbumArtist = metadata?.albumArtist ?? ""
        if let year = metadata?.year {
            formYear = String(year)
        } else if let albumId = track.albumId,
                  let album = try? LibraryReads.album(id: albumId),
                  let albumYear = album.year {
            formYear = String(albumYear) // 专辑 year 兜底（文件解析无 year）
        }
        // 重命名开关默认：当前文件名与模板渲染结果一致才 ON，否则 OFF
        renameTemplate = DeleteSettings.load().scrapingRenameTemplate
        renameEnabled = renderedTargetName() == URL(fileURLWithPath: track.path).lastPathComponent
        updateRenamePreview()
    }
}

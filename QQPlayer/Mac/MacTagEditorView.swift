//
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
//  - 保存 = TagWriterService.writeTags → renamed 时 DatabaseManager.moveTrack
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
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    @Environment(\.appAccentColor) private var appAccentColor
    @Environment(\.dismiss) private var dismiss

    /// 编辑目标（右键的那首歌；值拷贝，保存期间不依赖外部变化）
    let track: Track

    // MARK: 封面状态（keep = 不动文件现有封面）
    private enum CoverState {
        case keep
        case replace(Data)
        case remove
    }

    // MARK: 表单（与文件标签现读值同步；空 = 不写该字段）
    @State private var formTitle = ""
    @State private var formArtist = ""
    @State private var formAlbum = ""
    @State private var formYear = ""
    @State private var formGenre = ""
    @State private var formTrack = ""
    @State private var formAlbumArtist = ""
    @State private var coverState: CoverState = .keep

    // MARK: 刮削状态
    @State private var scrapeState: ScrapeState = .idle
    @State private var scrapeQuery = ""
    @State private var neteaseCandidates: [ScrapeCandidate] = []
    @State private var musicbrainzCandidates: [ScrapeCandidate] = []
    /// 当前点选候选的封面 URL（「使用候选封面」的下载源）
    @State private var selectedCoverURL: URL?

    // MARK: 重命名（模板来自设置 scraping.renameTemplate；默认关——文件名
    // 与模板渲染结果一致时才默认开，避免打开弹窗误触发改名）
    @State private var renameEnabled = false
    @State private var renameTemplate = TagWriterService.defaultRenameTemplate

    // MARK: 保存
    @State private var saving = false
    @State private var savedFlash = false
    @State private var saveError: String?
    @State private var showUnsupportedAlert = false
    @State private var renamePreviewText = ""

    // MARK: 文件解析（初始表单值；避免反复重扫文件）
    @State private var initialMetadata: AudioMetadata?
    @State private var loadFailed = false

    /// 刮削状态机（idle → searching → done/failed）
    private enum ScrapeState: Equatable {
        case idle
        case searching
        case done
        case failed(String)
    }

    private let scrapeTaskKey = "scrape"
    @State private var activeTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
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
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("tag_editor_saved".localized)
                        .font(.callout)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 50)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
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
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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
            .padding(16)
        }
    }

    /// 封面预览 + 表单（web tag-main 布局）
    private var mainEditor: some View {
        HStack(alignment: .top, spacing: 14) {
            coverColumn
            formColumn
        }
    }

    // MARK: 封面列

    private var coverColumn: some View {
        VStack(spacing: 8) {
            coverPreview
            Text("tag_editor_cover".localized)
                .font(.caption2)
                .foregroundColor(.secondary)
            Button {
                downloadCandidateCover()
            } label: {
                Label("tag_editor_use_candidate_cover".localized, systemImage: "photo.badge.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(selectedCoverURL == nil || saving)
            .help("tag_editor_use_candidate_cover_help".localized)

            Button(role: .destructive) {
                coverState = .remove
            } label: {
                Label("tag_editor_remove_cover".localized, systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(saving)
        }
        .frame(width: 150)
    }

    @ViewBuilder
    private var coverPreview: some View {
        Group {
            switch coverState {
            case .keep:
                MacArtworkThumbnail(track: track, size: 132, cornerRadius: 10)
            case .replace(let data):
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholderCover
                }
            case .remove:
                placeholderCover
            }
        }
        .frame(width: 132, height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.gray.opacity(0.25), lineWidth: 1)
        )
    }

    private var placeholderCover: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.gray.opacity(0.15))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
            }
    }

    // MARK: 表单列

    private var formColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("title".localized, text: $formTitle, disabled: saving)
            field("artist".localized, text: $formArtist, disabled: saving)
            field("album".localized, text: $formAlbum, disabled: saving)
            HStack(spacing: 10) {
                field("tag_editor_field_year".localized, text: $formYear, disabled: saving)
                field("tag_editor_field_genre".localized, text: $formGenre, disabled: saving)
            }
            HStack(spacing: 10) {
                field("tag_editor_field_track".localized, text: $formTrack, disabled: saving)
                field("tag_editor_field_album_artist".localized, text: $formAlbumArtist, disabled: saving)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .disabled(disabled)
        }
    }

    // MARK: 刮削行

    private var scrapeRow: some View {
        HStack(spacing: 8) {
            switch scrapeState {
            case .idle:
                emptyRow
            case .searching:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("tag_editor_scraping".localized)
                        .foregroundColor(.secondary)
                }
            case .done:
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundColor(appAccentColor)
                    if !scrapeQuery.isEmpty {
                        Text(scrapeQuery)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Button("tag_editor_scrape_again".localized) {
                        Task { await runScrape() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(saving)
                }
            case .failed(let message):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.red)
                    Text(message)
                        .foregroundColor(.red)
                        .lineLimit(1)
                    Spacer()
                    Button("tag_editor_scrape_again".localized) {
                        Task { await runScrape() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(saving)
                }
            }
            Spacer()
        }
        .font(.caption)
        .padding(.vertical, 2)
    }

    private var emptyRow: some View {
        Text("tag_editor_scrape_again".localized)
            .foregroundColor(.secondary)
            .onTapGesture {
                Task { await runScrape() }
            }
    }

    // MARK: 候选区（netease / musicbrainz 两组，展示顺序跟随设置 scrapingSourceOrder）

    @ViewBuilder
    private var candidatesSection: some View {
        if scrapeState != .idle && scrapeState != .searching {
            if neteaseCandidates.isEmpty && musicbrainzCandidates.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                    Text("tag_editor_no_candidates".localized)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(orderedSources, id: \.self) { source in
                        switch source {
                        case "musicbrainz":
                            candidateGroup(
                                title: "source_musicbrainz".localized,
                                icon: "brain.head.profile",
                                candidates: musicbrainzCandidates,
                                source: "musicbrainz"
                            )
                        default: // "netease"
                            candidateGroup(
                                title: "source_netease".localized,
                                icon: "cloud",
                                candidates: neteaseCandidates,
                                source: "netease"
                            )
                        }
                    }
                }
            }
        }
    }

    /// 源展示顺序 = 设置 scrapingSourceOrder（默认 netease 优先）；设置含未知源时过滤
    private var orderedSources: [String] {
        let known: Set<String> = ["netease", "musicbrainz"]
        let order = DeleteSettings.load().scrapingSourceOrder
        return order.filter { known.contains($0) }
    }

    private func candidateGroup(
        title: String,
        icon: String,
        candidates: [ScrapeCandidate],
        source: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
            }
            .foregroundColor(appAccentColor)
            if candidates.isEmpty {
                Text("tag_editor_no_candidates".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                    Button {
                        pick(candidate, source: source)
                    } label: {
                        MacTagEditorCandidateRow(candidate: candidate)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 重命名

    private var renameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $renameEnabled) {
                Text("tag_editor_rename_files".localized)
                    .font(.callout)
            }
            .disabled(saving)
            .onChange(of: renameEnabled) { _ in
                updateRenamePreview()
            }
            HStack(spacing: 8) {
                Text("scraping_rename_preview".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(renamePreviewText.isEmpty ? "—" : renamePreviewText)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(renameEnabled ? appAccentColor : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.leading, 2)
        }
        .onChange(of: formTitle) { _ in updateRenamePreview() }
        .onChange(of: formArtist) { _ in updateRenamePreview() }
        .onChange(of: formAlbum) { _ in updateRenamePreview() }
        .onChange(of: formYear) { _ in updateRenamePreview() }
        .onChange(of: formTrack) { _ in updateRenamePreview() }
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
                HStack(spacing: 5) {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 无可保存内容（全空 + 封面未动）→ 禁用保存（web「至少一个非空」语义的
    /// Mac 原生表达；封面操作/移除也算可保存）
    private var canSave: Bool {
        let textNonEmpty = [formTitle, formArtist, formAlbum, formGenre, formAlbumArtist]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let yearNonEmpty = !formYear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let trackNonEmpty = !formTrack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let coverChanged: Bool = {
            switch coverState {
            case .keep: return false
            case .replace, .remove: return true
            }
        }()
        return textNonEmpty || yearNonEmpty || trackNonEmpty || coverChanged
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
                  let album = try? DatabaseManager.shared.getAlbum(byId: albumId),
                  let albumYear = album.year {
            formYear = String(albumYear) // 专辑 year 兜底（文件解析无 year）
        }
        // 重命名开关默认：当前文件名与模板渲染结果一致才 ON，否则 OFF
        renameTemplate = DeleteSettings.load().scrapingRenameTemplate
        renameEnabled = renderedTargetName() == URL(fileURLWithPath: track.path).lastPathComponent
        updateRenamePreview()
    }

    // MARK: - 刮削（web POST /api/tags/scrape 等价）

    private func runScrape() async {
        // query = 文件 title（解析失败回落文件名 stem）
        let query = ScrapeLogic.searchQuery(
            title: initialMetadata?.title,
            fileName: track.path
        )
        scrapeQuery = query
        scrapeState = .searching
        neteaseCandidates = []
        musicbrainzCandidates = []
        let artist = initialMetadata?.artist ?? ""
        let sources = await ScrapeBatchService.scrapeSources(query: query, artist: artist)
        guard !Task.isCancelled else { return }
        neteaseCandidates = sources.netease
        musicbrainzCandidates = sources.musicbrainz
        scrapeState = .done
    }

    /// 点选候选 → 填充表单（web pick 语义：候选有值才填，空值清空对应字段；
    /// 封面记录到 selectedCoverURL，需用户显式「使用候选封面」才下载）
    private func pick(_ candidate: ScrapeCandidate, source: String) {
        formTitle = candidate.title ?? ""
        formArtist = candidate.artist ?? ""
        formAlbum = candidate.album ?? ""
        if let year = candidate.year {
            formYear = String(year)
        } else {
            formYear = ""
        }
        if let genre = candidate.genre, !genre.isEmpty {
            formGenre = genre
        } else {
            formGenre = ""
        }
        if let track = candidate.track {
            formTrack = String(track)
        } else {
            formTrack = ""
        }
        formAlbumArtist = candidate.albumArtist ?? ""
        selectedCoverURL = candidate.coverURL
        // 点选候选 = 自动采用候选封面（web 语义对齐：点选即记录并使用 cover_url，
        // 不需要额外按钮）。先回到文件现状，有 coverURL → 自动下载暂存（成功替换
        // 预览；失败留 keep 并在表单底部红字提示，可手动「使用候选封面」重试）；
        // 无 coverURL → 保持文件现状。
        coverState = .keep
        if let coverURL = candidate.coverURL {
            downloadCandidateCover(from: coverURL)
        }
        updateRenamePreview()

        // 网易云候选且表单 year 空 → 静默补年份（POST /api/tags/album-year 等价；
        // 异步 + 静默失败，不阻塞点选）
        if source == "netease", let id = candidate.id, formYear.isEmpty {
            activeTasks["albumYear"]?.cancel()
            let songID = Int(id)
            activeTasks["albumYear"] = Task {
                let year = await NeteaseOnlineClient().albumYear(songID: songID ?? 0)
                guard !Task.isCancelled else { return }
                if let year, formYear.isEmpty {
                    formYear = String(year)
                    updateRenamePreview()
                }
            }
        }
    }

    /// 下载候选封面 → Data 暂存（保存时才写入文件）。点选候选行自动调用；
    /// 「使用候选封面」按钮作为失败后的手动重试。
    private func downloadCandidateCover(from url: URL? = nil) {
        guard let url = url ?? selectedCoverURL, !saving else { return }
        let taskKey = "coverDownload"
        activeTasks[taskKey]?.cancel()
        activeTasks[taskKey] = Task {
            let data = try? await Self.downloadCoverData(from: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if let data {
                    coverState = .replace(data)
                    saveError = nil
                } else {
                    saveError = "tag_editor_cover_download_failed".localized
                }
            }
        }
    }

    /// 封面下载（JPEG/PNG 校验，web tag_editor.fetch_cover 语义）
    private static func downloadCoverData(from url: URL) async throws -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("QQPlayer/1.0 (https://github.com/daxmate/qqplayer)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              !data.isEmpty,
              data.starts(with: [0xFF, 0xD8, 0xFF]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            return nil
        }
        return data
    }

    // MARK: - 重命名预览

    /// 模板渲染目标文件名（含相对子目录路径）；渲染失败/空 → ""（不改名）
    private func renderedTargetName() -> String {
        let ext = URL(fileURLWithPath: track.path).pathExtension
        return TagRenameLogic.renderFileName(
            template: renameTemplate,
            values: TagRenameLogic.Values(
                artist: formArtist.isEmpty ? nil : formArtist,
                title: formTitle.isEmpty ? nil : formTitle,
                album: formAlbum.isEmpty ? nil : formAlbum,
                track: Int(formTrack),
                year: Int(formYear)
            ),
            ext: ext.isEmpty ? "" : "." + ext
        ) ?? ""
    }

    private func updateRenamePreview() {
        renamePreviewText = renderedTargetName()
    }

    // MARK: - 保存（web POST /api/tags 等价）

    private func save() {
        guard !saving, canSave else { return }
        saving = true
        saveError = nil
        let originalPath = track.path
        let request = buildRequest()
        let oldStableId = track.stableId

        // 写标签 + DB 迁移是阻塞 IO → 后台执行，完成后 hop 主线程
        Task.detached(priority: .userInitiated) {
            do {
                let result = try TagWriterService.writeTags(
                    to: URL(fileURLWithPath: originalPath),
                    request: request
                )
                if result.renamed {
                    // 改名 → moveTrack 迁移引用（幂等；文件已改名但迁移失败 → 提示重扫）
                    try DatabaseManager.shared.moveTrack(
                        from: originalPath,
                        to: result.finalURL.path
                    )
                    let migrated = try DatabaseManager.shared.getTrack(byPath: result.finalURL.path)
                    await MainActor.run {
                        finishSaveSuccess(renamed: true, oldStableId: oldStableId, migrated: migrated, finalPath: result.finalURL.path)
                    }
                } else {
                    await MainActor.run {
                        finishSaveSuccess(renamed: false, oldStableId: oldStableId, migrated: nil, finalPath: result.finalURL.path)
                    }
                }
            } catch {
                await MainActor.run {
                    finishSaveFailure(error)
                }
            }
        }
    }

    /// 构造写标签请求：非空文本才进 request；coverData/removeCover 按用户显式选择
    private func buildRequest() -> TagWriteRequest {
        var request = TagWriteRequest()
        request.title = trimmed(formTitle)
        request.artist = trimmed(formArtist)
        request.album = trimmed(formAlbum)
        request.genre = trimmed(formGenre)
        request.albumArtist = trimmed(formAlbumArtist)
        request.year = Int(formYear)
        request.trackNumber = Int(formTrack)
        request.renameTemplate = renameEnabled ? renameTemplate : nil
        switch coverState {
        case .keep:
            break
        case .replace(let data):
            request.coverData = data
        case .remove:
            request.removeCover = true
        }
        return request
    }

    private func trimmed(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private func finishSaveSuccess(renamed: Bool, oldStableId: String, migrated: Track?, finalPath: String) {
        saving = false
        if renamed, let migrated {
            followRenamedTrackInPlayback(oldStableId: oldStableId, newTrack: migrated)
        }
        // 单文件入库同步：保存只改了文件，DB 里的 title/artist/album/genre/year 与
        // 封面缓存仍是旧值 → 列表不刷新（旧实现只发 LibraryFolderContentChanged，
        // 要等整库重扫扫到这首歌才更新，歌单/自动歌单详情容器还不监听）。
        // 这里直接对该文件跑一次 indexer 单文件处理：解析 → upsert DB →
        // forceRefreshArtwork（封面缓存）→ 完成后内部 post LibraryNeedsRefresh，
        // 所有列表容器（主库/歌单详情/自动歌单/专辑卡）立即重拉新值。
        Task {
            _ = await LibraryIndexer.shared.processExternalFile(URL(fileURLWithPath: finalPath))
            // DB 已同步到最新标签 → 把播放上下文（当前曲目/队列）替换成 DB 新行，
            // 未改名时播放页标题/歌手也立即跟随（改名场景已在上面用 migrated 处理，
            // 此处按 oldStableId 匹配为幂等 no-op）
            if let fresh = try? DatabaseManager.shared.getTrack(byPath: finalPath) {
                followRenamedTrackInPlayback(oldStableId: oldStableId, newTrack: fresh)
            }
            // 兜底补发（processExternalFile 提前返回/指纹未变时也保证列表刷新）
            NotificationCenter.default.post(
                name: NSNotification.Name("LibraryNeedsRefresh"),
                object: nil
            )
        }
        // 成功反馈：短暂 flash 后自动关闭（web toast + close 语义）
        withAnimation { savedFlash = true }
        activeTasks["savedFlash"] = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                dismiss()
            }
        }
    }

    private func finishSaveFailure(_ error: Error) {
        saving = false
        if let tagError = error as? TagWriterError,
           case .unsupportedFormat = tagError {
            showUnsupportedAlert = true
            return
        }
        // 写失败/迁移失败 → 红字真实原因
        if case let TagWriterError.writeFailed(reason) = error {
            saveError = "tag_editor_save_failed".localized + ": " + reason
        } else if case TagWriterError.fileNotReadable = error {
            saveError = "tag_editor_save_failed".localized + ": " + (error.localizedDescription)
        } else {
            // moveTrack 抛错等：文件可能已改名但 DB 未迁移 → 提示重扫
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            saveError = "tag_editor_db_migrate_failed".localized(with: detail)
        }
    }

    /// 播放队列路径跟随（web「改名后目标歌曲路径跟随，不打断播放」语义）：
    /// 编辑对象若在播放队列/正在播放 → 用迁移后的新 Track 替换（含新 stableId），
    /// 不调 loadTrack/playTrack —— 已加载的音频继续播，下次切到它用新路径加载。
    @MainActor
    private func followRenamedTrackInPlayback(oldStableId: String, newTrack: Track) {
        let player = PlayerEngine.shared
        if player.currentTrack?.stableId == oldStableId {
            player.currentTrack = newTrack
        }
        if player.playbackQueue.contains(where: { $0.stableId == oldStableId }) {
            player.playbackQueue = player.playbackQueue.map {
                $0.stableId == oldStableId ? newTrack : $0
            }
        }
        if player.originalQueue.contains(oldStableId) {
            player.originalQueue = player.originalQueue.map {
                $0 == oldStableId ? newTrack.stableId : $0
            }
        }
        player.normalizeIndexAndTrack()
    }
}

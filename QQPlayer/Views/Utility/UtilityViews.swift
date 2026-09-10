import SwiftUI

struct InitializationView: View {
    @StateObject private var libraryIndexer = LibraryIndexer.shared
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var settings = DeleteSettings.load()

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            VStack(spacing: 8) {
                Text(statusMessage)
                    .font(.headline)

                if libraryIndexer.isIndexing {
                    VStack(spacing: 8) {
                        Text(Localized.foundTracks(libraryIndexer.tracksFound))
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        // Current file being processed
                        if !libraryIndexer.currentlyProcessing.isEmpty {
                            VStack(spacing: 4) {
                                Text(Localized.processingColon)
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Text(libraryIndexer.currentlyProcessing)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(settings.backgroundColorChoice.color)
                                    .lineLimit(1)
                                    .frame(maxWidth: 250)
                            }
                        }

                        // Progress bar and percentage
                        HStack {
                            Text(Localized.percentComplete(Int(libraryIndexer.indexingProgress * 100)))
                                .font(.caption)
                                .foregroundColor(settings.backgroundColorChoice.color)
                                .frame(width: 35, alignment: .leading)

                            ProgressView(value: libraryIndexer.indexingProgress)
                                .frame(maxWidth: 200)
                        }

                        // Queued files
                        if !libraryIndexer.queuedFiles.isEmpty {
                            VStack(spacing: 2) {
                                Text(Localized.waitingColon)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                ForEach(libraryIndexer.queuedFiles.prefix(3), id: \.self) { fileName in
                                    Text(fileName)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: 250)
                                }

                                if libraryIndexer.queuedFiles.count > 3 {
                                    Text(Localized.andMore(libraryIndexer.queuedFiles.count - 3))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 10)
    }

    private var statusMessage: String {
        // M3-2：本地沙盒是唯一数据源——索引中统一显示本地曲库文案
        "Setting up your local music library..."
    }
}

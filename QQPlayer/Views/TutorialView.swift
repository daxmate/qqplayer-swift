//
//  TutorialView.swift
//  QQPlayer
//
//  Tutorial flow for first-time users
//

import SwiftUI

struct TutorialView: View {
    @StateObject private var viewModel = TutorialViewModel()
    @Environment(\.dismiss) private var dismiss
    var onComplete: (() -> Void)?
    @State private var settings = DeleteSettings.load()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // M3-2：音乐存储已切本地沙盒 Documents（退役 iCloud）——单步引导
                // （在 Files app 的「我的 iPhone → QQPlayer」中放入音乐）。
                MusicFilesStepView(viewModel: viewModel, onComplete: onComplete)
            }
            .navigationTitle(Localized.welcomeToQQPlayer)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden()
        }
    }
}

struct MusicFilesStepView: View {
    @ObservedObject var viewModel: TutorialViewModel
    @Environment(\.dismiss) private var dismiss
    var onComplete: (() -> Void)?
    @State private var settings = DeleteSettings.load()

    var body: some View {
        ScrollView {
            VStack(spacing: 25) {
                Spacer(minLength: 20)

                Image(systemName: "music.note")
                    .font(.system(size: 70))
                    .foregroundColor(settings.backgroundColorChoice.color)

                VStack(spacing: 12) {
                    Text(Localized.addYourMusic)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(Localized.howToAddMusic)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)
                }

                VStack(alignment: .leading, spacing: 16) {
                    InstructionRow(
                        step: "1",
                        title: Localized.openFilesApp,
                        description: Localized.findOpenFilesApp
                    )

                    InstructionRow(
                        step: "2",
                        title: Localized.navigateToOnMyIphone,
                        description: Localized.tapOnMyIphoneSidebar
                    )

                    InstructionRow(
                        step: "3",
                        title: Localized.findQQPlayerFolder,
                        description: Localized.lookForQQPlayerFolder
                    )

                    InstructionRow(
                        step: "4",
                        title: Localized.addYourMusicInstruction,
                        description: Localized.copyMusicFiles
                    )
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 20)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                // Gradient overlay to separate content from buttons
                LinearGradient(
                    colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 20)

                HStack {
                    Spacer()

                    Button(Localized.getStarted) {
                        print("🎯 Get Started button tapped")
                        viewModel.completeTutorial()
                        print("🎯 About to dismiss tutorial")
                        onComplete?()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 40)
                .background(Color(.systemBackground))
            }
        }
    }
}

struct InstructionRow: View {
    let step: String
    let title: String
    let description: String
    @State private var settings = DeleteSettings.load()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(step)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(settings.backgroundColorChoice.color))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    TutorialView()
}

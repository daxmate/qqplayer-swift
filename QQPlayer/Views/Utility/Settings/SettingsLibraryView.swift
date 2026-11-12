//
//  SettingsLibraryView.swift
//  QQPlayer
// target: ios-only
//
//  设置 → 资料库（原 SettingsView 的 librarySection Section + 回收区入口 +
//  首页分区显示与排序，2026-11-12 设置页分类化迁移）。
//  文案 / 存储字段 / 默认值 / 显示顺序与迁移前逐行一致。
//

import SwiftUI

struct SettingsLibraryView: View {
    @State private var deleteSettings = DeleteSettings.load()

    var body: some View {
        Form {
            Section(Localized.librarySection) {
                Toggle(Localized.removeFromLibraryOnly, isOn: $deleteSettings.deleteFromLibraryOnly)
                    .onChange(of: deleteSettings.deleteFromLibraryOnly) { _, _ in
                        deleteSettings.save()
                    }

                Text(Localized.removeFromLibraryOnlyDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 回收区（2026-09-29 回收区管理批）：查看 / 恢复 / 彻底删除
            // （生产回收区 <曲库根>/.Trash；业务逻辑全在 Services，本页只做入口）。
            Section {
                NavigationLink(destination: ReclaimAreaView()) {
                    HStack {
                        Image(systemName: "trash")
                            .foregroundColor(.blue)
                            .font(.system(size: DesignTokens.font20))
                        Text("reclaim_area".localized)
                    }
                }
            } footer: {
                Text("reclaim_area_description".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                ForEach($deleteSettings.homeSections) { $section in
                    HStack {
                        Image(systemName: section.id.icon)
                            .foregroundColor(.secondary)
                            .frame(width: 24)

                        Toggle(section.id.displayName, isOn: $section.isVisible)
                            .onChange(of: section.isVisible) { _, _ in
                                deleteSettings.save()
                            }
                    }
                }
                .onMove { source, destination in
                    deleteSettings.homeSections.move(fromOffsets: source, toOffset: destination)
                    deleteSettings.save()
                }

                Text(Localized.chooseVisibleSections)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                HStack {
                    Text(Localized.homeSections)
                    Spacer()
                    EditButton()
                        .font(.caption)
                }
            }
        }
        .navigationTitle(Localized.librarySection)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView {
        SettingsLibraryView()
    }
}

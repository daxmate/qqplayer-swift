//
//  MacTrackSortMenu.swift
//  QQPlayer
//
//  macOS 歌曲列表的工具条「排序」菜单（QQPlayerMac target only）。
//
//  背景（2026-11-23）：列表为纯净观感隐藏了表头（MacTrackListView 的
//  `.tableColumnHeaders(.hidden)`），点列头排序的入口随之消失；排序状态
//  `sortOrder` 与 `.onChange(of: sortOrder)` 的重排逻辑仍在。本视图只把
//  「字段 + 方向」翻译成 SortDescriptor 数组写回 sortOrder —— 排序实现完全复用
//  既有链路（Table 原生排序 + displayedRows 镜像），不另起一套排序代码。
//
//  ⚠️ 排序 KeyPath 必须指向 MacTrackTableRow 的 @objc 存储属性：SortDescriptor /
//  TableColumn(value:) 经 OC runtime 内省，计算属性会运行期 fatal（见
//  MacTrackListView.swift 文件头，2026-09-02 用户实测）。
//

import SwiftUI

/// 列表可排序字段（顺序 = 菜单里的展示顺序）。
enum MacTrackSortField: CaseIterable {
    case title
    case artist
    case album
    case duration

    /// 菜单文案：复用列表列头同一批本地化 key（title / artist / album / duration）。
    var title: String {
        switch self {
        case .title: return "title".localized
        case .artist: return "artist".localized
        case .album: return "album".localized
        case .duration: return "duration".localized
        }
    }

    /// 升/降序对应的排序描述符（字段 ↔ @objc 存储属性一一对应）。
    func descriptor(ascending: Bool) -> SortDescriptor<MacTrackTableRow> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch self {
        case .title: return SortDescriptor(\.title, order: order)
        case .artist: return SortDescriptor(\.artistName, order: order)
        case .album: return SortDescriptor(\.albumName, order: order)
        case .duration: return SortDescriptor(\.durationMs, order: order)
        }
    }
}

/// 工具条「排序」菜单：字段 × 方向 + 「默认顺序」复位。
/// 当前生效项靠菜单勾选 + 标题箭头（↑ / ↓）标出（表头已隐藏，没有列头指示器）。
struct MacTrackSortMenu: View {
    @Binding var sortOrder: [SortDescriptor<MacTrackTableRow>]

    var body: some View {
        Menu {
            Toggle(isOn: defaultOrderBinding) {
                Text("sort_default".localized)
            }
            Divider()
            ForEach(MacTrackSortField.allCases, id: \.self) { field in
                Toggle(isOn: directionBinding(for: field, ascending: true)) {
                    Text("\(field.title) ↑")
                }
                Toggle(isOn: directionBinding(for: field, ascending: false)) {
                    Text("\(field.title) ↓")
                }
            }
        } label: {
            Label("sort".localized, systemImage: "arrow.up.arrow.down")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("sort".localized)
    }

    /// 「默认顺序」= 清空 sortOrder：Table 回到曲目原始顺序（= 隐藏表头之前的表现）。
    private var defaultOrderBinding: Binding<Bool> {
        Binding(
            get: { sortOrder.isEmpty },
            set: { isOn in
                if isOn { sortOrder = [] }
            }
        )
    }

    /// 单项勾选状态：只在「恰好是这一条描述符」时为真。
    /// 用描述符**值**比较（SortDescriptor 对 NSObject 行类型是 Equatable）；
    /// 不比较 keyPath —— 从 descriptor 取出的 PartialKeyPath 与字面量 `==` 不成立（实测）。
    private func directionBinding(for field: MacTrackSortField, ascending: Bool) -> Binding<Bool> {
        let target = field.descriptor(ascending: ascending)
        return Binding(
            get: { sortOrder == [target] },
            set: { isOn in
                if isOn { sortOrder = [target] }
            }
        )
    }
}

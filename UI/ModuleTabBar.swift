import SwiftUI

/// 底部标签栏：图标式胶囊切换
struct ModuleTabBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let boxes: [ModuleBox]
    @Binding var selection: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(boxes) { box in
                tabButton(box)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    private func tabButton(_ box: ModuleBox) -> some View {
        let isSelected = box.id == (selection ?? boxes.first?.id)
        return Button {
            withAnimation(NotchMotion.unlessReducedMotion(NotchMotion.layout, reduceMotion)) {
                selection = box.id
            }
        } label: {
            Image(systemName: box.systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(box.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(box.title)
        .animation(NotchMotion.unlessReducedMotion(NotchMotion.layout, reduceMotion), value: selection)
    }
}

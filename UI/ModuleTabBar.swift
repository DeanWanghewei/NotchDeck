import SwiftUI

/// 底部标签栏：图标式胶囊切换
struct ModuleTabBar: View {
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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
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
        .help(box.title)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selection)
    }
}

import SwiftUI

/// 权限交互由宿主提供，模块只绑定自己的提醒开关。
struct NotificationPermissionToggle: View {
    let title: String
    @Binding var isOn: Bool
    @ObservedObject private var service = AppNotificationService.shared
    @State private var requesting = false

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: Binding(get: { isOn }, set: { enabled in
                guard enabled else { isOn = false; return }
                requesting = true
                service.requestPermission { granted in
                    requesting = false
                    isOn = granted
                }
            })).disabled(requesting)
            if let message = service.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

import Foundation
import UserNotifications
import Combine

struct AppNotification: Equatable {
    let id: String
    let title: String
    let body: String
}

protocol AppNotificationSending {
    /// completion 在主队列返回；未授权或投递失败时允许下次有效采样重试。
    func send(_ notification: AppNotification, completion: @escaping (Bool) -> Void)
}

/// 所有模块共用系统通知通道；构造和后台投递均不触发权限申请。
final class AppNotificationService: NSObject, ObservableObject, AppNotificationSending, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationService()
    @Published private(set) var statusMessage: String?

    func requestPermission(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.statusMessage = granted ? nil : (error == nil ? "通知未获授权，请在系统设置 → 通知 → NotchDeck 中允许通知。" : "无法申请通知权限，请稍后重试。")
                completion(granted)
            }
        }
    }

    func send(_ notification: AppNotification, completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                DispatchQueue.main.async {
                    self.statusMessage = "通知未获授权，请在系统设置 → 通知 → NotchDeck 中允许通知。"
                    completion(false)
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)) { error in
                DispatchQueue.main.async {
                    self.statusMessage = error == nil ? nil : "消息投递失败，下次刷新将重试。"
                    completion(error == nil)
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

/// 可供任何指标模块复用：同一阈值、同一周期只触发一次；无周期时降回阈值下方才重新布防。
struct ThresholdAlertGate {
    private struct State: Equatable {
        let threshold: Double
        let cycle: Date?
    }
    private var sent: [String: State] = [:]

    mutating func shouldNotify(key: String, value: Double, threshold: Double, cycle: Date?) -> Bool {
        guard value.isFinite, threshold.isFinite else { return false }
        guard value >= threshold else {
            if cycle == nil { sent.removeValue(forKey: key) }
            return false
        }
        let state = State(threshold: threshold, cycle: cycle)
        guard sent[key] != state else { return false }
        sent[key] = state
        return true
    }

    mutating func retry(key: String) { sent.removeValue(forKey: key) }
}

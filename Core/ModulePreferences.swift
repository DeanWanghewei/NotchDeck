import Combine
import Foundation
import SwiftUI

/// 一个组件拥有一份 Codable 配置，按稳定 id 隔离存储，无需向全局设置类添加字段。
/// 编码成功后才发布新值，失败保留内存与磁盘中的旧值，由组件设置页展示错误。
final class ModulePreferences<Value: Codable & Equatable>: ObservableObject {
    @Published private(set) var value: Value
    @Published private(set) var saveError: String?
    private let defaults: UserDefaults
    private let storageKey: String

    init(moduleID: String, defaultValue: Value, defaults: UserDefaults) {
        self.defaults = defaults
        storageKey = "modules.preferences.\(moduleID)"
        value = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode(Value.self, from: $0) } ?? defaultValue
    }

    @discardableResult
    func update(_ mutate: (inout Value) -> Void) -> Bool {
        var next = value
        mutate(&next)
        guard next != value else {
            if saveError != nil { saveError = nil }
            return true
        }
        do {
            let data = try JSONEncoder().encode(next)
            defaults.set(data, forKey: storageKey)
            saveError = nil
            value = next
            return true
        } catch {
            saveError = "无法保存组件设置，请检查配置值。"
            return false
        }
    }

    func binding<Member>(for keyPath: WritableKeyPath<Value, Member>) -> Binding<Member> {
        Binding(get: { self.value[keyPath: keyPath] },
                set: { newValue in self.update { $0[keyPath: keyPath] = newValue } })
    }
}

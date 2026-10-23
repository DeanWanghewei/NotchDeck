/// 内置组件的唯一装配入口；只创建实例，采集统一由注册表在启用后启动。
enum BuiltInModules {
    static func make(settings: SettingsStore) -> [ModuleBox] {
        [
            ModuleBox(MediaModule(settings: settings)),
            ModuleBox(VolumeModule()),
            ModuleBox(AppLauncherModule(settings: settings)),
            ModuleBox(SystemMonitor(settings: settings)),
            ModuleBox(NodeProcessScanner(settings: settings)),
            ModuleBox(CustomItemsModule(settings: settings)),
            ModuleBox(ClockModule(settings: settings)),
        ]
    }
}

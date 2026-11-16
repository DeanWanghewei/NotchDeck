/// 插件的可信实现随应用发布，GitHub 目录只控制介绍与兼容版本。
enum MarketplacePlugins {
    /// 原固定组件首次登记为已添加，保持新安装与升级前的默认布局。
    static let standardImplementations: [PluginImplementation] = [
        PluginImplementation(descriptor: MediaModule.descriptor, version: "1.0.0",
                             makeModule: { ModuleBox(MediaModule(settings: $0)) }, installedByDefault: true),
        PluginImplementation(descriptor: VolumeModule.descriptor, version: "1.0.0",
                             makeModule: { _ in ModuleBox(VolumeModule()) }, installedByDefault: true),
        PluginImplementation(descriptor: AppLauncherModule.descriptor, version: "1.0.0",
                             makeModule: { ModuleBox(AppLauncherModule(settings: $0)) }, installedByDefault: true),
        PluginImplementation(descriptor: SystemMonitor.descriptor, version: "1.0.0",
                             makeModule: { ModuleBox(SystemMonitor(settings: $0)) }, installedByDefault: true),
        PluginImplementation(descriptor: NodeProcessScanner.descriptor, version: "1.0.0",
                             makeModule: { ModuleBox(NodeProcessScanner(settings: $0)) }, installedByDefault: true),
        PluginImplementation(descriptor: CustomItemsModule.descriptor, version: "1.0.0",
                             makeModule: { ModuleBox(CustomItemsModule(settings: $0)) }, installedByDefault: true),
        PluginImplementation(descriptor: ClockModule.descriptor, version: "1.0.0",
                             makeModule: { ModuleBox(ClockModule(settings: $0)) }, installedByDefault: true),
    ]

    static let implementations: [PluginImplementation] = standardImplementations + [
        PluginImplementation(descriptor: SubscriptionQuotaModule.descriptor, version: "1.3.1",
                             makeModule: { ModuleBox(SubscriptionQuotaModule(settings: $0)) }),
    ]
}

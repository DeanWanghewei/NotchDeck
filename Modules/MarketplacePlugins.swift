/// 插件的可信实现随应用发布，GitHub 目录只控制介绍与兼容版本。
enum MarketplacePlugins {
    static let implementations: [PluginImplementation] = [
        PluginImplementation(descriptor: SubscriptionQuotaModule.descriptor, version: "1.1.3",
                             makeModule: { ModuleBox(SubscriptionQuotaModule(settings: $0)) }),
    ]
}

// swift-tools-version:6.0
import PackageDescription

// Liquid Glass（glassEffect / GlassEffectContainer / .buttonStyle(.glass)）是 macOS 26 才有的 API，
// 本机就是 macOS 26，直接把部署目标提到 v26，省去满屏 if #available 分支。
let package = Package(
    name: "FrpPanel",
    // 用字符串形式指定：当前 CommandLineTools 的 PackageDescription 还没有 .v26 枚举
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "FrpPanel", path: "Sources")
    ]
)

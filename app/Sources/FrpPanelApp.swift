import AppKit

// 菜单栏常驻 app：不用 SwiftUI 的 App/WindowGroup 生命周期，
// 否则启动时会自动开一个窗口、且关窗即退出，与"后台常驻"冲突。
@main
struct FrpPanelMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        // NSApplication.delegate 是 weak 引用，这个局部变量要活到 run() 结束（即进程退出）
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

import AppKit
import SwiftUI

/// 菜单栏常驻控制器。
/// app 以 LSUIElement 方式运行（不进 Dock、无菜单栏菜单），
/// 面板窗口按需创建，关掉窗口不退出进程。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private let model = PanelModel()
    private var healthTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        startHealthPolling()
    }

    /// LSUIElement 的 app 不会自动获得主菜单，不建的话 ⌘W / ⌘Q 这些标准快捷键全部失效，
    /// 且面板置前时菜单栏会残留上一个 app 的菜单。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "关于 frp 隧道面板",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏面板", action: #selector(hidePanelAction), keyEquivalent: "h")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 frp 隧道面板", action: #selector(quit), keyEquivalent: "q")
            .target = self
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(
            withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"
        )
        windowMenu.addItem(
            withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func hidePanelAction() {
        hidePanel()
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = menuBarImage()
        item.button?.image?.isTemplate = true
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    /// 菜单栏图标与 app 图标同源（同一套两端节点+隧道的设计），
    /// 打包为多分辨率模板 tiff，由系统按明暗主题着色。
    private func menuBarImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "tiff"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 20, height: 11)
            return image
        }
        // 资源缺失时退回系统符号，至少保证菜单栏里有个可点的图标
        return NSImage(
            systemSymbolName: "point.3.filled.connected.trianglepath.dotted",
            accessibilityDescription: "frp 隧道面板"
        )
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
        if rightClick {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "打开面板", action: #selector(openPanel), keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "退出", action: #selector(quit), keyEquivalent: "q"
        ).target = self
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // 用完立刻摘掉，否则左键点击会被菜单接管，无法切换面板
        statusItem?.menu = nil
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 面板窗口

    @objc private func openPanel() {
        showPanel()
    }

    private func togglePanel() {
        if let window, window.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        if window == nil {
            let hosting = NSHostingController(rootView: ContentView(model: model))
            let win = NSWindow(contentViewController: hosting)
            win.title = "frp 隧道面板"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            win.titlebarAppearsTransparent = true
            // 不设 isMovableByWindowBackground：那会让整个窗口内容区（包括输入框、按钮、
            // 滚动日志区）都变成拖拽热区，点哪都在拖窗口。.fullSizeContentView 只是让内容
            // 延伸到标题栏底下，原生标题栏那一条本身依然是可拖拽区域，不需要额外开这个开关。
            win.setContentSize(NSSize(width: 680, height: 780))
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.center()
            window = win
        }
        // 面板窗口整个进程生命周期只创建一次、之后靠 orderOut/makeKeyAndOrderFront 显隐，
        // SwiftUI 的内容视图从未真正被销毁重建，.onAppear/.onDisappear 因此永远不会触发。
        // 所以 5 秒自动刷新的启停必须由这里显式驱动，不能指望 ContentView 的生命周期回调。
        model.startAutoRefresh()
        // LSUIElement 的进程默认拿不到键盘焦点，临时提升为 regular 才能正常输入。
        // 策略变更要等 runloop 走一拍才对 AppKit 生效，同一拍里直接 activate 会被忽略，
        // 表现为窗口出来了但菜单栏还是上一个 app、输入框点不进去。
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func hidePanel() {
        window?.orderOut(nil)
        model.stopAutoRefresh()
        // 退回后台身份，Dock 图标随之消失
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return true
    }

    // MARK: - 菜单栏图标健康色

    /// 面板没打开时也要能一眼看出隧道是否正常，所以图标本身要反映状态。
    private func startHealthPolling() {
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.model.refresh()
                self?.updateStatusIcon()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let localOK = model.local?.connected ?? false
        let remoteOK = model.remote?.active ?? false
        let healthy = localOK && remoteOK

        button.contentTintColor = healthy ? nil : .systemRed
        button.toolTip = healthy
            ? "frp 隧道正常（\(model.local?.proxies.count ?? 0) 条）"
            : "frp 隧道异常：本地 \(localOK ? "正常" : "异常") / 远程 \(remoteOK ? "正常" : "异常")"
    }
}

// MARK: - 窗口关闭

extension AppDelegate: NSWindowDelegate {
    /// 点标题栏红灯关窗（或 ⌘W）时，AppKit 只会关闭窗口，不会动激活策略、
    /// 也不会经过 hidePanel()——这两件事这里都要补上，否则 Dock 图标赖着不走、
    /// 5 秒轮询也不会停。
    func windowWillClose(_ notification: Notification) {
        model.stopAutoRefresh()
        NSApp.setActivationPolicy(.accessory)
    }

    /// 最小化本身不需要处理（窗口仍属于 .regular 策略下的正常状态）。
    /// 但如果用户最小化后又按 ⌘H"隐藏面板"（走 hidePanel，与 minimize 是两条独立路径），
    /// 策略会被设回 .accessory；这之后用户从 Dock/Mission Control 直接把缩略图人工还原，
    /// AppKit 只会调这个回调，不会经过 showPanel()，策略/焦点的那套 dance 就被绕开了——
    /// 所以复原时无条件重放一遍 showPanel() 里同样的策略+激活逻辑。
    func windowDidDeminiaturize(_ notification: Notification) {
        model.startAutoRefresh()
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }
}

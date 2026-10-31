import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = Engine()
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        engine.start()
        NSApp.setActivationPolicy(.accessory)   // menu-bar app, no Dock icon

        // compact status popover
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 260, height: 280)
        let host = NSHostingController(
            rootView: StatusView(e: engine,
                                  onSettings: { [weak self] in self?.openSettings() },
                                  onQuit: { NSApp.terminate(nil) }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        // menu-bar item — sized to fit the menu bar (slightly larger than default)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            b.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Google Remote Voice")?
                .withSymbolConfiguration(cfg)
            b.image?.isTemplate = true
            b.imagePosition = .imageOnly
            b.action = #selector(iconClicked(_:))
            b.target = self
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        if CommandLine.arguments.contains("--settings") || !engine.axTrusted || !engine.inputMonitoringOK { openSettings() }
    }

    @objc func iconClicked(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if let ev = NSApp.currentEvent, ev.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
            for it in menu.items { it.target = self }
            statusItem.menu = menu
            button.performClick(nil)
            statusItem.menu = nil
            return
        }
        if popover.isShown { popover.performClose(sender) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            win.title = "Google Remote Voice · 设置"
            win.center()
            win.isReleasedWhenClosed = false
            win.contentView = NSHostingView(rootView: ContentView(e: engine))
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let wasActive = engine.googleCapture.active
        engine.shutdown()
        guard wasActive else { return .terminateNow }
        let deadline = Date().addingTimeInterval(8)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                if self?.engine.googleCapture.active != true || Date() >= deadline {
                    timer.invalidate(); sender.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

import AppKit
import SwiftUI

@main
@MainActor
enum SaveNestApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var model: AppModel!
    private var libraryWindow: NSWindow!
    private var captureEditor: NSPanel?
    private var tabSelectionPanel: NSPanel?
    private var tabSearchPanel: NSPanel?
    private var returnToApp: NSRunningApplication?
    private var editorDraftID: UUID?
    private var tabSelectionDraftID: UUID?
    private var statusItem: NSStatusItem!
    private var toastPanel: NSPanel?
    private var toastDismiss: DispatchWorkItem?
    private var pendingURLs: [URL] = []
    private var electronBridge: ElectronBridge?
    private var librarySession: LibrarySessionLock?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let isElectron = ProcessInfo.processInfo.arguments.contains("--electron-bridge")
        if isElectron && ProcessInfo.processInfo.arguments.contains("--ui-preview") && !AppLaunch.isPreview {
            ElectronBridge.failStartup("Preview requires a debug helper. Run npm run build:native first.")
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(isElectron ? .accessory : .regular)
        NSApp.appearance = AppAppearance.saved.nativeAppearance
        if !isElectron && pendingURLs.isEmpty && ApplicationMover.offerMoveIfNeeded() { return }
        if isElectron && !AppLaunch.isPreview {
            let otherCopy = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
            if otherCopy {
                ElectronBridge.failStartup("Quit the other SaveNest app, then reopen this one. Only one app can write your library.")
                NSApp.terminate(nil); return
            }
        }
        if !AppLaunch.isPreview {
            do { librarySession = try LibrarySessionLock() }
            catch {
                if isElectron { ElectronBridge.failStartup(error.localizedDescription) }
                else { let alert = NSAlert(); alert.messageText = error.localizedDescription; alert.runModal() }
                NSApp.terminate(nil); return
            }
        }
        model = AppModel()
        model.showTabSearch = { [weak self] in self?.openTabSearch() }
        model.tabSearch.close = { [weak self] in self?.tabSearchPanel?.orderOut(nil); self?.model.tabSearch.suspend() }
        model.showLibrary = { [weak self] in self?.openLibrary() }
        model.showAccount = { [weak self] in self?.openAccount() }
        model.account.presentationWindow = { [weak self] in self?.libraryWindow }
        model.account.bringAccountForward = { [weak self] in self?.openAccount() }
        model.showSettings = { [weak self] in self?.openSettings() }
        model.showCaptureEditor = { [weak self] draft in self?.openCaptureEditor(draft) }
        model.closeCaptureEditor = { [weak self] in self?.closeCaptureEditor() }
        model.showTabSelection = { [weak self] draft in self?.openTabSelection(draft) }
        model.closeTabSelection = { [weak self] in self?.closeTabSelection() }
        model.showToast = { [weak self] message in
            guard self?.electronBridge?.panelVisible != true else { return }
            self?.presentToast(message)
        }
        model.dismissClipboardNotice = { [weak self] in
            guard self?.model.toast?.clipboardURL != nil else { return }
            self?.toastPanel?.orderOut(nil); self?.model.toast = nil
        }
        let root = AppRootView(model: model).modifier(ElectronUtilitySheets(model: model, enabled: isElectron))
        libraryWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        libraryWindow.identifier = ElectronBridge.settingsWindowIdentifier
        libraryWindow.title = model.isPreview ? "SaveNest Preview — Settings" : "SaveNest Settings"; libraryWindow.titleVisibility = .hidden
        libraryWindow.titlebarAppearsTransparent = true; libraryWindow.isReleasedWhenClosed = false
        libraryWindow.backgroundColor = NSColor(Color.paper)
        let libraryContent = NSHostingView(rootView: root)
        // Navigation must not resize the window to a scroll view's entire content.
        libraryContent.sizingOptions = []
        libraryWindow.contentView = libraryContent
        libraryWindow.minSize = NSSize(width: 640, height: 520)
        if !model.isPreview { libraryWindow.setFrameAutosaveName("SaveNest.MinimalLibrary") }
        libraryWindow.center()
        setupMenus()
        if isElectron {
            electronBridge = ElectronBridge(model: model)
            model.tabSearch.close = { [weak self] in self?.electronBridge?.event("hide"); self?.model.tabSearch.suspend() }
            electronBridge?.start()
        } else {
            setupStatusItem(); openLibrary()
            model.updater.start()
        }
        let launchURLs = pendingURLs
        pendingURLs.removeAll()
        for url in launchURLs { model.account.handleIncomingURL(url) }
        if !model.isPreview { Task { await model.account.synchronizeLogin() } }
        if model.shortcutError != nil && !isElectron { openSettings() }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard model != nil else { pendingURLs.append(contentsOf: urls); return }
        for url in urls { model.account.handleIncomingURL(url) }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if model != nil && !model.isPreview { Task { await model.account.synchronizeLogin() } }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { electronBridge?.event("quit") }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openLibrary(); return true }
    @objc func openLibrary() {
        if electronBridge != nil && model.cleanupReview != nil { openSettings(); return }
        libraryWindow.orderOut(nil); openTabSearch()
    }
    @objc private func openTabSearch() {
        if let electronBridge { electronBridge.event("show"); return }
        if tabSearchPanel == nil {
            let panel = TabSearchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = model.isPreview ? "SaveNest Preview" : "SaveNest"; panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true; panel.isReleasedWhenClosed = false
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let content = NSHostingView(rootView: TabSearchView(app: model, model: model.tabSearch))
            content.sizingOptions = []
            panel.contentView = content
            panel.setContentSize(NSSize(width: 720, height: 650))
            panel.onDismiss = { [weak self] in self?.model.tabSearch.suspend() }
            panel.dismissOnResign = !model.isPreview
            panel.keyHandler = { [weak self] event in self?.model.workspaceKeyHandler?(event) ?? false }
            panel.center(); tabSearchPanel = panel
        }
        if tabSearchPanel?.isVisible == true {
            tabSearchPanel?.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .focusSearch, object: nil)
            return
        }
        model.tabSearch.query = ""; model.tabSearch.updateLibrary(model.library.links); model.tabSearch.refresh()
        // Take keyboard focus without raising Settings or switching Spaces.
        tabSearchPanel?.makeKeyAndOrderFront(nil)
    }
    @objc func openSettings() {
        model.section = .settings
        tabSearchPanel?.orderOut(nil); model.tabSearch.suspend()
        libraryWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func openAccount() {
        model.section = .account
        tabSearchPanel?.orderOut(nil); model.tabSearch.suspend()
        libraryWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if !model.isPreview { Task { await model.account.synchronizeLogin() } }
    }
    @objc private func captureTab() { model.capture(action: .quick) }
    @objc private func captureWindow() { model.capture(action: .window) }
    @objc private func captureSelected() { model.capture(action: .selected) }
    @objc private func captureNote() { model.capture(action: .note) }
    @objc private func closeDuplicateTabs() { model.closeDuplicateTabs() }
    @objc private func cleanUpTabs() { model.runTabCleanup() }
    @objc private func saveClipboard() { model.saveCurrentClipboard() }
    private func openCaptureEditor(_ draft: CaptureDraft) {
        if editorDraftID == draft.id, let captureEditor {
            captureEditor.makeKeyAndOrderFront(nil); return
        }
        let panel = CaptureEditorPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = draft.action.title; panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSHostingView(rootView: QuickCaptureView(model: model, draft: draft))
        panel.contentView = content; panel.setContentSize(content.fittingSize)
        panel.center(); captureEditor = panel; editorDraftID = draft.id
        // Match open-tab search: take keyboard focus without raising the library.
        panel.makeKeyAndOrderFront(nil)
    }
    private func closeCaptureEditor() {
        captureEditor?.orderOut(nil); captureEditor = nil; editorDraftID = nil
    }
    private func openTabSelection(_ draft: TabSelectionDraft) {
        if tabSelectionDraftID == draft.id, let tabSelectionPanel { tabSelectionPanel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let front = NSWorkspace.shared.frontmostApplication
        returnToApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Save selected tabs"; panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSHostingView(rootView: TabSelectionView(model: model, draftID: draft.id))
        panel.contentView = content; panel.setContentSize(content.fittingSize); panel.center()
        tabSelectionPanel = panel; tabSelectionDraftID = draft.id
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func closeTabSelection() {
        tabSelectionPanel?.orderOut(nil); tabSelectionPanel = nil; tabSelectionDraftID = nil
        if NSApp.isActive { returnToApp?.activate(options: []) }; returnToApp = nil
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window === captureEditor { model.cancelDraft() }
            if window === tabSelectionPanel { model.cancelTabSelection() }
        }
    }
    @objc private func addLink() {
        openLibrary()
        if let electronBridge { electronBridge.event("add") } else { model.presentAdd() }
    }
    @objc private func focusSearch() { openLibrary(); NotificationCenter.default.post(name: .focusSearch, object: nil) }
    @objc private func exportLibrary() { model.exportLibrary() }
    @objc private func importLibrary() { model.importLibrary() }
    @objc private func performUndo(_ sender: Any?) {
        if let manager = NSApp.keyWindow?.firstResponder?.undoManager, manager.canUndo {
            manager.undo()
        } else {
            model.undoLastAction()
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(performUndo(_:)) else { return true }
        return NSApp.keyWindow?.firstResponder?.undoManager?.canUndo == true || model.canUndoLastAction
    }
    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: key); result.target = self; return result
    }
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "SaveNest") { image.isTemplate = true; statusItem.button?.image = image }
        let menu = NSMenu()
        menu.addItem(item("Open SaveNest", #selector(openLibrary)))
        menu.addItem(item("Close duplicate tabs", #selector(closeDuplicateTabs)))
        menu.addItem(item("Clean up tabs…", #selector(cleanUpTabs)))
        menu.addItem(.separator())
        menu.addItem(item("Save current tab", #selector(captureTab)))
        menu.addItem(item("Save copied link", #selector(saveClipboard)))
        menu.addItem(item("Save with a note…", #selector(captureNote)))
        menu.addItem(item("Save selected tabs…", #selector(captureSelected)))
        menu.addItem(item("Save all tabs in this window", #selector(captureWindow)))
        menu.addItem(item("Add a link…", #selector(addLink)))
        menu.addItem(.separator()); menu.addItem(item("Account…", #selector(openAccount))); menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(model.updater.menuItem())
        menu.addItem(NSMenuItem(title: "Quit SaveNest", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
    private func setupMenus() {
        let main = NSMenu()
        let app = NSMenu(); app.addItem(item("Account…", #selector(openAccount))); app.addItem(item("Settings…", #selector(openSettings), key: ",")); app.addItem(.separator())
        app.addItem(model.updater.menuItem()); app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide SaveNest", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(NSMenuItem(title: "Quit SaveNest", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appRoot = NSMenuItem(); appRoot.submenu = app; main.addItem(appRoot)
        let file = NSMenu(title: "File")
        file.addItem(item("Search Tabs & Saved Links…", #selector(openTabSearch)))
        file.addItem(item("Close Duplicate Tabs", #selector(closeDuplicateTabs)))
        file.addItem(item("Clean Up Tabs…", #selector(cleanUpTabs)))
        file.addItem(item("Save Copied Link", #selector(saveClipboard)))
        file.addItem(item("Add Link…", #selector(addLink), key: "n")); file.addItem(item("Open SaveNest", #selector(openLibrary), key: "0"))
        file.addItem(.separator()); file.addItem(item("Save Current Browser Tab", #selector(captureTab))); file.addItem(item("Save with a Note…", #selector(captureNote))); file.addItem(item("Save Selected Tabs…", #selector(captureSelected))); file.addItem(item("Save Browser Window", #selector(captureWindow)))
        file.addItem(.separator()); file.addItem(item("Import Backup…", #selector(importLibrary))); file.addItem(item("Export Backup…", #selector(exportLibrary)))
        file.addItem(.separator()); file.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let fileRoot = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); fileRoot.submenu = file; main.addItem(fileRoot)
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", #selector(performUndo(_:)), key: "z"))
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key)) }
        edit.addItem(.separator()); edit.addItem(item("Find…", #selector(focusSearch), key: "f"))
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editRoot.submenu = edit; main.addItem(editRoot)
        NSApp.mainMenu = main
    }
    private func presentToast(_ notice: CaptureNotice) {
        toastDismiss?.cancel(); toastPanel?.orderOut(nil)
        let panel = CaptureNoticePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "SaveNest notification"
        panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSHostingView(rootView: CaptureNoticeView(notice: notice, dismiss: { [weak panel] in
            panel?.orderOut(nil)
        }, openSettings: { [weak panel] in
            panel?.orderOut(nil)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        }, openAccount: { [weak self, weak panel] in
            panel?.orderOut(nil); self?.openAccount()
        }, saveClipboard: { [weak self, weak panel] url, withNote in
            panel?.orderOut(nil); self?.model.saveClipboard(url, withNote: withNote)
        }))
        panel.contentView = content
        let size = content.fittingSize
        panel.setContentSize(size)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 24, y: frame.maxY - size.height - 20))
        }
        // Never activate SaveNest or make the panel key: typing stays in the browser.
        panel.orderFrontRegardless(); toastPanel = panel
        let dismiss = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }; toastDismiss = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + notice.duration, execute: dismiss)
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: "\(notice.title). \(notice.message)",
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }
}

private final class TabSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onDismiss: (() -> Void)?
    var dismissOnResign = true
    var keyHandler: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func resignKey() {
        super.resignKey()
        // Sheets take key focus. Keep their parent visible until editing finishes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dismissOnResign, !self.isKeyWindow, self.attachedSheet == nil,
                  !(self.childWindows ?? []).contains(where: { $0.isKeyWindow }) else { return }
            self.orderOut(nil); self.onDismiss?()
        }
    }
}

private final class CaptureEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

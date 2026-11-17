import AppKit
import SaveNestCore

/// Serves the “Add to SaveNest…” macOS Service. AppKit supplies the request
/// pasteboard, so the normal clipboard is never consulted or changed.
@MainActor
final class ServicesProvider: NSObject {
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    /// AppDelegate retains the returned provider for the process lifetime.
    @discardableResult
    static func register(_ model: AppModel) -> ServicesProvider {
        let provider = ServicesProvider(model: model)
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
        return provider
    }

    @objc(addToSaveNest:userData:error:)
    func addToSaveNest(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = Self.linkText(from: pasteboard), let url = ClipboardLink.parse(text) else {
            error.pointee = "Select one complete web address starting with http:// or https://, then choose Add to SaveNest again." as NSString
            return
        }
        if let message = model.beginServicesCapture(url) { error.pointee = message as NSString }
    }

    /// Accept URL and plain-text representations, but only a single complete link.
    static func linkText(from pasteboard: NSPasteboard) -> String? {
        guard let items = pasteboard.pasteboardItems, items.count == 1 else { return nil }
        return items[0].string(forType: .URL) ?? items[0].string(forType: .string)
    }
}

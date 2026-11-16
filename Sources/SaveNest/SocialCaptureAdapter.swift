import Foundation
import SaveNestCore
#if canImport(SaveNestProCapture)
import SaveNestProCapture
#endif

enum SocialCaptureBuild {
    static var capabilityMarker: String {
        #if canImport(SaveNestProCapture)
        "SaveNestSocialCaptureCapability-v1=enabled"
        #else
        "SaveNestSocialCaptureCapability-v1=disabled"
        #endif
    }
    static var isAvailable: Bool {
        #if canImport(SaveNestProCapture)
        true
        #else
        false
        #endif
    }
}

/// The private observer receives no account credentials or library writer.
/// Every bounded event is decoded and validated again by the public host.
final class SocialBrowserCaptureObserver {
    var onCapture: ((SaveNestCore.SocialSaveCapture) throws -> Void)?
    var onStatus: ((String) -> Void)?
    var onAuthorizationCheck: (() -> Bool)?
    var onClipboardActivity: ((Bool) -> Void)?
    var enabledPlatforms: Set<String> = [] {
        didSet {
            #if canImport(SaveNestProCapture)
            backend.enabledPlatforms = enabledPlatforms
            #endif
        }
    }
    #if canImport(SaveNestProCapture)
    private let backend = SaveNestProCapture.SocialBrowserCaptureObserver()
    #endif
    var isCapturing: Bool {
        #if canImport(SaveNestProCapture)
        backend.isCapturing
        #else
        false
        #endif
    }
    init() {
        #if canImport(SaveNestProCapture)
        backend.onAuthorizationCheck = { [weak self] in self?.onAuthorizationCheck?() == true }
        backend.onStatus = { [weak self] in self?.onStatus?($0) }
        backend.onClipboardActivity = { [weak self] in self?.onClipboardActivity?($0) }
        backend.onCapture = { [weak self] value in
            guard let handler = self?.onCapture else { throw SaveNestCore.SocialSaveCaptureError("Capture stopped.") }
            let payload = try JSONEncoder().encode(value)
            guard payload.count <= 100_000 else { throw SaveNestCore.SocialSaveCaptureError("Capture is too large.") }
            try handler(try JSONDecoder().decode(SaveNestCore.SocialSaveCapture.self, from: payload).validated())
        }
        #endif
    }
    func start() {
        #if canImport(SaveNestProCapture)
        backend.start()
        #endif
    }
    func stop() {
        #if canImport(SaveNestProCapture)
        backend.stop()
        #endif
    }
    func discardPending() {
        #if canImport(SaveNestProCapture)
        backend.discardPending()
        #endif
    }
}

final class SocialSlackCaptureObserver {
    var onCapture: ((SaveNestCore.SocialSaveCapture) throws -> Void)?
    var onStatus: ((String) -> Void)?
    var onAuthorizationCheck: (() -> Bool)?
    #if canImport(SaveNestProCapture)
    private let backend = SaveNestProCapture.SocialSlackCaptureObserver()
    #endif
    static func trusted(prompt: Bool = false) -> Bool {
        #if canImport(SaveNestProCapture)
        SaveNestProCapture.SocialSlackCaptureObserver.trusted(prompt: prompt)
        #else
        false
        #endif
    }
    init() {
        #if canImport(SaveNestProCapture)
        backend.onAuthorizationCheck = { [weak self] in self?.onAuthorizationCheck?() == true }
        backend.onStatus = { [weak self] in self?.onStatus?($0) }
        backend.onCapture = { [weak self] value in
            guard let handler = self?.onCapture else { throw SaveNestCore.SocialSaveCaptureError("Capture stopped.") }
            let payload = try JSONEncoder().encode(value)
            guard payload.count <= 100_000 else { throw SaveNestCore.SocialSaveCaptureError("Capture is too large.") }
            try handler(try JSONDecoder().decode(SaveNestCore.SocialSaveCapture.self, from: payload).validated())
        }
        #endif
    }
    func start() {
        #if canImport(SaveNestProCapture)
        backend.start()
        #endif
    }
    func stop() {
        #if canImport(SaveNestProCapture)
        backend.stop()
        #endif
    }
    func discardPending() {
        #if canImport(SaveNestProCapture)
        backend.discardPending()
        #endif
    }
}

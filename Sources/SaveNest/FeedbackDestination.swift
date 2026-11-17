import Foundation

enum FeedbackDestination: String, CaseIterable {
    case requestFeature
    case reportBug

    var title: String {
        switch self {
        case .requestFeature: "Request a feature"
        case .reportBug: "Report a bug"
        }
    }

    var url: URL {
        let template = self == .requestFeature ? "feature.yml" : "bug.yml"
        return URL(string: "https://github.com/dmytroomelian/savenest/issues/new?template=\(template)")!
    }
}

import Foundation
import SwiftUI

/// AIMeter's own text badges, not service logos or third-party artwork.
public enum ServiceIdentity: String, CaseIterable {
    case openai, gemini, claude, cursor, windsurf, copilot, grokbot
    case devin, perplexity, deepseek, poe, trae

    public init?(serviceID: String) {
        // Preset copies have IDs such as cursor_ab12. Do not classify custom
        // services by their editable names or by a partial string match.
        let base = serviceID.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? serviceID
        self.init(rawValue: base)
    }

    public var monogram: String {
        switch self {
        case .openai: return "OA"
        case .gemini: return "GE"
        case .claude: return "CL"
        case .cursor: return "CU"
        case .windsurf: return "WS"
        case .copilot: return "CP"
        case .grokbot: return "GR"
        case .devin: return "DV"
        case .perplexity: return "PX"
        case .deepseek: return "DS"
        case .poe: return "PO"
        case .trae: return "TR"
        }
    }
}

/// Keep the service's adjacent name as its accessible label. Unknown services
/// retain their saved SF Symbol, without changing preferences or shared JSON.
public struct ServiceIcon: View {
    public let serviceID: String
    public let fallbackSystemName: String
    public var size: CGFloat
    public var tint: Color

    public init(serviceID: String, fallbackSystemName: String, size: CGFloat = 18, tint: Color = .secondary) {
        self.serviceID = serviceID
        self.fallbackSystemName = fallbackSystemName
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        Group {
            if let identity = ServiceIdentity(serviceID: serviceID) {
                Text(identity.monogram)
                    .font(.system(size: size * 0.43, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: size, height: size)
                    .background {
                        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                            .fill(tint.opacity(0.08))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                            .strokeBorder(tint.opacity(0.28), lineWidth: 0.7)
                    }
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: size * 0.68, weight: .medium))
                    .frame(width: size, height: size)
            }
        }
        .foregroundStyle(tint)
        .accessibilityHidden(true)
    }
}

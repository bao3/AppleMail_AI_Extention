import Foundation

/// Google 1P Gemini models routed through Vertex AI `locations/global`.
public enum GeminiModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case flash38 = "gemini-3.8-flash"
    case carbon4 = "gemini-4-carbon"

    public static let vertexLocation = "global"
    public static let defaultModel: GeminiModel = .flash38

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .flash38:
            return "Gemini 3.8 Flash"
        case .carbon4:
            return "Gemini 4 Carbon"
        }
    }

    public var shortLabel: String {
        switch self {
        case .flash38:
            return "⚡ Flash 3.8"
        case .carbon4:
            return "🧠 Carbon 4"
        }
    }

    public var subtitle: String {
        switch self {
        case .flash38:
            return "快速响应 · 默认主力"
        case .carbon4:
            return "深度推理 · 复杂长信/商务核价"
        }
    }

    public func generateContentURL(projectID: String) -> URL {
        URL(string: "https://aiplatform.googleapis.com/v1beta1/projects/\(projectID)/locations/\(Self.vertexLocation)/publishers/google/models/\(rawValue):generateContent")!
    }

    public func countTokensURL(projectID: String) -> URL {
        URL(string: "https://aiplatform.googleapis.com/v1beta1/projects/\(projectID)/locations/\(Self.vertexLocation)/publishers/google/models/\(rawValue):countTokens")!
    }
}

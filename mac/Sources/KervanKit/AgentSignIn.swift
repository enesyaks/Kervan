import Foundation

/// The agents that come with every Kervan server, and how a pasted key turns into their sign-in.
/// The key is saved on the server as the agent's own environment (agent.save), never on the Mac.
public struct AgentSignIn: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// One line on what the agent is, for someone choosing.
    public let blurb: String
    public let keyName: String
    public let placeholder: String
    /// Where to create a key.
    public let keyURL: URL
    /// Another way in, for people with a subscription rather than an API account.
    public let alternative: String?

    public static let all: [AgentSignIn] = [
        AgentSignIn(
            id: "claude", name: "Claude Code", blurb: "Anthropic'in kodlama ajanı.",
            keyName: "ANTHROPIC_API_KEY", placeholder: "sk-ant-…",
            keyURL: URL(string: "https://console.anthropic.com/settings/keys")!,
            alternative: "Claude aboneliğiniz varsa Mac'te Terminal'de claude setup-token çalıştırıp çıkan jetonu da yapıştırabilirsiniz."
        ),
        AgentSignIn(
            id: "codex", name: "Codex", blurb: "OpenAI'ın kodlama ajanı.",
            keyName: "OPENAI_API_KEY", placeholder: "sk-…",
            keyURL: URL(string: "https://platform.openai.com/api-keys")!,
            alternative: nil
        ),
        AgentSignIn(
            id: "gemini", name: "Gemini", blurb: "Google'ın kodlama ajanı; ücretsiz kotası var.",
            keyName: "GEMINI_API_KEY", placeholder: "AIza…",
            keyURL: URL(string: "https://aistudio.google.com/apikey")!,
            alternative: nil
        ),
    ]

    public static func of(_ id: String) -> AgentSignIn? { all.first { $0.id == id } }

    /// The variable a pasted key goes into: a Claude subscription token is not an API key.
    public func variable(for key: String) -> String {
        id == "claude" && key.hasPrefix("sk-ant-oat") ? "CLAUDE_CODE_OAUTH_TOKEN" : keyName
    }

    /// The builtin adapter with the key, ready for agent.save; nil for an empty key.
    public func input(key: String) -> AgentInput? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        // Codex offers several sign-ins and waits until one is picked; Gemini likewise.
        let authMethod: String? = switch id {
        case "codex": "api-key"
        case "gemini": "gemini-api-key"
        default: nil
        }
        return AgentInput(id: id, name: name, command: "builtin", authMethod: authMethod, env: [variable(for: key): key])
    }
}

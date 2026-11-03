import Foundation

/// Making this Mac a node (docs/plans/mac-node.md): the commands for infra/mac-node-setup.sh, run through macOS's own
/// administrator prompt, so the app never sees the password.
public enum MacNode {
    public static let service = "/Library/LaunchDaemons/com.enes.kervan.node.plist"
    /// There while "keep this Mac awake" is on.
    public static let keepAwakeService = "/Library/LaunchDaemons/com.enes.kervan.node.awake.plist"
    /// Written by the setup script, readable by anyone: the node's key file isn't.
    public static let nameFile = "/opt/kervan-node/node-name"

    public static func isInstalled(fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> Bool {
        fileExists(service)
    }

    /// A node name from the Mac's host name: lowercase letters, digits and '-', up to 32 characters.
    public static func suggestedName(from hostName: String) -> String {
        let first = hostName.split(separator: ".").first.map(String.init) ?? ""
        let mapped = first.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        }
        let cleaned = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let short = String(cleaned.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return short.isEmpty || short == "local" ? "mac" : short
    }

    public static func isValidName(_ name: String) -> Bool {
        name != "local" && name.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil
    }

    /// `text` as one word for the shell.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The setup command, its output going to `log`, which the app follows: `do shell script` only answers at the end.
    public static func installCommand(script: String, hub: String, code: String, name: String, log: String) -> String {
        let arguments = ["/bin/bash", script, "install", "--hub", "http://\(hub)", "--code", code, "--name", name]
        return arguments.map(shellQuoted).joined(separator: " ") + " >> " + shellQuoted(log) + " 2>&1"
    }

    public static func removeCommand(script: String, log: String) -> String {
        ["/bin/bash", script, "remove"].map(shellQuoted).joined(separator: " ") + " >> " + shellQuoted(log) + " 2>&1"
    }

    public static func keepAwakeCommand(script: String, on: Bool, log: String) -> String {
        ["/bin/bash", script, "keep-awake", on ? "on" : "off"].map(shellQuoted).joined(separator: " ") + " >> " + shellQuoted(log) + " 2>&1"
    }

    /// The arguments for `osascript`, which shows the administrator prompt and runs `command` as root.
    public static func adminArguments(for command: String) -> [String] {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
    }

    /// Whether `osascript` failed because the user closed the administrator prompt.
    public static func wasCancelled(_ errorOutput: String) -> Bool {
        errorOutput.contains("-128") || errorOutput.localizedCaseInsensitiveContains("user canceled")
    }

    /// The setup's stages, in the order its "==>" lines arrive.
    public enum Step: Int, CaseIterable, Comparable, Sendable {
        case checking, folders, code, joining, service

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var marker: String {
            switch self {
            case .checking: "==> checking the hub"
            case .folders: "==> user and folders"
            case .code: "==> Kervan code"
            case .joining: "==> joining the hub"
            case .service: "==> service"
            }
        }

        public var title: String {
            switch self {
            case .checking: L("Reaching the server", "Sunucuya ulaşılıyor")
            case .folders: L("Making a separate user", "Ayrı kullanıcı oluşturuluyor")
            case .code: L("Installing Kervan", "Kervan kuruluyor")
            case .joining: L("Joining the server", "Sunucuya katılınıyor")
            case .service: L("Starting the service", "Servis başlatılıyor")
            }
        }

        public var detail: String {
            switch self {
            case .code: L("This is the long part: usually 1 to 3 minutes.", "En uzun bölüm bu: genelde 1-3 dakika sürer.")
            default: ""
            }
        }

        public static func reached(in output: String) -> Step {
            allCases.last { output.contains($0.marker) } ?? .checking
        }
    }
}

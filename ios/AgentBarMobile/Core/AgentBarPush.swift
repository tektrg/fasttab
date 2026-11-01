import Foundation

/// Notification contract with the dashboard's APNs sender
/// (dashboard/server/lib/apns_push.py docstring). Ids must match the server.
public enum AgentBarPush {
    public enum Category {
        public static let permission = "AGENT_PERMISSION"
        public static let message = "AGENT_MESSAGE"
    }

    public enum Action {
        public static let allow = "ALLOW"
        public static let deny = "DENY"
        public static let reply = "REPLY"
        public static let `continue` = "CONTINUE"
        public static let stop = "STOP"
    }

    /// A permission prompt waiting on the Mac.
    public struct PermissionPrompt: Equatable {
        public let requestId: String
        public let agent: String
        public let summary: String
        public let toolName: String

        public init(requestId: String, agent: String, summary: String, toolName: String) {
            self.requestId = requestId; self.agent = agent; self.summary = summary; self.toolName = toolName
        }
    }

    /// Parses an AGENT_PERMISSION userInfo; nil when requestId is missing.
    public static func permissionPrompt(from userInfo: [AnyHashable: Any]) -> PermissionPrompt? {
        guard let id = nonEmptyString(userInfo["requestId"]) else { return nil }
        return PermissionPrompt(requestId: id,
                                agent: nonEmptyString(userInfo["agent"]) ?? "",
                                summary: nonEmptyString(userInfo["summary"]) ?? "",
                                toolName: nonEmptyString(userInfo["toolName"]) ?? "")
    }

    /// requestId of a silent `{"withdrawn": requestId}` push, else nil.
    public static func withdrawnRequestId(from userInfo: [AnyHashable: Any]) -> String? {
        nonEmptyString(userInfo["withdrawn"])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }
}

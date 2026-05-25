import Foundation
import SwiftUI

enum AgentStatus: String, Codable, CaseIterable {
    case idle
    case working
    case waiting
    case paused
    case cancelled
    case failed
    case completed
}

enum EdgeKind: String, Codable {
    case handoff
    case message
}

struct SessionSummary: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var detail: String
    var createdAt: String? = nil
    var workspaceRoot: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case detail = "workflowId"
        case createdAt
        case workspaceRoot
    }
}

struct ToolPolicy: Hashable, Codable {
    var canRead: Bool
    var canWrite: Bool
    var canRunCommands: Bool
    var canCreatePlans: Bool?
}

struct RoleWorkspace: Hashable, Codable {
    var allowedRoots: [String]
}

struct RoleSpec: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var color: String
    var promptTemplate: String
    var model: String
    var toolPolicy: ToolPolicy
    var workspace: RoleWorkspace
    var expectedOutputs: [String]
    var reviewResponsibilities: [String]
}

struct WorkflowNodeSpec: Identifiable, Hashable, Codable {
    var id: String
    var roleId: String
    var label: String
    var startsActive: Bool?
}

struct WorkflowEdgeSpec: Identifiable, Hashable, Codable {
    var id: String
    var from: String
    var to: String
    var kind: EdgeKind
    var description: String
}

struct WorkflowSpec: Identifiable, Hashable, Codable {
    var version: Int
    var id: String
    var name: String
    var description: String
    var roles: [RoleSpec]
    var nodes: [WorkflowNodeSpec]
    var edges: [WorkflowEdgeSpec]
    var stopCriteria: [String]
}

struct AuthStatus: Hashable, Codable {
    var clientId: String
    var connected: Bool
    var hasTokens: Bool?
    var email: String?
    var expiresAt: String?
    var needsRefresh: Bool?
}

struct AgentNode: Identifiable, Hashable, Codable {
    let id: String
    var roleId: String
    var label: String
    var status: AgentStatus
    var colorHex: String
    var unreadCount: Int
    var errorCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case roleId
        case label
        case status
        case colorHex = "color"
        case unreadCount
        case errorCount
    }
}

struct AgentEdge: Identifiable, Hashable, Codable {
    let id: String
    var from: String
    var to: String
    var kind: EdgeKind
    var active: Bool
}

struct TranscriptItem: Identifiable, Hashable {
    let id: String
    var agentId: String?
    var sender: String
    var recipient: String?
    var type: String
    var text: String
    var timestamp: Date
    var payload: [String: JSONValue]
}

enum DebugLogLevel: String, Codable, CaseIterable {
    case debug
    case info
    case warn
    case error
}

struct DebugLogItem: Identifiable, Hashable, Codable {
    var logId: String
    var sessionId: String
    var timestamp: String
    var level: DebugLogLevel
    var source: String
    var agentId: String?
    var message: String
    var payload: [String: JSONValue]
    var causationId: String?
    var correlationId: String?

    var id: String { logId }
}

enum InspectorPanel: String, CaseIterable, Identifiable {
    case graph = "Graph"
    case debug = "Debug"

    var id: String { rawValue }
}

struct GraphState: Hashable, Codable {
    var sessionId: String
    var workflowId: String
    var nodes: [AgentNode]
    var edges: [AgentEdge]
}

struct SessionEvent: Identifiable, Hashable, Codable {
    var eventId: String
    var sessionId: String
    var agentId: String?
    var timestamp: String
    var type: String
    var payload: [String: JSONValue]
    var causationId: String?
    var correlationId: String?

    var id: String { eventId }
}

struct SessionSnapshot: Codable {
    var sessionId: String
    var title: String
    var createdAt: String
    var updatedAt: String
    var workspaceRoot: String
    var workflowId: String
    var debugMode: Bool?
    var graph: GraphState
    var transcript: [SessionEvent]
}

enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

extension Color {
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: trimmed)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

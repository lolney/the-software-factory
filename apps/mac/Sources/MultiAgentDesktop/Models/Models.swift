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

struct SessionSummary: Identifiable, Hashable {
    let id: String
    var title: String
    var detail: String
}

struct AgentNode: Identifiable, Hashable {
    let id: String
    var roleId: String
    var label: String
    var status: AgentStatus
    var colorHex: String
    var unreadCount: Int
    var errorCount: Int
}

struct AgentEdge: Identifiable, Hashable {
    let id: String
    var from: String
    var to: String
    var kind: EdgeKind
    var active: Bool
}

struct TranscriptItem: Identifiable, Hashable {
    let id: String
    var agentId: String?
    var type: String
    var text: String
    var timestamp: Date
}

struct GraphState: Hashable {
    var sessionId: String
    var workflowId: String
    var nodes: [AgentNode]
    var edges: [AgentEdge]
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

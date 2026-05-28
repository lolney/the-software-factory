import Foundation

enum GraphViewCommand: String {
    case zoomIn
    case zoomOut
    case reset
}

struct GraphViewCommandRequest: Equatable {
    var id = UUID()
    var command: GraphViewCommand
}

import Foundation
import SwiftUI

struct SoftwareFactoryViewCommands {
    var canShowDetails: Bool
    var focusTranscriptSearch: () -> Void
    var toggleDetails: () -> Void
    var showPanel: (InspectorPanel) -> Void
    var applyGraphCommand: (GraphViewCommand) -> Void
}

enum GraphViewCommand: String {
    case zoomIn
    case zoomOut
    case reset
}

struct GraphViewCommandRequest: Equatable {
    var id = UUID()
    var command: GraphViewCommand
}

private struct SoftwareFactoryViewCommandsKey: FocusedValueKey {
    typealias Value = SoftwareFactoryViewCommands
}

extension FocusedValues {
    var softwareFactoryViewCommands: SoftwareFactoryViewCommands? {
        get { self[SoftwareFactoryViewCommandsKey.self] }
        set { self[SoftwareFactoryViewCommandsKey.self] = newValue }
    }
}

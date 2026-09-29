import AppKit
import SwiftUI

@MainActor
final class ShortcutRecorderProbe: ObservableObject {
    @Published var recorded: RecordedShortcut?
    @Published var isRecording = true
}

struct ShortcutRecorderDiagnostic: View {
    @ObservedObject var probe: ShortcutRecorderProbe
    var body: some View {
        ShortcutRecorder(recorded: $probe.recorded, isRecording: $probe.isRecording, onFinished: {})
            .frame(width: 240, height: 44)
    }
}

import SwiftUI

struct ComposerView: View {
    @Bindable var store: SessionStore

    var body: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $store.composerText)
                    .font(.body)
                    .frame(minHeight: 56, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

                Button {
                    store.sendComposerMessage()
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}

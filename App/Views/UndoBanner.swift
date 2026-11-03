import SwiftUI

struct DeletedEntry: Equatable {
    var lines: [String]
    var line: Int
    var title: String
}

/// A short-lived banner offering to put back what was just deleted.
struct UndoBanner: View {
    @Binding var deleted: DeletedEntry?
    var restore: (DeletedEntry) -> Void

    var body: some View {
        if let entry = deleted {
            HStack {
                Text("Deleted “\(entry.title)”")
                    .font(.footnote)
                    .lineLimit(1)
                Spacer()
                Button("Undo") {
                    restore(entry)
                    withAnimation(.snappy) { deleted = nil }
                }
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: entry) {
                try? await Task.sleep(for: .seconds(6))
                withAnimation(.snappy) { deleted = nil }
            }
        }
    }
}

import SwiftUI

/// A reusable view for displaying a labeled piece of data.
struct InfoRowView<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundColor(.secondary)
            
            content
            
            Spacer()
        }
        .font(.caption2)
        .padding(.horizontal, 8)
    }
}
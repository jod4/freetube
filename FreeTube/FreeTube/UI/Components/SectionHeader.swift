import SwiftUI

/// Section title row. `init(title:)` takes a localizable key (literals get translated);
/// `init(verbatim:)` is for content strings from YouTube that must be shown as-is.
struct SectionHeader: View {
    private let title: Text
    private let trailing: AnyView?

    init(title: LocalizedStringKey, trailing: AnyView? = nil) {
        self.title = Text(title)
        self.trailing = trailing
    }

    init(verbatim: String, trailing: AnyView? = nil) {
        self.title = Text(verbatim: verbatim)
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            title
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }
}

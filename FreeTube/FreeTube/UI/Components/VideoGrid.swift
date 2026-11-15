import SwiftUI

// MARK: - Breakpoints

/// Column breakpoints for every video list in the app. Based on the width of the scroll
/// container (not the device), so Split View / Slide Over and rotation are handled too.
///
/// | Width (pt)  | Columns | Typical case                                         |
/// |-------------|---------|------------------------------------------------------|
/// | < 600       | 1       | iPhone portrait, iPad Split View ½ or narrower        |
/// | 600 – 999   | 2       | iPad portrait (810 pt on iPad 7), iPhone landscape   |
/// | ≥ 1000      | 3       | iPad landscape (1080 pt on iPad 7), 12.9" portrait   |
///
/// 3 is the cap: wider windows grow the cards instead of adding a 4th column.
enum VideoGridColumns {
    static func count(forWidth width: CGFloat) -> Int {
        switch width {
        case ..<600: return 1
        case ..<1000: return 2
        default: return 3
        }
    }
}

extension View {
    /// Writes the column count for this view's width into `columns`. Only fires when the
    /// count actually changes (the geometry is reduced to an `Int`), so rotation re-lays the
    /// grid once instead of re-rendering on every pixel of a resize.
    func readVideoGridColumns(into columns: Binding<Int>) -> some View {
        onGeometryChange(for: Int.self) { proxy in
            VideoGridColumns.count(forWidth: proxy.size.width)
        } action: { count in
            columns.wrappedValue = count
        }
    }
}

// MARK: - Grid

/// One titled block of videos inside a `VideoGrid` (e.g. a discovery category in Trending).
struct VideoGridSection: Identifiable {
    let id: String
    let title: String?
    let videos: [Video]
}

/// Responsive list of videos for use inside a `ScrollView`.
///
/// - **1 column:** the screen's original look — full-bleed `VideoCard`s, or compact
///   `VideoRow`s when `compactWhenSingleColumn` is set (search, channel, playlist lists).
/// - **2–3 columns:** always `VideoCard`s in the inset style (rounded thumbnail, card sits
///   inside the grid's side padding), like YouTube's iPad layout.
///
/// **Scroll performance — keep it to one lazy container.** All sections live in a single
/// `LazyVGrid` (with `Section` headers). Don't wrap a `VideoGrid` in a `LazyVStack` or put
/// one grid per section: nested lazy containers have to re-estimate the heights above the
/// viewport while scrolling *up*, and the resulting content-offset corrections make the
/// scroll stutter. Wrap it in a plain `VStack` instead; it stays lazy inside the
/// `ScrollView`. Cards also have a fixed height (16:9 thumbnail, title always reserving two
/// lines) so every grid row is the same height and the estimates are exact.
///
/// `onItemAppear` reports each item's index across *all* sections as it appears, for
/// pagination triggers (compare against `totalCount`).
@available(iOS 17.0, *)
struct VideoGrid: View {
    let sections: [VideoGridSection]
    let columns: Int
    var compactWhenSingleColumn: Bool = false
    var showsMoreMenu: Bool = false
    let onTap: (Video) -> Void
    var onItemAppear: ((Int) -> Void)?

    /// Single untitled section — the common case.
    init(
        videos: [Video],
        columns: Int,
        compactWhenSingleColumn: Bool = false,
        showsMoreMenu: Bool = false,
        onTap: @escaping (Video) -> Void,
        onItemAppear: ((Int) -> Void)? = nil
    ) {
        self.init(
            sections: [VideoGridSection(id: "all", title: nil, videos: videos)],
            columns: columns,
            compactWhenSingleColumn: compactWhenSingleColumn,
            showsMoreMenu: showsMoreMenu,
            onTap: onTap,
            onItemAppear: onItemAppear
        )
    }

    init(
        sections: [VideoGridSection],
        columns: Int,
        compactWhenSingleColumn: Bool = false,
        showsMoreMenu: Bool = false,
        onTap: @escaping (Video) -> Void,
        onItemAppear: ((Int) -> Void)? = nil
    ) {
        self.sections = sections
        self.columns = columns
        self.compactWhenSingleColumn = compactWhenSingleColumn
        self.showsMoreMenu = showsMoreMenu
        self.onTap = onTap
        self.onItemAppear = onItemAppear
    }

    /// Number of videos across all sections.
    static func totalCount(of sections: [VideoGridSection]) -> Int {
        sections.reduce(0) { $0 + $1.videos.count }
    }

    private var isMultiColumn: Bool { columns > 1 }

    private var isCompact: Bool { !isMultiColumn && compactWhenSingleColumn }

    /// Global index of each section's first video, so `onItemAppear` can report a flat index.
    private var sectionOffsets: [Int] {
        var offsets: [Int] = []
        var running = 0
        for section in sections {
            offsets.append(running)
            running += section.videos.count
        }
        return offsets
    }

    var body: some View {
        let offsets = sectionOffsets
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: max(columns, 1)),
            spacing: isMultiColumn ? 24 : (isCompact ? 12 : 16)
        ) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { sectionIndex, section in
                Section {
                    ForEach(Array(section.videos.enumerated()), id: \.element.id) { index, video in
                        item(video)
                            .onAppear { onItemAppear?(offsets[sectionIndex] + index) }
                    }
                } header: {
                    if let title = section.title {
                        SectionHeader(verbatim: title)
                            .padding(.horizontal, isMultiColumn || isCompact ? -16 : 0)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .padding(.horizontal, isMultiColumn || isCompact ? 16 : 0)
    }

    @ViewBuilder
    private func item(_ video: Video) -> some View {
        if isCompact {
            VideoRow(video: video, onTap: { onTap(video) }, showsMoreMenu: showsMoreMenu)
        } else {
            VideoCard(
                video: video,
                onTap: { onTap(video) },
                showsMoreMenu: showsMoreMenu,
                isInset: isMultiColumn
            )
        }
    }
}

import SwiftUI

/// Page for a feature that is planned but not built yet.
struct PlaceholderPage: View {
    let section: SidebarSection

    var body: some View {
        ContentUnavailableView(
            section.title,
            systemImage: section.symbol,
            description: Text(section.comingSoon)
        )
    }
}

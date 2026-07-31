import Foundation

/// How the record itself is drawn.
enum DiscStyle: String, CaseIterable, Identifiable {
    /// Black vinyl with the cover as a centre label.
    case classic
    /// The cover fills the whole disc, grooves cut over the top of it.
    case picture
    /// Clear pressing — the cover shows through a translucent disc.
    case glass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic: return "Classic Vinyl"
        case .picture: return "Picture Disc"
        case .glass: return "Clear Vinyl"
        }
    }
}

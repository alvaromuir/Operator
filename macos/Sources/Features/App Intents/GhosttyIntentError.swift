enum GhosttyIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appUnavailable
    case surfaceNotFound
    case permissionDenied
    case boardNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appUnavailable: "Operator isn't properly initialized."
        case .surfaceNotFound: "The terminal no longer exists."
        case .permissionDenied: "Operator doesn't allow Shortcuts."
        case .boardNotFound: "The board or sketch no longer exists."
        }
    }
}

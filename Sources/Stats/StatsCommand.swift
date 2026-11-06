// StatsCommand.swift
//
// alfresco://stats, the `/stats` workflow in workflows.json. While the
// launcher input runs it, the usage report shows under the input
// (StatsView); Enter opens the menu bar's "Usage…" summary of the last 30
// days, which can also reveal usage.json.

import Foundation

enum StatsCommand {
    static let feature = "stats"

    /// Whether `url` is alfresco://stats itself: the only action there is.
    static func isSummary(_ url: URL) -> Bool {
        InternalURL.action(of: url, feature: feature) == ""
    }
}

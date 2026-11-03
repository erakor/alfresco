// InternalURL.swift
//
// alfresco:// URLs from workflows.json run inside the app instead of being
// opened. The host names the feature (alfresco://pomodoro/...,
// alfresco://system/...) and the path its action. AppDelegate routes on
// `feature(of:)`; each feature's command parses `action(of:)`.

import Foundation

enum InternalURL {
    static let scheme = "alfresco"

    /// The feature an alfresco:// URL is for (its host, lowercased); nil
    /// for any other scheme.
    static func feature(of url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        return url.host?.lowercased()
    }

    /// The action of an alfresco://<feature>/<action> URL, lowercased and
    /// without slashes or spaces around it; nil when the URL isn't for
    /// `feature`.
    static func action(of url: URL, feature: String) -> String? {
        guard self.feature(of: url) == feature else { return nil }
        return url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespaces))
            .lowercased()
    }
}

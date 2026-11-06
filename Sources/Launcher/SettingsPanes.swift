// SettingsPanes.swift
//
// System Settings panes the launcher offers next to apps: typing `wifi`,
// `bluetooth` or `moniteurs` opens that pane through its
// x-apple.systempreferences: URL. The table names each pane in English and
// French; a pane is offered only when this macOS has it.

import Cocoa

/// One System Settings pane.
struct SettingsPane: Sendable {
    /// The pane's extension bundle ID, which is also what its URL names,
    /// e.g. "com.apple.wifi-settings-extension".
    let id: String
    let english: String
    let french: String
    /// Other words that find it ("wifi", "dark mode"), in either language.
    let aliases: [String]

    init(_ id: String, _ english: String, _ french: String, aliases: [String] = []) {
        self.id = id
        self.english = english
        self.french = french
        self.aliases = aliases
    }

    /// What opens it.
    var url: URL { URL(string: "\(SettingsPanes.scheme):\(id)")! }

    /// Folded (AppIndex.fold) names to match against: both titles and the aliases.
    var searchNames: [String] {
        Array(Set(([english, french] + aliases).map(AppIndex.fold)))
    }

    /// Its name in the user's first language: French when it is French,
    /// else English, as System Settings shows it.
    var title: String { SettingsPanes.prefersFrench ? french : english }
}

enum SettingsPanes {
    static let scheme = "x-apple.systempreferences"

    /// Pane IDs move between macOS versions, so each is checked against the
    /// panes this Mac has (`installed()`) and the self-test checks the table
    /// on the CI runner's macOS. macOS 12's System Preferences used other
    /// IDs and isn't covered.
    static let all: [SettingsPane] = [
        SettingsPane("com.apple.wifi-settings-extension", "Wi-Fi", "Wi-Fi", aliases: ["wifi"]),
        SettingsPane("com.apple.BluetoothSettings", "Bluetooth", "Bluetooth"),
        SettingsPane("com.apple.Network-Settings.extension", "Network", "Réseau", aliases: ["ethernet", "proxy"]),
        SettingsPane("com.apple.Notifications-Settings.extension", "Notifications", "Notifications"),
        SettingsPane("com.apple.Sound-Settings.extension", "Sound", "Son", aliases: ["audio", "volume"]),
        SettingsPane("com.apple.Focus-Settings.extension", "Focus", "Concentration", aliases: ["do not disturb", "ne pas déranger"]),
        SettingsPane("com.apple.Screen-Time-Settings.extension", "Screen Time", "Temps d’écran", aliases: ["temps d'ecran"]),
        SettingsPane("com.apple.Appearance-Settings.extension", "Appearance", "Apparence", aliases: ["dark mode", "mode sombre"]),
        SettingsPane("com.apple.Accessibility-Settings.extension", "Accessibility", "Accessibilité"),
        SettingsPane("com.apple.ControlCenter-Settings.extension", "Control Center", "Centre de contrôle", aliases: ["menu bar", "barre des menus"]),
        SettingsPane("com.apple.Siri-Settings.extension", "Siri", "Siri"),
        SettingsPane("com.apple.settings.PrivacySecurity.extension", "Privacy & Security", "Confidentialité et sécurité", aliases: ["privacy", "security", "permissions"]),
        SettingsPane("com.apple.Desktop-Settings.extension", "Desktop & Dock", "Bureau et Dock", aliases: ["dock", "mission control", "hot corners", "coins actifs"]),
        SettingsPane("com.apple.Displays-Settings.extension", "Displays", "Moniteurs", aliases: ["display", "écrans", "écran", "resolution", "résolution", "night shift"]),
        SettingsPane("com.apple.Wallpaper-Settings.extension", "Wallpaper", "Fond d’écran", aliases: ["fond d'ecran"]),
        SettingsPane("com.apple.ScreenSaver-Settings.extension", "Screen Saver", "Économiseur d’écran", aliases: ["economiseur d'ecran"]),
        SettingsPane("com.apple.Battery-Settings.extension", "Battery", "Batterie", aliases: ["energy", "énergie"]),
        SettingsPane("com.apple.Lock-Screen-Settings.extension", "Lock Screen", "Écran verrouillé"),
        SettingsPane("com.apple.Touch-ID-Settings.extension", "Touch ID & Password", "Touch ID et mot de passe"),
        SettingsPane("com.apple.Users-Groups-Settings.extension", "Users & Groups", "Utilisateurs et groupes", aliases: ["users", "utilisateurs"]),
        SettingsPane("com.apple.Internet-Accounts-Settings.extension", "Internet Accounts", "Comptes Internet"),
        SettingsPane("com.apple.Keyboard-Settings.extension", "Keyboard", "Clavier", aliases: ["shortcuts", "raccourcis"]),
        SettingsPane("com.apple.Mouse-Settings.extension", "Mouse", "Souris"),
        SettingsPane("com.apple.Trackpad-Settings.extension", "Trackpad", "Trackpad"),
        SettingsPane("com.apple.Print-Scanner-Settings.extension", "Printers & Scanners", "Imprimantes et scanners", aliases: ["printer", "imprimante"]),
        SettingsPane("com.apple.Software-Update-Settings.extension", "Software Update", "Mise à jour de logiciels", aliases: ["update", "mise à jour"]),
        SettingsPane("com.apple.settings.Storage", "Storage", "Stockage", aliases: ["disk space", "espace disque"]),
        SettingsPane("com.apple.AirDrop-Handoff-Settings.extension", "AirDrop & Handoff", "AirDrop et Handoff"),
        SettingsPane("com.apple.LoginItems-Settings.extension", "Login Items", "Ouverture", aliases: ["éléments de connexion"]),
        SettingsPane("com.apple.Localization-Settings.extension", "Language & Region", "Langue et région"),
        SettingsPane("com.apple.Date-Time-Settings.extension", "Date & Time", "Date et heure"),
        SettingsPane("com.apple.Sharing-Settings.extension", "Sharing", "Partage", aliases: ["screen sharing", "partage d'écran"]),
        SettingsPane("com.apple.Time-Machine-Settings.extension", "Time Machine", "Time Machine", aliases: ["backup", "sauvegarde"]),
    ]

    /// Where macOS 13+ keeps the panes, one .appex per pane.
    static let extensionsFolder = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true)

    /// The panes of the table this Mac has: those whose extension is in
    /// `folder`. None before macOS 13. Reads one Info.plist per extension,
    /// so it runs off the main thread with the app scan.
    static func installed(in folder: URL = extensionsFolder) -> [SettingsPane] {
        guard #available(macOS 13, *) else { return [] }
        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval("panes.scan", id: signposter.makeSignpostID())
        let ids = installedIDs(in: folder)
        let panes = all.filter { ids.contains($0.id) }
        signposter.endInterval(
            "panes.scan", signpost,
            "extensions=\(ids.count, privacy: .public) panes=\(panes.count, privacy: .public)"
        )
        return panes
    }

    /// The bundle IDs of the extensions in `folder`.
    static func installedIDs(in folder: URL = extensionsFolder) -> Set<String> {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return Set(items.filter { $0.pathExtension == "appex" }.compactMap { Bundle(url: $0)?.bundleIdentifier })
    }

    /// System Settings itself, for the row icon and the subtitle.
    @MainActor static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences")
    }

    /// "System Settings", or the name Finder shows ("Réglages Système").
    @MainActor static var appName: String {
        guard let path = appURL?.path else { return "System Settings" }
        let name = FileManager.default.displayName(atPath: path)
        return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// System Settings' icon (a gear without it), kept in `cache` under the
    /// app's path like an app row's.
    @MainActor static func icon(cache: inout [String: NSImage]) -> NSImage? {
        guard let path = appURL?.path else {
            return NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        }
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }

    static var prefersFrench: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("fr") == true
    }
}

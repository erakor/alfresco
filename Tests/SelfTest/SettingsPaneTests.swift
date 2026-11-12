// SettingsPaneTests.swift
//
// System Settings panes as launcher results: the table (unique IDs and
// names, every pane present on this macOS, a handler for the URL scheme) and
// how panes rank against apps.

import Cocoa

@MainActor
enum SettingsPaneTests {
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        SelfTest.check("settings panes: \(name)", condition, detail())
    }

    static func run() {
        checkTable()
        checkInstalled()
        checkRanking()
    }

    private static func checkTable() {
        let panes = SettingsPanes.all
        check("the table has panes", panes.count >= 20, "\(panes.count)")
        let ids = panes.map(\.id)
        check("pane IDs are unique", Set(ids).count == ids.count)

        var owners: [String: String] = [:]
        var shared: [String] = []
        for pane in panes {
            for name in pane.searchNames {
                if let owner = owners[name], owner != pane.id { shared.append(name) }
                owners[name] = pane.id
            }
        }
        check("no name finds two panes", shared.isEmpty, shared.joined(separator: ", "))
        check("every pane has an English and a French name",
              panes.allSatisfy { !$0.english.isEmpty && !$0.french.isEmpty })
        check("every URL is x-apple.systempreferences:<id>",
              panes.allSatisfy { $0.url.scheme == SettingsPanes.scheme && $0.url.absoluteString.hasSuffix($0.id) })
    }

    /// Pane IDs move between macOS versions: this fails on a macOS whose
    /// System Settings dropped or renamed one, naming it, so the table gets
    /// fixed. The app itself just leaves such a pane out.
    private static func checkInstalled() {
        guard #available(macOS 13, *) else {
            check("no panes before macOS 13", SettingsPanes.installed().isEmpty)
            return
        }
        let installedIDs = SettingsPanes.installedIDs()
        check("System Settings' extensions are found", installedIDs.count > 20, "\(installedIDs.count)")
        let missing = SettingsPanes.all.filter { !installedIDs.contains($0.id) }.map { "\($0.english) (\($0.id))" }
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        check("every pane in the table is on this macOS (\(version))", missing.isEmpty,
              "missing: " + missing.joined(separator: ", "))
        check("installed() keeps the panes this Mac has",
              SettingsPanes.installed().count == SettingsPanes.all.count - missing.count)
        let empty = SelfTest.scratchFile("no-extensions").deletingLastPathComponent()
        check("a folder without extensions gives no panes", SettingsPanes.installed(in: empty).isEmpty)
        let handler = SettingsPanes.all.first.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0.url) }
        check("System Settings opens the pane URLs", handler != nil, String(describing: handler))
    }

    private static func checkRanking() {
        func app(_ name: String, _ bundleID: String? = nil) -> AppEntry {
            AppEntry(
                url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name,
                searchNames: [AppIndex.fold(name)], bundleID: bundleID
            )
        }
        let apps = [
            app("Bluetooth File Exchange"), app("Safari", "com.apple.Safari"),
            app("Sound Studio", "x.sound"), app("Super Tracker", "x.tracker"),
        ]
        let panes = SettingsPanes.all
        func top(_ input: String, openCounts: [String: Int] = [:], picks: [String: Double] = [:]) -> String {
            let (best, _) = AppIndex.rankedResults(
                apps, panes: panes, for: AppIndex.normalize(input), limit: 9, openCounts: openCounts, picks: picks
            )
            switch best.first {
            case .app(let app)?: return "app \(app.name)"
            case .settingsPane(let pane)?: return "pane \(pane.english)"
            default: return "nothing"
            }
        }

        check("bluetooth: the pane, an exact name, before the app it starts",
              top("bluetooth") == "pane Bluetooth", top("bluetooth"))
        check("wifi finds Wi-Fi", top("wifi") == "pane Wi-Fi", top("wifi"))
        check("wi-fi finds Wi-Fi", top("wi-fi") == "pane Wi-Fi", top("wi-fi"))
        check("display finds Displays", top("display") == "pane Displays", top("display"))
        check("French names, without accents (reseau)", top("reseau") == "pane Network", top("reseau"))
        check("French names (moniteurs)", top("moniteurs") == "pane Displays", top("moniteurs"))
        check("an alias (écrans)", top("écrans") == "pane Displays", top("écrans"))
        check("a word of the name (dock)", top("dock") == "pane Desktop & Dock", top("dock"))
        check("an app keeps its exact name", top("safari") == "app Safari", top("safari"))
        check("an exact pane name beats an app it starts (sound)", top("sound") == "pane Sound", top("sound"))
        check("an app comes before a pane matched the same way (sou)",
              top("sou") == "app Sound Studio", top("sou"))
        check("a closer pane name beats an app's word (trac)", top("trac") == "pane Trackpad", top("trac"))
        let used = top("trac", openCounts: ["x.tracker": 1000])
        check("a much-used app moves up past a pane", used == "app Super Tracker", used)
        let picked = top("trac", picks: ["x.tracker": 1])
        check("an app picked for the input comes before a pane", picked == "app Super Tracker", picked)
        let pickedExact = top("sound", picks: ["x.sound": 8])
        check("an exact pane name still beats a picked app", pickedExact == "pane Sound", pickedExact)
        check("nothing matches zzq", top("zzq") == "nothing", top("zzq"))
        check("ranked leaves panes out", AppIndex.ranked(apps, for: "bluetooth", limit: 9).map(\.name)
              == ["Bluetooth File Exchange"])

        let (limited, matched) = AppIndex.rankedResults(apps, panes: panes, for: "s", limit: 3)
        check("the limit counts apps and panes together", limited.count == 3 && matched > 3,
              "\(limited.count) of \(matched)")

        let wifi = LauncherItem.settingsPane(panes[0])
        check("Tab completes a pane's name", wifi.completion == panes[0].title)
        check("the same pane is the same row", wifi.isSame(as: .settingsPane(panes[0])))
        check("two panes are different rows", !wifi.isSame(as: .settingsPane(panes[1])))
    }
}

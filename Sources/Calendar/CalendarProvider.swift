// CalendarProvider.swift
//
// Main-actor side of the calendar area: answers a CalendarQuery (the
// launcher builds it from the `cal` workflow's input) with the events macOS
// Calendar knows about (Google accounts added in System Settings > Internet
// Accounts included), read through EventKit off the main thread. Needs the
// Calendars permission, so it only works in build/Launcher.app, whose
// Info.plist carries the usage description.

import Cocoa
import EventKit

/// A calendar's color as sRGB components, so events can cross threads.
struct CalendarColor: Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init?(_ color: NSColor?) {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
        red = Double(rgb.redComponent)
        green = Double(rgb.greenComponent)
        blue = Double(rgb.blueComponent)
    }
}

/// One event, copied out of EventKit so the view needs no EKEvent.
struct CalendarEvent: Sendable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarColor: CalendarColor?
    let calendarName: String
    let location: String?
    /// Folded title and location, matched by `cal <text>`.
    let searchText: String

    var color: NSColor {
        guard let calendarColor else { return .controlAccentColor }
        return NSColor(srgbRed: calendarColor.red, green: calendarColor.green, blue: calendarColor.blue, alpha: 1)
    }
}

enum CalendarQuery: Equatable {
    /// `cal`: what is left of today and the next days (Config.calendarDays).
    case upcoming
    /// `cal <text>`: upcoming events whose title or location contains the
    /// folded text, over Config.calendarSearchDays.
    case search(String)
}

enum CalendarState {
    /// Waiting for the permission prompt, or for the first fetch.
    case loading(String)
    /// No access, no calendar, or not running as an app bundle.
    case message(String)
    /// Every upcoming event for `.upcoming` (the view picks what fits), at
    /// most Config.calendarMaxEvents for `.search`; `hiddenCount` more matched.
    case loaded([CalendarEvent], hiddenCount: Int)
}

/// EKEventStore is not marked Sendable, but Apple documents fetching events
/// off the main thread; CalendarProvider runs one fetch at a time.
private final class EventStoreBox: @unchecked Sendable {
    let store: EKEventStore
    init(_ store: EKEventStore) { self.store = store }
}

/// Calendars exist but the Config filters left none of them.
private struct FilteredOut: Sendable {
    /// The settings that removed at least one calendar.
    let settings: [String]
    /// Account names as Internet Accounts shows them, to fix calendarAccounts.
    let accounts: [String]
}

private struct FetchResult: Sendable {
    let events: [CalendarEvent]
    let hasCalendars: Bool
    let filteredOut: FilteredOut?
}

@MainActor
final class CalendarProvider {
    /// Called when new events arrive or the calendars change.
    var onUpdate: (@MainActor () -> Void)?
    /// Called once the permission prompt is answered, with whether access
    /// was granted (the launcher closes behind it, so it may open again).
    var onAccessAnswered: (@MainActor (Bool) -> Void)?

    private var store: EKEventStore?
    private var storeObserver: NSObjectProtocol?
    /// Every included event from the start of today over `fetchedDays`,
    /// from the last fetch; still shown while a newer one runs.
    private var events: [CalendarEvent] = []
    private var fetchedAt: Date?
    /// 0 until a fetch finishes.
    private var fetchedDays = 0
    private var hasCalendars = true
    private var filteredOut: FilteredOut?
    private var fetchTask: Task<Void, Never>?
    /// Bumped when the calendars change, so a fetch started before is not
    /// taken as fresh.
    private var generation = 0
    private var isRequestingAccess = false

    private enum Access {
        case granted, notDetermined, denied
    }

    /// TCC ends a process that asks for calendar access without a usage
    /// description, so the feature stays off without one (the plain binary).
    private static var isAvailable: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let key: String
        if #available(macOS 14.0, *) {
            key = "NSCalendarsFullAccessUsageDescription"
        } else {
            key = "NSCalendarsUsageDescription"
        }
        return Bundle.main.object(forInfoDictionaryKey: key) != nil
    }

    /// Whether the permission prompt is up.
    var isAwaitingAccess: Bool { isRequestingAccess }

    /// Days of events a query needs: `.search` also covers `.upcoming`, so
    /// going back to `cal` after a search reuses the events.
    private static func days(for query: CalendarQuery) -> Int {
        switch query {
        case .upcoming: return Config.calendarDays
        case .search: return max(Config.calendarDays, Config.calendarSearchDays)
        }
    }

    /// What to show for `query` right now. Asks for access the first time,
    /// and starts a fetch when the events are missing or stale (showing the
    /// stale ones meanwhile); the result comes back through onUpdate.
    func state(for query: CalendarQuery) -> CalendarState {
        guard Self.isAvailable else {
            return .message("L'agenda ne fonctionne que dans Launcher.app (./build.sh)")
        }
        switch Self.access() {
        case .notDetermined:
            requestAccess()
            return .loading("Accès à l'agenda…")
        case .denied:
            return .message("Accès refusé : Réglages Système › Confidentialité et sécurité › Calendriers")
        case .granted:
            break
        }

        let needed = Self.days(for: query)
        if !isFresh || fetchedDays < needed { startFetch(days: needed) }
        guard fetchedDays >= needed else {
            return .loading(fetchedDays == 0 ? "Lecture de l'agenda…" : "Recherche dans l'agenda…")
        }
        guard hasCalendars else {
            return .message("Aucun calendrier : ajoutez votre compte Google dans Réglages Système › Comptes Internet")
        }
        if let filteredOut {
            var text = "Tous les calendriers sont écartés par \(filteredOut.settings.joined(separator: ", "))"
            if filteredOut.settings.contains("calendarAccounts"), !filteredOut.accounts.isEmpty {
                text += " (comptes : \(filteredOut.accounts.joined(separator: ", ")))"
            }
            return .message(text)
        }
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let matching: [CalendarEvent]
        switch query {
        case .upcoming:
            let limit = Calendar.current.date(byAdding: .day, value: Config.calendarDays, to: today) ?? now
            matching = events.filter { $0.end > now && $0.start < limit }
        case .search(let text):
            let limit = Calendar.current.date(byAdding: .day, value: Config.calendarSearchDays, to: today) ?? now
            matching = events.filter { $0.end > now && $0.start < limit && $0.searchText.contains(text) }
        }
        let shown = query == .upcoming ? matching : Array(matching.prefix(Config.calendarMaxEvents))
        return .loaded(shown, hiddenCount: matching.count - shown.count)
    }

    // MARK: Events

    private var isFresh: Bool {
        guard let fetchedAt else { return false }
        return Date().timeIntervalSince(fetchedAt) < Config.calendarCacheLifetime
    }

    /// Reads `days` of events in a detached task (recurring events are
    /// expanded there, which can take a while), one fetch at a time. A wider
    /// one asked for meanwhile starts on the redraw that follows.
    private func startFetch(days: Int) {
        guard fetchTask == nil else { return }
        let box = EventStoreBox(eventStore())
        let startedGeneration = generation
        fetchTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Self.fetch(from: box, days: days) }.value
            guard let self else { return }
            self.fetchTask = nil
            self.events = result.events
            self.hasCalendars = result.hasCalendars
            self.filteredOut = result.filteredOut
            self.fetchedDays = days
            // A change during the fetch leaves it stale: the next state()
            // fetches again.
            self.fetchedAt = startedGeneration == self.generation ? Date() : nil
            self.onUpdate?()
        }
    }

    nonisolated private static func fetch(from box: EventStoreBox, days: Int) -> FetchResult {
        let store = box.store
        let allCalendars = store.calendars(for: .event)
        guard !allCalendars.isEmpty else {
            return FetchResult(events: [], hasCalendars: false, filteredOut: nil)
        }
        let reasons = allCalendars.map { exclusion(of: $0) }
        let calendars = zip(allCalendars, reasons).filter { $0.1 == nil }.map { $0.0 }
        // An empty list would mean every calendar to EventKit.
        guard !calendars.isEmpty else {
            let settings = Set(reasons.compactMap { $0 }).sorted()
            let accounts = Set(allCalendars.compactMap { $0.source?.title }).sorted()
            return FetchResult(
                events: [], hasCalendars: true, filteredOut: FilteredOut(settings: settings, accounts: accounts)
            )
        }
        let today = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: today) else {
            return FetchResult(events: [], hasCalendars: true, filteredOut: nil)
        }
        let predicate = store.predicateForEvents(withStart: today, end: end, calendars: calendars)
        let events = store.events(matching: predicate)
            .compactMap { makeEvent($0) }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.title < rhs.title
            }
        return FetchResult(events: events, hasCalendars: true, filteredOut: nil)
    }

    /// The Config setting that leaves `calendar` out, or nil to list it.
    nonisolated private static func exclusion(of calendar: EKCalendar) -> String? {
        if Config.calendarHidesBirthdays, calendar.type == .birthday { return "calendarHidesBirthdays" }
        let title = calendar.title
        if Config.calendarExcluded.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
            return "calendarExcluded"
        }
        guard !Config.calendarAccounts.isEmpty else { return nil }
        let account = calendar.source?.title ?? ""
        let listed = Config.calendarAccounts.contains { $0.caseInsensitiveCompare(account) == .orderedSame }
        return listed ? nil : "calendarAccounts"
    }

    nonisolated private static func makeEvent(_ event: EKEvent) -> CalendarEvent? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        if Config.calendarHidesDeclined,
           event.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) == true {
            return nil
        }
        let rawTitle = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.isEmpty ? "(Sans titre)" : rawTitle
        let rawLocation = (event.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let location = rawLocation.isEmpty ? nil : rawLocation
        return CalendarEvent(
            title: title,
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            calendarColor: CalendarColor(event.calendar?.color),
            calendarName: event.calendar?.title ?? "",
            location: location,
            searchText: AppIndex.fold([title, location ?? ""].joined(separator: " "))
        )
    }

    /// Marks the events stale; the ones in hand stay on screen until the
    /// next fetch replaces them.
    private func invalidate() {
        fetchedAt = nil
        generation += 1
    }

    // MARK: Store and access

    private func eventStore() -> EKEventStore {
        if let store { return store }
        let store = EKEventStore()
        self.store = store
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.storeDidChange() }
        }
        return store
    }

    private func storeDidChange() {
        invalidate()
        onUpdate?()
    }

    private static func access() -> Access {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted, .denied: return .denied
        default: break
        }
        if #available(macOS 14.0, *) {
            // Write-only access can't read events.
            return status == .fullAccess ? .granted : .denied
        }
        return .granted
    }

    /// Shows the system prompt once; the answer comes back through
    /// onAccessAnswered.
    private func requestAccess() {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        Self.askForAccess(eventStore()) { granted in
            Task { @MainActor in self.accessAnswered(granted: granted) }
        }
    }

    private func accessAnswered(granted: Bool) {
        isRequestingAccess = false
        // A store made before access was granted can stay empty: start over.
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
        store = nil
        invalidate()
        onAccessAnswered?(granted)
    }

    /// Kept out of main-actor code: the completion handler runs on a
    /// background queue.
    nonisolated private static func askForAccess(_ store: EKEventStore, then done: @escaping @Sendable (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, error in
                if let error { NSLog("Launcher: calendar access failed: \(error)") }
                done(granted)
            }
        } else {
            store.requestAccess(to: .event) { granted, error in
                if let error { NSLog("Launcher: calendar access failed: \(error)") }
                done(granted)
            }
        }
    }
}

// CalendarProvider.swift
//
// Main-actor side of the calendar area: turns launcher input into a
// CalendarQuery and reads the events macOS Calendar knows about (Google
// accounts added in System Settings > Internet Accounts included) through
// EventKit, off the main thread. Needs the Calendars permission, so it only
// works in build/Launcher.app, whose Info.plist carries the usage description.

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

private struct FetchResult: Sendable {
    let events: [CalendarEvent]
    let hasCalendars: Bool
    /// The account names when calendars exist but the Config filters left
    /// none of them; nil otherwise.
    let filteredOutAccounts: [String]?
}

@MainActor
final class CalendarProvider {
    /// Called when new events arrive or the calendars change.
    var onUpdate: (@MainActor () -> Void)?
    /// Called once the permission prompt is answered (the launcher closes
    /// behind it, so it may need to open again).
    var onAccessAnswered: (@MainActor () -> Void)?

    private var store: EKEventStore?
    private var storeObserver: NSObjectProtocol?
    /// Every included event from the start of today over the longest window,
    /// from the last fetch; still shown while a newer one runs.
    private var events: [CalendarEvent] = []
    private var fetchedAt: Date?
    private var hasFetched = false
    private var hasCalendars = true
    private var filteredOutAccounts: [String]?
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

    /// `cal` → `.upcoming`, `cal <text>` → `.search`, nil for anything else.
    /// The launcher also checks that a workflow takes the input.
    func query(for input: String) -> CalendarQuery? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let keyword = parts.first, keyword.lowercased() == Config.calendarKeyword else { return nil }
        if parts.count == 2 {
            let text = AppIndex.fold(parts[1].trimmingCharacters(in: .whitespaces))
            if !text.isEmpty { return .search(text) }
        }
        return .upcoming
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

        if !isFresh { startFetch() }
        guard hasFetched else { return .loading("Lecture de l'agenda…") }
        guard hasCalendars else {
            return .message("Aucun calendrier : ajoutez votre compte Google dans Réglages Système › Comptes Internet")
        }
        if let accounts = filteredOutAccounts {
            let names = accounts.isEmpty ? "" : " (comptes : \(accounts.joined(separator: ", ")))"
            return .message("Aucun calendrier ne correspond à calendarAccounts / calendarExcluded\(names)")
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

    /// Reads the events in a detached task (recurring events are expanded
    /// there, which can take a while), one fetch at a time.
    private func startFetch() {
        guard fetchTask == nil else { return }
        let box = EventStoreBox(eventStore())
        let startedGeneration = generation
        fetchTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Self.fetch(from: box) }.value
            guard let self else { return }
            self.fetchTask = nil
            self.events = result.events
            self.hasCalendars = result.hasCalendars
            self.filteredOutAccounts = result.filteredOutAccounts
            self.hasFetched = true
            // A change during the fetch leaves it stale: the next state()
            // fetches again.
            self.fetchedAt = startedGeneration == self.generation ? Date() : nil
            self.onUpdate?()
        }
    }

    nonisolated private static func fetch(from box: EventStoreBox) -> FetchResult {
        let store = box.store
        let allCalendars = store.calendars(for: .event)
        let calendars = allCalendars.filter { isIncluded($0) }
        let today = Calendar.current.startOfDay(for: Date())
        let days = max(Config.calendarDays, Config.calendarSearchDays)
        // An empty list would mean every calendar to EventKit.
        guard !allCalendars.isEmpty else {
            return FetchResult(events: [], hasCalendars: false, filteredOutAccounts: nil)
        }
        guard !calendars.isEmpty else {
            // Named as Internet Accounts shows them, to fix calendarAccounts.
            let accounts = Set(allCalendars.compactMap { $0.source?.title }).sorted()
            return FetchResult(events: [], hasCalendars: true, filteredOutAccounts: accounts)
        }
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: today) else {
            return FetchResult(events: [], hasCalendars: true, filteredOutAccounts: nil)
        }
        let predicate = store.predicateForEvents(withStart: today, end: end, calendars: calendars)
        let events = store.events(matching: predicate)
            .compactMap { makeEvent($0) }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.title < rhs.title
            }
        return FetchResult(events: events, hasCalendars: true, filteredOutAccounts: nil)
    }

    nonisolated private static func isIncluded(_ calendar: EKCalendar) -> Bool {
        if Config.calendarHidesBirthdays, calendar.type == .birthday { return false }
        let title = calendar.title
        if Config.calendarExcluded.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
            return false
        }
        guard !Config.calendarAccounts.isEmpty else { return true }
        let account = calendar.source?.title ?? ""
        return Config.calendarAccounts.contains { $0.caseInsensitiveCompare(account) == .orderedSame }
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
        Self.askForAccess(eventStore()) { _ in
            Task { @MainActor in self.accessAnswered() }
        }
    }

    private func accessAnswered() {
        isRequestingAccess = false
        // A store made before access was granted can stay empty: start over.
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
        store = nil
        invalidate()
        onAccessAnswered?()
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

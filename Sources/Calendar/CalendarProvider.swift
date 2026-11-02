// CalendarProvider.swift
//
// Main-actor side of the calendar list: turns launcher input into a
// CalendarQuery and reads the events macOS Calendar knows about (Google
// accounts added in System Settings > Internet Accounts included) through
// EventKit. Needs the Calendars permission, so it only works in
// build/Launcher.app, whose Info.plist carries the usage description.

import Cocoa
import EventKit

/// One event, copied out of EventKit so the view needs no EKEvent.
struct CalendarEvent {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: NSColor
    let calendarName: String
    let location: String?
    /// Folded title and location, matched by `cal <text>`.
    let searchText: String
}

enum CalendarQuery: Equatable {
    /// `cal`: what is left of today and the next days (Config.calendarDays).
    case upcoming
    /// `cal <text>`: upcoming events whose title or location contains the
    /// folded text, over Config.calendarSearchDays.
    case search(String)
}

enum CalendarState {
    /// Waiting for the answer to the permission prompt.
    case loading
    /// No access, no calendar, or not running as an app bundle.
    case message(String)
    /// Every upcoming event for `.upcoming` (the view picks what fits), at
    /// most Config.calendarMaxEvents for `.search`; `hiddenCount` more matched.
    case loaded([CalendarEvent], hiddenCount: Int)
}

@MainActor
final class CalendarProvider {
    /// Called when access is answered or the calendars change.
    var onUpdate: (@MainActor () -> Void)?

    private var store: EKEventStore?
    private var storeObserver: NSObjectProtocol?
    /// Every included event from the start of today over the longest window.
    private var events: [CalendarEvent] = []
    private var fetchedAt: Date?
    private var hasCalendars = true
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

    /// What to show for `query` right now. Asks for access the first time.
    func state(for query: CalendarQuery) -> CalendarState {
        guard Self.isAvailable else {
            return .message("L'agenda ne fonctionne que dans Launcher.app (./build.sh)")
        }
        switch Self.access() {
        case .notDetermined:
            requestAccess()
            return .loading
        case .denied:
            return .message("Accès refusé : Réglages Système › Confidentialité et sécurité › Calendriers")
        case .granted:
            break
        }

        let all = currentEvents()
        guard hasCalendars else {
            return .message("Aucun calendrier : ajoutez votre compte Google dans Réglages Système › Comptes Internet")
        }
        let now = Date()
        let matching: [CalendarEvent]
        switch query {
        case .upcoming:
            let today = Calendar.current.startOfDay(for: now)
            let limit = Calendar.current.date(byAdding: .day, value: Config.calendarDays, to: today) ?? now
            matching = all.filter { $0.end > now && $0.start < limit }
        case .search(let text):
            matching = all.filter { $0.end > now && $0.searchText.contains(text) }
        }
        let shown = query == .upcoming ? matching : Array(matching.prefix(Config.calendarMaxEvents))
        return .loaded(shown, hiddenCount: matching.count - shown.count)
    }

    // MARK: Events

    /// The cached events, fetched again after Config.calendarCacheLifetime
    /// or once the calendars change.
    private func currentEvents() -> [CalendarEvent] {
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < Config.calendarCacheLifetime {
            return events
        }
        let store = eventStore()
        let allCalendars = store.calendars(for: .event)
        hasCalendars = !allCalendars.isEmpty
        let calendars = allCalendars.filter { Self.isIncluded($0) }

        var fetched: [CalendarEvent] = []
        let today = Calendar.current.startOfDay(for: Date())
        let days = max(Config.calendarDays, Config.calendarSearchDays)
        // An empty list would mean every calendar to EventKit.
        if !calendars.isEmpty, let end = Calendar.current.date(byAdding: .day, value: days, to: today) {
            let predicate = store.predicateForEvents(withStart: today, end: end, calendars: calendars)
            fetched = store.events(matching: predicate)
                .compactMap { Self.makeEvent($0) }
                .sorted { lhs, rhs in
                    if lhs.start != rhs.start { return lhs.start < rhs.start }
                    if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                    return lhs.title < rhs.title
                }
        }
        events = fetched
        fetchedAt = Date()
        return fetched
    }

    private func invalidate() {
        fetchedAt = nil
        events = []
    }

    private static func isIncluded(_ calendar: EKCalendar) -> Bool {
        if Config.calendarHidesBirthdays, calendar.type == .birthday { return false }
        let title = calendar.title
        if Config.calendarExcluded.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
            return false
        }
        guard !Config.calendarAccounts.isEmpty else { return true }
        let account = calendar.source?.title ?? ""
        return Config.calendarAccounts.contains { $0.caseInsensitiveCompare(account) == .orderedSame }
    }

    private static func makeEvent(_ event: EKEvent) -> CalendarEvent? {
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
            color: event.calendar?.color ?? .controlAccentColor,
            calendarName: event.calendar?.title ?? "",
            location: location,
            searchText: AppIndex.fold([title, location ?? ""].joined(separator: " "))
        )
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

    /// Shows the system prompt once; the answer comes back through onUpdate.
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
        onUpdate?()
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

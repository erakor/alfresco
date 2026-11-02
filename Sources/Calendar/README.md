# Calendar

Type `cal` in the [launcher](../Launcher/README.md) and it shows what's next
over today and the next two days, from every calendar the macOS Calendar app
knows: your Google calendars once the account is added, plus iCloud, Exchange
and the rest. Enter still runs the `cal` workflows in `workflows.json`: Google
Calendar, or its search for the text.

## Set up

1. System Settings > Internet Accounts > Add Account > Google, sign in, and
   turn on Calendars. Check that your events show up in the Calendar app.
2. Run `build/Launcher.app` (`./build.sh`). The plain `./Launcher` binary
   can't get the permission, since it has no Info.plist to explain why it
   asks, so `cal` there only says so.
3. Type `cal`. macOS asks once whether the launcher may access your
   calendars (the launcher closes behind the prompt); allow it and type `cal`
   again.

## Use

- `cal` puts the next event first:
  - a line for the event under way ("En cours : Standup, se termine dans
    10 min");
  - a card for the next one with a countdown ("10 min", or its time and day
    when it is an hour away or more), its title, time, place and calendar;
  - two columns: "Plus tard aujourd'hui" and the next day that has events
    (Demain, or the date), up to 4 events each, all-day events as "Journée";
  - a last line counting what didn't fit.
- `cal <text>` lists up to 8 events of the next 30 days whose title or place
  contains the text, ignoring case and accents, under day headers. Each row
  shows its calendar's color, its time, and on the right "en cours", "dans
  12 min" (within the hour) or its place.
- Hover an event for its calendar's name and full place.
- Events are read on your Mac through EventKit: nothing goes over the network
  and there is no Google sign-in in the launcher. They are as fresh as the
  Calendar app's sync, and a change in a calendar refreshes the list at once.
- Declined events and the Birthdays calendar are left out.
- `build.sh` signs the app ad hoc, so macOS may ask again after a rebuild, or
  keep refusing: then reset it with `tccutil reset Calendars local.launcher`.
  If you said no, allow it in System Settings > Privacy & Security >
  Calendars.
- Labels are in French, like the weather.

## Settings

In `Sources/App/Config.swift` (rebuild after a change):

- `calendarKeyword` (`"cal"`): the keyword that shows the list. The two `cal`
  workflows in `workflows.json` only decide what Enter opens.
- `calendarDays` (3, today included) and `calendarSearchDays` (30).
- `calendarMaxEvents` (8): results listed by `cal <text>`.
- `calendarAccounts` (empty, every account): only these accounts, by the name
  shown in Internet Accounts (usually the address).
- `calendarExcluded` (empty): calendars left out by name, e.g. holidays.
- `calendarHidesBirthdays`, `calendarHidesDeclined` (both `true`).
- `calendarCacheLifetime` (60 s).

## Code

- `CalendarProvider.swift`: turns launcher input into a query, asks for
  access, reads and caches the events through EventKit.
- `CalendarView.swift`: the "next up" layout for `cal` and the result list
  for `cal <text>`, under the input.

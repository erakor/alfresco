# Transit

Type `/transit` or `/metro` in the [launcher](../Launcher/README.md) to see
the next subway trains at W 4 St-Washington Sq, under the input instead of
the suggestion list:

- The station's name, then two columns, **Uptown** and **Downtown**, with
  up to six trains each (`Config.transitDepartures`), soonest first.
- Each train has its line's round bullet in the MTA's colors, a countdown
  ("now", "4 min", rounded down like the station clocks) and its time.
- A footer says how old the MTA's data is ("Updated 25 s ago"), and when
  one of the station's feeds didn't answer ("some lines unavailable").

Enter opens the station in Google Maps, the `transit` workflow's URL in
[`workflows.json`](../../workflows.json). Change it there, or add
keywords to that workflow: the board shows for any workflow whose first
keyword is `Config.transitKeyword` (`transit`).

## Setup

The trains come from [transit](https://github.com/erakor/transit), a small
service that reads the MTA's real-time feeds and answers with the next
trains at a station, line names and colors included. The launcher needs its
address and token; until both are set, the board says so.

```sh
mkdir -p ~/.config/alfresco
printf '%s\n' 'https://<your-deployment>.vercel.app' > ~/.config/alfresco/transit-url
(umask 077; printf '%s\n' '<token>' > ~/.config/alfresco/transit-token)
```

Or set `ALFRESCO_TRANSIT_URL` and `ALFRESCO_TRANSIT_TOKEN` in the
launcher's environment. The address must be https. Both are read before
each fetch, so no restart is needed. The token is sent in the
`X-Transit-Token` header, which lets the service's CDN cache answers.

A snapshot is fetched when the board appears and again every 30 seconds
while it stays open (`Config.transitCacheLifetime`); countdowns are redrawn
every 10 seconds from the times already fetched. Nothing is fetched while
the launcher is closed. A failed fetch keeps the last snapshot on screen for
up to 3 minutes (the footer's age shows it getting older), then shows the
error; the next try waits 15 seconds.

## In the menu bar

A tram in the menu bar opens the same board as a menu, with the station's
service alerts under it: the MTA's status for each (Delays, Part
Suspended…), its lines' bullets and what it says, incidents first and
planned work dimmed, at most four and a count of the rest. **Open /transit
in Launcher** opens the launcher on the board.

Trains are fetched only while the menu is open (the launcher and the menu
share what was fetched, so opening one right after the other doesn't
fetch again), and the countdowns follow the clock while it stays open.

The tram shows an orange dot in its top-right corner while an incident
affects the station: delays,
suspensions, reroutes, anything the MTA hasn't planned. Planned work
(weekend and night changes) is listed in the menu but never shows the dot,
since there is some most nights. For the dot, the station's alerts are
checked every 5 minutes while the screens are awake
(`Config.transitAlertCheckInterval`; the service caches them for a minute,
so this costs it little), and the dot goes away once they can't be checked
for 30 minutes. The icon's tool tip names the first incident.

`Config.transitMenuBarItem = false` removes the item;
`Config.transitAlertCheckInterval = nil` stops the background checks (the
menu still lists the alerts when it opens, and the dot never shows). The
item is independent of `Config.showMenuBarIcon`, and absent while
`Config.transitStation` is nil. Without the service's address and token,
the menu says how to set them up.

## Any station in the hint

`/subway <station>` (`/subway bedford av`) shows the next train per line
and direction at any station in the launcher's hint, from the service's
`/preview/subway`, and Enter opens the station in Google Maps:

```
Bedford Av · L ↑2 ↓4 min  ↩ Station in Google Maps bedford av
```

`↑` is the northbound (uptown) platform, `↓` the southbound one. The name
is the service's best match, so check it in the hint before relying on the
times. It is the `subway` workflow's `preview` in
[`workflows.json`](../../workflows.json), `{service}/preview/subway?q={query}`:
`{service}` is the address set up above, sent with the token, and kept for
the 20 seconds the service says. Without the address and token there is no
preview, and the workflow still opens Maps.

## PATH, LIRR, Metro-North and NYC Ferry

The same kind of hint, one line from the service's `/preview/path`,
`/preview/lirr`, `/preview/mnr` and `/preview/ferry`: the station, then the
next departure to each destination in whole minutes, soonest first.

| Type | Hint |
| --- | --- |
| `/path grove` | `Grove Street · Journal Square 0 · 33rd Street 1 · Newark 3 min` |
| `/lirr penn` | `Penn Station · Ronkonkoma 1 · Huntington 9 · Port Washington 16 min` |
| `/mnr white plains` | next Metro-North trains at White Plains |
| `/ferry wall st` | next boats from Wall St/Pier 11 |

Enter opens the station in Google Maps. Like `/subway`, the name is the
service's best match, the line is kept for the 20 seconds the service says,
and without the address and token there is no preview. A PATH train at the
platform reads 0. Ferry times past a boat's next stop are the service's
estimates.

## Another station

Set `Config.transitStation` in [`Config.swift`](../App/Config.swift) to a
station id from the service's `/stops/search`:

```sh
curl -s -H "X-Transit-Token: $(cat ~/.config/alfresco/transit-token)" \
  "$(cat ~/.config/alfresco/transit-url)/stops/search?q=union+sq"
```

```swift
static let transitStation: String? = "635+L03+R20"
```

A single stop id (`L08`) works too. `transitNorthLabel` and
`transitSouthLabel` name the columns ("Uptown" and "Downtown" by default;
"Manhattan" and "Brooklyn" suit an L or G station better). `nil` turns the
board off: the workflow then just opens its URL.

The board shows only the subway; PATH, the LIRR, Metro-North and the ferry
are in the hint (above). Buses can't be added yet: the service has bus
service alerts (`/bus/alerts`) but no bus arrivals, which wait on an MTA
Bus Time key and the static bus data (see the service's roadmap).

## Files

| File | What it does |
| --- | --- |
| `TransitAPI.swift` | `TransitLoader` asks the service for the station's trains (signpost `transit.load`) and decodes the answer; `TransitBoard` (pure) sorts, limits and counts down what a snapshot holds at a given moment. |
| `TransitProvider.swift` | Keeps the last snapshot and the last alerts, and fetches new ones when they are stale, one of each at a time, for the launcher and the menu bar item (one provider, made by the app). Never fetches in the self-test build, which has no service. |
| `TransitView.swift` | The board under the input, with the shared `StatusRow` while loading or failed. |
| `TransitAlerts.swift` | `TransitAlertsLoader` asks the service for the station's alerts (`/subway/alerts?stop=`, signpost `transit.alerts`) and decodes them; `TransitAlerts.incidents` are the ones that show the dot. |
| `TransitStatusItem.swift` | The menu bar item: fetches when its menu opens, redraws every 10 s while open, checks alerts in the background while the screens are awake. |
| `TransitMenuView.swift` | The menu's content: the board, then the alerts. |
| `TransitMenuBarIcon.swift` | The tram as a template image (with a hole for the dot during an incident), and `TransitBadgeView`, the orange dot over it: a template image is one color, so the dot is a view on the status button. |

The usage stats count snapshots loaded (`transit.loaded`), failures by kind
(`transit.failed.offline`, `.token`, `.server`, `.badResponse`), alerts
loaded and their failures (`transit.alertsLoaded`,
`transit.alertsFailed.<kind>`), and how often the board is shown
(`transit.shown`, once per launcher opening; `transit.menuOpened` from the
menu bar), never what it lists.

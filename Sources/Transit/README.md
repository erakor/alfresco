# Transit

Type `/transit`, `/metro` or `/bus` in the [launcher](../Launcher/README.md)
to see the next subway trains at W 4 St-Washington Sq, under the input
instead of the suggestion list:

- The station's name, then two columns, **Uptown** and **Downtown**, with
  up to six trains each (`Config.transitDepartures`), soonest first.
- Each train has its line's round bullet in the MTA's colors, a countdown
  ("now", "4 min", rounded down like the station clocks) and its time.
- A footer says how old the data is ("Updated 25 s ago"), and when one of
  the feeds didn't answer ("some lines unavailable").

Enter opens the station in Google Maps, the `transit` workflow's URL in
[`workflows.json`](../../workflows.json). Change it there, or add
keywords to that workflow: the board shows for any workflow whose first
keyword is `Config.transitKeyword` (`transit`).

## Data

The trains come from the MTA's GTFS-Realtime subway feeds
(`api-endpoint.mta.info`), which need no key or account. The station needs
two of them, fetched side by side: `nyct/gtfs-ace` for the A, C and E
(8 Av platforms) and `nyct/gtfs-bdfm` for the B, D, F and M (6 Av
platforms). A train rerouted onto the other line still shows, since both
feeds are read for both platforms.

A snapshot is fetched when the board appears and again every 30 seconds
while it stays open (`Config.transitCacheLifetime`); countdowns are redrawn
every 10 seconds from the times already fetched. Nothing is fetched while
the launcher is closed. A failed fetch keeps the last snapshot on screen for
up to 3 minutes (the footer's age shows it getting older), then shows the
error; the next try waits 15 seconds.

## Another station

Set `Config.transitStation` in [`Config.swift`](../App/Config.swift):

```swift
static let transitStation: TransitStation? = TransitStation(
    name: "14 St-Union Sq",
    stopIDs: ["635", "R20", "L03"],
    feeds: ["nyct/gtfs", "nyct/gtfs-nqrw", "nyct/gtfs-l"]
)
```

- `stopIDs` are the parent stop IDs in the MTA's static GTFS `stops.txt`
  (one per platform group; the feeds add `N` or `S` for the direction).
- `feeds` are the paths of the feeds for the lines stopping there:
  `nyct/gtfs` (1 to 7 and S), `nyct/gtfs-ace`, `nyct/gtfs-bdfm`,
  `nyct/gtfs-g`, `nyct/gtfs-jz`, `nyct/gtfs-nqrw`, `nyct/gtfs-l`,
  `nyct/gtfs-si`.
- `northLabel` and `southLabel` name the columns ("Uptown" and "Downtown"
  by default; "Manhattan" and "Brooklyn" suit an L or G station better).

`nil` turns the board off: the workflow then just opens its URL.

Buses aren't on the board: the MTA's bus times need a Bus Time key.

## Files

| File | What it does |
| --- | --- |
| `GTFSRealtime.swift` | `TransitStation`, and a minimal protobuf reader that finds the trains due at the station's platforms in a feed, skipping every other field. |
| `TransitAPI.swift` | `TransitLoader` fetches the feeds (signpost `transit.load`); `TransitBoard` (pure) sorts, limits and counts down what a snapshot holds at a given moment. |
| `TransitProvider.swift` | Keeps the last snapshot and fetches a new one when it is stale, one at a time. Never fetches in the self-test build. |
| `TransitView.swift` | The board under the input, with the shared `StatusRow` while loading or failed. |

The usage stats count snapshots loaded (`transit.loaded`), failures by kind
(`transit.failed.offline`, `.server`, `.badResponse`) and how often the
board is shown (`transit.shown`, once per opening), never what it lists.

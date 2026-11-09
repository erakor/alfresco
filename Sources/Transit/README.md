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

Buses aren't on the board yet: the service serves only the subway for now.

## Files

| File | What it does |
| --- | --- |
| `TransitAPI.swift` | `TransitLoader` asks the service for the station's trains (signpost `transit.load`) and decodes the answer; `TransitBoard` (pure) sorts, limits and counts down what a snapshot holds at a given moment. |
| `TransitProvider.swift` | Keeps the last snapshot and fetches a new one when it is stale, one at a time. Never fetches in the self-test build, which has no service. |
| `TransitView.swift` | The board under the input, with the shared `StatusRow` while loading or failed. |

The usage stats count snapshots loaded (`transit.loaded`), failures by kind
(`transit.failed.offline`, `.token`, `.server`, `.badResponse`) and how
often the board is shown (`transit.shown`, once per opening), never what it
lists.

# Weather

With a [WeatherAPI.com](https://www.weatherapi.com/pricing.aspx) key (the
free plan is enough, no card needed), typing `/weather` or `/weather <place>` in
the [launcher](../Launcher/README.md) opens a forecast under the input: current
conditions (temperature, feels-like, humidity, wind, chance of rain this hour),
the next 12 hours (temperature, icon, chance of rain or snow;
`Config.weatherHours`), and below them a compact line with three days' high /
low and chance of rain or snow. Enter still opens the `weather` workflow's page.

## Set up

1. Create a free account at weatherapi.com and copy your API key from the
   dashboard.
2. Save it, alone on the first line, in `~/.config/alfresco/weatherapi-key`.
   Type or paste it at the prompt (it isn't shown) rather than piping it from
   the clipboard, so it doesn't stay in the clipboard history:

   ```bash
   mkdir -p ~/.config/alfresco
   (umask 077; trap 'stty echo' EXIT; trap 'exit 1' INT TERM
    printf 'WeatherAPI key: '; stty -echo; read -r key; stty echo; echo
    [ -n "$key" ] && printf '%s\n' "$key" > ~/.config/alfresco/weatherapi-key &&
      chmod 600 ~/.config/alfresco/weatherapi-key)
   ```

   If you copied the key, select it in the history (`⌘⌥C`) and press `⌘⌫`
   to delete it there.

   Or set `ALFRESCO_WEATHERAPI_KEY` in the launcher's environment. The key is
   read each time the launcher opens, so no restart is needed.

Without a key the launcher behaves as before, with the one-line `preview` in
the hint.

## Use

With a key, the launcher's top-right corner, above the input, always shows
the current weather where you are (e.g. "☀️ 14°  Ciel dégagé · Paris
↑ 16°  ↓ 8°"; hover it for the full place). Click it to open the forecast:
it types `/weather` in the input, replacing what was there, so Enter then
opens the `weather` workflow's page as usual. It shares the 10-minute cache with `/weather`,
so opening the launcher often costs at most one request every 10 minutes.
Turn it off with `Config.weatherStrip = false`. The same line shows the
[next meeting](../Calendar/README.md) on the left once calendar access is
granted; when both don't fit, the meeting's title is shortened first.

- `/weather paris`, `/weather lyon`, `/weather 75011`, `/weather cdg`: WeatherAPI
  accepts city names, postal codes, airport codes and `lat,lon`. The place is
  looked up after you pause typing.
- `/weather` alone is located from your public IP address (`auto:ip`), shown as
  "position approximative" since it can be off by a city. Set
  `Config.weatherHomePlace` (e.g. `"Paris, France"`) and rebuild to use a
  fixed place instead.
- Text is in French, metric units (`Config.weatherLanguage` sets the language
  of WeatherAPI's condition text and the day names; the panel's own labels
  are French).
- One request per place, reused for 10 minutes (`Config.weatherCacheLifetime`),
  far below the free plan's monthly quota. The free plan forecasts 3 days
  (`Config.weatherDays`).
- "Powered by WeatherAPI.com" in the corner is the link back the free plan
  asks for.

## Settings

In `Sources/App/Config.swift` (rebuild after a change):

- `weatherKeyword` (`"weather"`, typed `/weather`): the keyword that shows the forecast.
- `weatherLanguage` (`"fr"`): language of the condition text and day names.
- `weatherStrip` (`true`): the current weather above the input.
- `weatherDays` (3, the free plan's maximum) and `weatherHours` (12).
- `weatherHomePlace` (`nil`, located by IP): the place for `/weather` alone.
- `weatherCacheLifetime` (10 min).

## Code

- `WeatherAPI.swift`: the `forecast.json` request, the `Forecast` model and
  WeatherAPI error codes.
- `WeatherProvider.swift`: turns launcher input into a query, debounces,
  caches and runs one request at a time.
- `WeatherView.swift`: the forecast panel under the input.
- `WeatherStripView.swift`: the line above the input.

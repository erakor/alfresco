# Built-ins

Small answers the [launcher](../Launcher/README.md) works out itself instead
of opening a URL. The hint shows the answer as you type, the icon shows which
built-in it is, and `Enter` copies it to the clipboard and closes the bar
(so it also lands in the [clipboard history](../Clipboard/README.md)). Hover
the hint for details.

| Input | Hint | `Enter` copies |
| ----- | ---- | -------------- |
| `= 3*14` | `42` | `42` |
| `= 2^10 / (4 + 4)` | `128` | `128` |
| `= 10 km in mi` | `6.21371192237 mi` | `6.21371192237` |
| `= 100 c in f` | `212 °F` | `212` |
| `time tokyo` | `Tokyo 22:05, Tue 3 Nov` | `22:05` (always 24-hour) |
| `time 15:00 tokyo` | `15:00 Tokyo = 07:00 Paris` | `07:00` |
| `time 9am new york in paris` | `09:00 New York = 15:00 Paris` | `15:00` |
| `uuid` | `↩ Copy a new UUID` | a new random UUID, lowercase |
| `now` | `2026-11-03T14:05:09+01:00` | the time when you press `Enter` |

A [workflow](../Launcher/README.md#workflows) keyword always wins: with a
`time` workflow in `workflows.json`, `time tokyo` runs it instead. Built-ins
come before apps and the fallback search, and `⌘↩` skips them and searches
for what you typed.

## Calculator

Everything after `=` is a calculation:

- `+ - * /` (also `×`, `÷`, `−`), `^` or `**` for powers, parentheses.
  `-2^2` is `-4`, `2^3^2` is `2^9`.
- `%` divides by 100: `15% * 80` is `12`.
- A number next to a parenthesis or a name multiplies: `2(3+4)`, `2pi`.
- Decimals with `.` or `,` (`1,5 + 1` is `2.5`), and exponents (`1e3`,
  `2.5E-2`). There are no thousands separators, and a comma that could be
  one (`1,000`, `12,500`) is refused rather than read as a decimal: write
  `1000`, or `1.000` for a decimal.
- `pi` (or `π`), `tau`, `e`, and the functions `sqrt`, `cbrt`, `abs`,
  `round`, `floor`, `ceil`, `ln`, `log` (base 10), `log2`, `exp`, `sin`,
  `cos`, `tan`, `asin`, `acos`, `atan` (radians), written `sqrt(2)` or
  `sqrt 2`.

Results are whole numbers when they can be, else up to 12 significant digits,
always with a `.` and no grouping, so they paste into code and spreadsheets.
While the calculation is unfinished or has no result (`= 3*`, `= 1/0`), the
hint says why and `Enter` beeps instead of searching for it. So does a
calculation nested too deeply to work out (a pasted run of thousands of `(`).

## Units

`= <amount> <unit> in <unit>` converts. `to`, `en`, `->` and `→` work like
`in`, and the amount can be a calculation (`= 2*3 kg in g`). Units are
case-insensitive:

| Kind | Units |
| ---- | ----- |
| Length | `mm` `cm` `m` `km` `in` `ft` `yd` `mi` `nmi` |
| Area | `cm2` `m2` `km2` `ha` `acre` `ft2` (`sqft`) `mi2`, also with `²` |
| Volume | `ml` `cl` `dl` `l` `m3` `tsp` `tbsp` `fl oz` `cup` `pt` `qt` `gal` (US) |
| Mass | `mg` `g` `kg` `t` `oz` `lb` `st` |
| Temperature | `c` (`°c`) `f` (`°f`) `k` |
| Speed | `m/s` `km/h` (`kmh`, `kph`) `mph` `kn` |
| Data | `b` `kb` `mb` `gb` `tb` (bytes, powers of 1000), `kib` `mib` `gib` `tib` (powers of 1024), the French `o` `ko` `mo` `go` `to`, and bits: `bit`, `kbit` `mbit` `gbit` `tbit`, or `Kb` `Mb` `Gb` `Tb` written with a capital and a lowercase `b` |
| Duration | `ms` `s` `min` `h` `d` (`j`) `wk` |

Most units also take their full names, in English and some in French
(`miles`, `kilomètres`, `pouces`, `heures`). Because the last `in` counts,
`= 10 in in cm` converts inches, and `= 30 cm in in` converts to them.
Bytes and bits only differ in case where it is the usual spelling: `MB`,
`mb` and `Mo` are megabytes, `Mb` and `Mbit` megabits (`= 100 Mb in MB` is
`12.5`).

## Time zones

`time <place>` shows the time there now. With a time, `time <time> <place>`
shows that time in your time zone, `time <time> in <place>` shows your time
there, and `time <time> <place> in <place>` converts between the two. A
conversion that lands on another day says so (`+1 day`).

- Times: `15:00`, `15h`, `15h30`, `9am`, `9:30 pm`. A bare number like `15`
  is not a time.
- Places: the cities of macOS's time zones (`tokyo`, `new york`,
  `sao paulo`, accents and dashes optional), more cities and some French names
  (`sf`, `nyc`, `lyon`, `londres`, `pékin`, `inde`, `honolulu`, `reunion`),
  common abbreviations (`cet`, `bst`, `est`, `pst`, `ist`, `jst`, `aest`
  and a few more; each stands for its region, so `pst` follows daylight
  saving time), `utc`, `utc+2`, `utc-5:30`, and `here`.
- Island and polar zones, whose names are often plain words (Christmas,
  Easter, Wake), answer only to their full name (`time pacific/easter`) or
  to the cities above, so `time christmas` stays a search.
- The hint shows times in your Mac's format (12 or 24 hours); Enter always
  copies `HH:mm` (`22:05`), so it pastes cleanly anywhere.

`time` alone, or followed by words that are not a place (`time machine`), is
left to apps and the search.

## UUID and timestamp

- `uuid`: a new random UUID, lowercase, made when you press `Enter`.
- `now`: the current date and time in ISO 8601 with your offset
  (`2026-11-03T14:05:09+01:00`). `now utc` (`2026-11-03T13:05:09Z`),
  `now unix` (seconds), `now ms` (milliseconds) and `now date`
  (`2026-11-03`) give other forms. The value is taken again when you press
  `Enter`.

## Settings

In `Sources/App/Config.swift` (rebuild after a change); `nil` turns one off:

- `calculatorPrefix` (`=`): what starts a calculation or conversion.
- `timeKeyword` (`time`), `uuidKeyword` (`uuid`), `timestampKeyword` (`now`).

The [usage stats](../Shared/README.md#usage-stats) count how often each
built-in's answer is copied, never what was typed or copied.

## Code

- `BuiltIns.swift`: which built-in takes the input (after workflows), the
  answers for `=`, `uuid` and `now`, the separators (`in`, `to`…) both
  conversions split on, and `BuiltInContext` (the clock, time zone and
  locale, pinned by the self-test).
- `Calculator.swift`: the expression evaluator and the number format.
- `UnitConverter.swift`: the unit table and `<amount> <unit> in <unit>`.
- `WorldClock.swift`: places, times and the `time` answers.

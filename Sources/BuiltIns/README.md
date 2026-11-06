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
| `days until 25/12` | `52 days until Fri 25 Dec 2026` | `52` |
| `days since 1/1` | `306 days since Thu 1 Jan 2026` | `306` |
| `= today + 30 days` | `Thu 3 Dec 2026` | `2026-12-03` |
| `week` | `Week 45: Mon 2 Nov 2026 – Sun 8 Nov 2026` | `45` |
| `week 12` | `Week 12: Mon 16 Mar 2026 – Sun 22 Mar 2026` | `2026-03-16` |

Built-ins use bare words, and [workflow](../Launcher/README.md#workflows)
keywords are typed after `/`, so they don't collide: with a `time` workflow in
`workflows.json`, `/time tokyo` runs it and `time tokyo` still shows the time.
(With `Config.commandPrefix` set to `nil`, the workflow wins.) Built-ins
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

## Dates

Dates are read day first, whatever the Mac's language: `25/12`, `25.12`,
`25/12/2026` (or `/26`), ISO `2026-12-25`, with a month name in English or
French (`25 dec`, `25 décembre`, `1er janvier 2027`, `dec 25`), or as a word:
`today`, `tomorrow`, `yesterday`, `aujourd'hui`, `demain`, `hier`,
`après-demain`, `avant-hier`, and weekdays (`friday`, `fri`, `vendredi`,
`ven`), which mean the coming one (a week away on that very day).

- `days until <date>` (also `to`, `till`, `before`, `jusqu'au`, `avant`):
  the days left. A date without a year is the next one, today included, so
  `days until 1/1` counts to New Year's Day.
- `days since <date>` (also `depuis`): the days gone by; a date without a
  year is the last one, today included.
- `days <date>`: either way, with this year's date when no year is given
  (`days 1/11` on 3 November is `2 days since`).
- `days from <date> to <date>` (also `between … and …`, `du … au …`): the days
  between two dates, this year's when no year is given.

Enter copies the number of days; the tooltip gives it in weeks too. `days`
alone, or followed by words that aren't a date (`days of thunder`), is left
to apps and the search; after `until` or `since`, a date that can't be read
(`days until 31/2`) says so and `Enter` beeps.

After `=`, a date can be moved by days (`d`, `day`, `j`, `jours`), weeks
(`w`, `week`, `sem`, `semaines`), months (`mo`, `month`, `mois`) or years
(`y`, `year`, `an`, `ans`): `= today + 30 days`, `= today+30d`,
`= 31/1 + 1 month` (the 28th, months never overflow), `= friday + 1 week`.
`Enter` copies the date as `2026-12-03`; the tooltip gives its week number and
how far away it is. One date minus another gives the days between them
(`= 25/12 - today` is `52`). A date written in digits alone is still a
division, so `= 25/12` is `2.08333333333` and `= 25/12 - 1/1` too: add a
duration or a word to make it a date.

`week` gives this ISO week's number (weeks start on Monday, and week 1 holds
the year's first Thursday) and its dates; `week <date>` the week that day is
in (`week 1/1/2027` is week 53 of 2026). Both copy the number. `week 12`, or
`week 12 2027`, shows that week's dates and copies its Monday; a week the
year doesn't have (`week 53 2027`) says so.

Days are counted in your Mac's time zone, a day at a time, so a daylight
saving change never shifts a count.

## Settings

In `Sources/App/Config.swift` (rebuild after a change); `nil` turns one off:

- `calculatorPrefix` (`=`): what starts a calculation or conversion.
- `timeKeyword` (`time`), `uuidKeyword` (`uuid`), `timestampKeyword` (`now`),
  `daysKeyword` (`days`), `weekKeyword` (`week`). Date arithmetic goes with
  `calculatorPrefix`.

The [usage stats](../Shared/README.md#usage-stats) count how often each
built-in's answer is copied, never what was typed or copied.

## Code

- `BuiltIns.swift`: which built-in takes the input (after workflows), the
  answers for `=`, `uuid` and `now`, the separators (`in`, `to`…) both
  conversions split on. `BuiltInContext` (the clock, time zone and locale,
  pinned by the self-test) is in `Sources/Shared/DateReading.swift`.
- `Calculator.swift`: the expression evaluator and the number format.
- `UnitConverter.swift`: the unit table and `<amount> <unit> in <unit>`.
- `WorldClock.swift`: places, times and the `time` answers.
- `DateMath.swift`: `days`, `week` and date arithmetic after `=`. Reading
  the dates is shared with the calendar, in
  [`Sources/Shared/DateReading.swift`](../Shared/README.md).

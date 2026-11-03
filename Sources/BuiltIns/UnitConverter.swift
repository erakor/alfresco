// UnitConverter.swift
//
// `= 10 km in mi`: an amount (any calculation) with a unit, converted to
// another unit of the same kind. The units are a table of their own rather
// than Foundation's, so their names (French ones included) are ours.

import Foundation

enum UnitConversionError: Error, Equatable, Sendable {
    case unknownUnit(String)
    /// From and to measure different things, e.g. km in kg.
    case incompatible(from: String, to: String)
    case amount(CalculatorError)

    var message: String {
        switch self {
        case .unknownUnit(let name): return "Unknown unit \"\(name)\""
        case .incompatible(let from, let to): return "Can't convert \(from) to \(to)"
        case .amount(let error): return error.message
        }
    }
}

enum UnitConverter {
    enum Quantity: Sendable {
        case length, area, volume, mass, temperature, speed, data, duration
    }

    /// A unit as `factor` × value + `offset` of its quantity's base unit
    /// (metre, square metre, litre, kilogram, kelvin, metre per second,
    /// byte, second).
    struct Unit: Equatable, Sendable {
        let symbol: String
        let quantity: Quantity
        let factor: Double
        var offset: Double = 0
    }

    struct Conversion: Equatable, Sendable {
        let amount: Double
        let from: Unit
        let to: Unit
        let value: Double
    }

    /// Every name a unit is known by, lowercased, and the unit.
    private static let units: [String: Unit] = {
        let table: [([String], Unit)] = [
            // Length (metre)
            (["mm", "millimeter", "millimeters", "millimetre", "millimetres"], Unit(symbol: "mm", quantity: .length, factor: 0.001)),
            (["cm", "centimeter", "centimeters", "centimetre", "centimetres"], Unit(symbol: "cm", quantity: .length, factor: 0.01)),
            (["m", "meter", "meters", "metre", "metres", "mètre", "mètres"], Unit(symbol: "m", quantity: .length, factor: 1)),
            (["km", "kilometer", "kilometers", "kilometre", "kilometres", "kilomètre", "kilomètres"], Unit(symbol: "km", quantity: .length, factor: 1000)),
            (["in", "inch", "inches", "pouce", "pouces"], Unit(symbol: "in", quantity: .length, factor: 0.0254)),
            (["ft", "foot", "feet", "pied", "pieds"], Unit(symbol: "ft", quantity: .length, factor: 0.3048)),
            (["yd", "yard", "yards"], Unit(symbol: "yd", quantity: .length, factor: 0.9144)),
            (["mi", "mile", "miles"], Unit(symbol: "mi", quantity: .length, factor: 1609.344)),
            (["nmi"], Unit(symbol: "nmi", quantity: .length, factor: 1852)),
            // Area (square metre)
            (["cm2", "cm²"], Unit(symbol: "cm²", quantity: .area, factor: 0.0001)),
            (["m2", "m²"], Unit(symbol: "m²", quantity: .area, factor: 1)),
            (["km2", "km²"], Unit(symbol: "km²", quantity: .area, factor: 1_000_000)),
            (["ha", "hectare", "hectares"], Unit(symbol: "ha", quantity: .area, factor: 10_000)),
            (["acre", "acres"], Unit(symbol: "acre", quantity: .area, factor: 4046.8564224)),
            (["ft2", "ft²", "sqft", "sq ft"], Unit(symbol: "ft²", quantity: .area, factor: 0.09290304)),
            (["mi2", "mi²"], Unit(symbol: "mi²", quantity: .area, factor: 2_589_988.110336)),
            // Volume (litre)
            (["ml"], Unit(symbol: "ml", quantity: .volume, factor: 0.001)),
            (["cl"], Unit(symbol: "cl", quantity: .volume, factor: 0.01)),
            (["dl"], Unit(symbol: "dl", quantity: .volume, factor: 0.1)),
            (["l", "liter", "liters", "litre", "litres"], Unit(symbol: "l", quantity: .volume, factor: 1)),
            (["m3", "m³"], Unit(symbol: "m³", quantity: .volume, factor: 1000)),
            (["tsp", "teaspoon", "teaspoons"], Unit(symbol: "tsp", quantity: .volume, factor: 0.00492892159375)),
            (["tbsp", "tablespoon", "tablespoons"], Unit(symbol: "tbsp", quantity: .volume, factor: 0.01478676478125)),
            (["fl oz", "floz"], Unit(symbol: "fl oz", quantity: .volume, factor: 0.0295735295625)),
            (["cup", "cups"], Unit(symbol: "cup", quantity: .volume, factor: 0.2365882365)),
            (["pt", "pint", "pints"], Unit(symbol: "pt", quantity: .volume, factor: 0.473176473)),
            (["qt", "quart", "quarts"], Unit(symbol: "qt", quantity: .volume, factor: 0.946352946)),
            (["gal", "gallon", "gallons"], Unit(symbol: "gal", quantity: .volume, factor: 3.785411784)),
            // Mass (kilogram)
            (["mg"], Unit(symbol: "mg", quantity: .mass, factor: 0.000001)),
            (["g", "gram", "grams", "gramme", "grammes"], Unit(symbol: "g", quantity: .mass, factor: 0.001)),
            (["kg", "kilo", "kilos", "kilogram", "kilograms", "kilogramme", "kilogrammes"], Unit(symbol: "kg", quantity: .mass, factor: 1)),
            (["t", "tonne", "tonnes"], Unit(symbol: "t", quantity: .mass, factor: 1000)),
            (["oz", "ounce", "ounces"], Unit(symbol: "oz", quantity: .mass, factor: 0.028349523125)),
            (["lb", "lbs", "pound", "pounds"], Unit(symbol: "lb", quantity: .mass, factor: 0.45359237)),
            (["st", "stone", "stones"], Unit(symbol: "st", quantity: .mass, factor: 6.35029318)),
            // Temperature (kelvin)
            (["c", "°c", "celsius"], Unit(symbol: "°C", quantity: .temperature, factor: 1, offset: 273.15)),
            (["f", "°f", "fahrenheit"], Unit(symbol: "°F", quantity: .temperature, factor: 5.0 / 9, offset: 459.67 * 5 / 9)),
            (["k", "kelvin"], Unit(symbol: "K", quantity: .temperature, factor: 1)),
            // Speed (metre per second)
            (["m/s"], Unit(symbol: "m/s", quantity: .speed, factor: 1)),
            (["km/h", "kmh", "kph"], Unit(symbol: "km/h", quantity: .speed, factor: 1 / 3.6)),
            (["mph"], Unit(symbol: "mph", quantity: .speed, factor: 0.44704)),
            (["kn", "kt", "knot", "knots", "noeud", "noeuds", "nœud", "nœuds"], Unit(symbol: "kn", quantity: .speed, factor: 1852.0 / 3600)),
            // Data (byte); "o", "ko", "Mo"… are the French names.
            (["b", "byte", "bytes", "o", "octet", "octets"], Unit(symbol: "B", quantity: .data, factor: 1)),
            (["kb", "ko"], Unit(symbol: "kB", quantity: .data, factor: 1e3)),
            (["mb", "mo"], Unit(symbol: "MB", quantity: .data, factor: 1e6)),
            (["gb", "go"], Unit(symbol: "GB", quantity: .data, factor: 1e9)),
            (["tb", "to"], Unit(symbol: "TB", quantity: .data, factor: 1e12)),
            (["kib", "kio"], Unit(symbol: "KiB", quantity: .data, factor: 1024)),
            (["mib", "mio"], Unit(symbol: "MiB", quantity: .data, factor: 1_048_576)),
            (["gib", "gio"], Unit(symbol: "GiB", quantity: .data, factor: 1_073_741_824)),
            (["tib", "tio"], Unit(symbol: "TiB", quantity: .data, factor: 1_099_511_627_776)),
            // Bits, spelled out; "Mb" and the like are in exactUnits.
            (["bit", "bits"], Unit(symbol: "bit", quantity: .data, factor: 0.125)),
            (["kbit", "kbits"], Unit(symbol: "kbit", quantity: .data, factor: 125)),
            (["mbit", "mbits"], Unit(symbol: "Mbit", quantity: .data, factor: 125_000)),
            (["gbit", "gbits"], Unit(symbol: "Gbit", quantity: .data, factor: 125_000_000)),
            (["tbit", "tbits"], Unit(symbol: "Tbit", quantity: .data, factor: 125_000_000_000)),
            // Duration (second)
            (["ms"], Unit(symbol: "ms", quantity: .duration, factor: 0.001)),
            (["s", "sec", "secs", "second", "seconds", "seconde", "secondes"], Unit(symbol: "s", quantity: .duration, factor: 1)),
            (["min", "mins", "minute", "minutes"], Unit(symbol: "min", quantity: .duration, factor: 60)),
            (["h", "hr", "hrs", "hour", "hours", "heure", "heures"], Unit(symbol: "h", quantity: .duration, factor: 3600)),
            (["d", "day", "days", "j", "jour", "jours"], Unit(symbol: "d", quantity: .duration, factor: 86400)),
            (["wk", "week", "weeks", "semaine", "semaines"], Unit(symbol: "wk", quantity: .duration, factor: 604_800)),
        ]
        var units: [String: Unit] = [:]
        for (names, unit) in table {
            // The first unit to claim a name keeps it (no name is listed twice).
            for name in names where units[name] == nil { units[name] = unit }
        }
        return units
    }()

    /// Names whose case matters, matched as typed before `units`: a
    /// lowercase "b" after a capital is a bit, so "Mb" is megabits, while
    /// "mb" and "MB" are megabytes.
    private static let exactUnits: [String: Unit] = [
        "Kb": Unit(symbol: "kbit", quantity: .data, factor: 125),
        "Mb": Unit(symbol: "Mbit", quantity: .data, factor: 125_000),
        "Gb": Unit(symbol: "Gbit", quantity: .data, factor: 125_000_000),
        "Tb": Unit(symbol: "Tbit", quantity: .data, factor: 125_000_000_000),
    ]

    /// Every unit name, longest first (so "10 cm" is centimetres and not
    /// "10 c" metres), and of two as long, a case-sensitive one first (so
    /// "Mb" is tried before "mb").
    private static let namesByLength: [(name: String, exact: Bool)] = {
        let names = exactUnits.keys.map { (name: $0, exact: true) } + units.keys.map { (name: $0, exact: false) }
        return names.sorted { lhs, rhs in
            if lhs.name.count != rhs.name.count { return lhs.name.count > rhs.name.count }
            if lhs.exact != rhs.exact { return lhs.exact }
            return lhs.name < rhs.name
        }
    }()

    /// The unit `name` stands for: as typed among the case-sensitive names,
    /// else in any case.
    static func unit(named name: String) -> Unit? {
        exactUnits[name] ?? units[name.lowercased()]
    }

    /// `text` (what follows "=") read as `<amount> <unit> in <unit>`. nil
    /// when it isn't shaped like a conversion (no separator, or no unit
    /// before it), so it is a plain calculation instead.
    static func convert(_ text: String) -> Result<Conversion, UnitConversionError>? {
        guard let parts = BuiltIns.splitOnLastSeparator(text) else { return nil }
        let left = parts.left.trimmingCharacters(in: .whitespaces)
        let right = parts.right.trimmingCharacters(in: .whitespaces)
        guard let split = splitUnit(left) else { return nil }
        let from = split.unit
        guard let to = unit(named: right) else { return .failure(.unknownUnit(right)) }
        guard from.quantity == to.quantity else { return .failure(.incompatible(from: from.symbol, to: to.symbol)) }
        let amount: Double
        do {
            amount = try Calculator.evaluate(split.amount)
        } catch {
            return .failure(.amount(error as? CalculatorError ?? .incomplete))
        }
        let value = (amount * from.factor + from.offset - to.offset) / to.factor
        guard value.isFinite else { return .failure(.amount(.notFinite)) }
        return .success(Conversion(amount: amount, from: from, to: to, value: value))
    }

    /// "10 km" or "(2+3)km" as the amount's text and its unit. The unit's
    /// name must not follow a letter, so "2 pim" is not 2π metres.
    private static func splitUnit(_ text: String) -> (amount: String, unit: Unit)? {
        let lowercased = text.lowercased()
        for (name, exact) in namesByLength {
            let source = exact ? text : lowercased
            guard source.hasSuffix(name) else { continue }
            let amount = source.dropLast(name.count)
            if let last = amount.last, last.isLetter { continue }
            let trimmed = amount.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let unit = exact ? exactUnits[name] : units[name] else { continue }
            return (amount: trimmed, unit: unit)
        }
        return nil
    }
}

// Calculator.swift
//
// The arithmetic behind `= 3*14`: a small recursive-descent evaluator over
// Doubles (+ - * / ^, parentheses, %, a few functions and constants), and
// the number formatting every built-in answer uses.

import Foundation

/// Why an expression has no value.
enum CalculatorError: Error, Equatable, Sendable {
    /// Ends too early, e.g. "3*" or "(1+2".
    case incomplete
    case unexpected(Character)
    case unknownName(String)
    case divisionByZero
    /// Infinite or not a number, e.g. sqrt(-1) or 10^400.
    case notFinite

    var message: String {
        switch self {
        case .incomplete: return "Incomplete calculation"
        case .unexpected(let character): return "Unexpected \"\(character)\""
        case .unknownName(let name): return "Unknown \"\(name)\" (try sqrt, ln, log, sin, pi…)"
        case .divisionByZero: return "Division by zero"
        case .notFinite: return "No finite result"
        }
    }
}

enum Calculator {
    /// Functions of one argument, written `sqrt(2)` or `sqrt 2`. Angles
    /// are in radians.
    private static let functions: [String: @Sendable (Double) -> Double] = [
        "sqrt": { $0.squareRoot() },
        "cbrt": { cbrt($0) },
        "abs": { abs($0) },
        "round": { $0.rounded() },
        "floor": { $0.rounded(.down) },
        "ceil": { $0.rounded(.up) },
        "ln": { log($0) },
        "log": { log10($0) },
        "log2": { log2($0) },
        "exp": { exp($0) },
        "sin": { sin($0) },
        "cos": { cos($0) },
        "tan": { tan($0) },
        "asin": { asin($0) },
        "acos": { acos($0) },
        "atan": { atan($0) },
    ]

    private static let constants: [String: Double] = [
        "pi": Double.pi,
        "π": Double.pi,
        "tau": 2 * Double.pi,
        "e": exp(1.0),
    ]

    /// The value of `text`, e.g. "3*14", "2^10", "(1+2)*3", "-2^2" (-4),
    /// "2pi", "15% * 80", "1,5 + 1" (a comma is a decimal separator too).
    static func evaluate(_ text: String) throws -> Double {
        var parser = Parser(Array(text))
        let value = try parser.parseExpression()
        if let character = parser.peek() { throw CalculatorError.unexpected(character) }
        guard value.isFinite else { throw CalculatorError.notFinite }
        return value
    }

    /// `value` as it is shown and copied: a whole number without decimals,
    /// else up to 12 significant digits, "." as the decimal separator and no
    /// grouping, so it pastes into code and spreadsheets alike.
    static func format(_ value: Double) -> String {
        if value == 0 { return "0" } // -0 too
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.12g", value)
    }

    /// expression := term (("+" | "-") term)*
    /// term       := unary (("*" | "/") unary | implicit unary)*
    /// unary      := ("-" | "+") unary | power
    /// power      := postfix (("^" | "**") unary)?
    /// postfix    := primary "%"*
    /// primary    := number | "(" expression ")" | constant | function primary
    private struct Parser {
        let characters: [Character]
        var index = 0

        init(_ characters: [Character]) {
            self.characters = characters
        }

        /// The next character that isn't whitespace, without taking it.
        mutating func peek() -> Character? {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            return index < characters.count ? characters[index] : nil
        }

        mutating func parseExpression() throws -> Double {
            var value = try parseTerm()
            while let character = peek() {
                if character == "+" {
                    index += 1
                    value += try parseTerm()
                } else if character == "-" || character == "−" {
                    index += 1
                    value -= try parseTerm()
                } else {
                    break
                }
            }
            return value
        }

        mutating func parseTerm() throws -> Double {
            var value = try parseUnary()
            while let character = peek() {
                switch character {
                case "*", "×", "·":
                    index += 1
                    value *= try parseUnary()
                case "/", "÷":
                    index += 1
                    let divisor = try parseUnary()
                    guard divisor != 0 else { throw CalculatorError.divisionByZero }
                    value /= divisor
                case "(":
                    // "2(3+4)", "(1+2)(3+4)"
                    value *= try parseUnary()
                case _ where character.isLetter:
                    // "2pi", "3 sqrt 2"
                    value *= try parseUnary()
                default:
                    return value
                }
            }
            return value
        }

        mutating func parseUnary() throws -> Double {
            switch peek() {
            case "-"?, "−"?:
                index += 1
                return try -parseUnary()
            case "+"?:
                index += 1
                return try parseUnary()
            default:
                return try parsePower()
            }
        }

        mutating func parsePower() throws -> Double {
            let base = try parsePostfix()
            if peek() == "^" {
                index += 1
                return try pow(base, parseUnary())
            }
            if peek() == "*", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                return try pow(base, parseUnary())
            }
            return base
        }

        mutating func parsePostfix() throws -> Double {
            var value = try parsePrimary()
            while peek() == "%" {
                index += 1
                value /= 100
            }
            return value
        }

        mutating func parsePrimary() throws -> Double {
            guard let character = peek() else { throw CalculatorError.incomplete }
            if character == "(" {
                index += 1
                let value = try parseExpression()
                guard let closing = peek() else { throw CalculatorError.incomplete }
                guard closing == ")" else { throw CalculatorError.unexpected(closing) }
                index += 1
                return value
            }
            if Self.isDigit(character) || character == "." || character == "," {
                return try parseNumber()
            }
            if character.isLetter {
                let name = parseName()
                if let function = Calculator.functions[name] {
                    return try function(parsePostfix())
                }
                if let constant = Calculator.constants[name] { return constant }
                throw CalculatorError.unknownName(name)
            }
            throw CalculatorError.unexpected(character)
        }

        /// Digits with at most one "." or "," and an optional exponent
        /// ("1e3", "2.5E-2"). An "e" not followed by digits is left for
        /// the constant e ("2e" is 2 × e).
        mutating func parseNumber() throws -> Double {
            var text = ""
            var hasSeparator = false
            while index < characters.count {
                let character = characters[index]
                if Self.isDigit(character) {
                    text.append(character)
                } else if (character == "." || character == ","), !hasSeparator {
                    hasSeparator = true
                    text.append(".")
                } else {
                    break
                }
                index += 1
            }
            guard text.contains(where: Self.isDigit) else { throw CalculatorError.unexpected(characters[index - 1]) }
            if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                var lookahead = index + 1
                var exponent = "e"
                if lookahead < characters.count, characters[lookahead] == "+" || characters[lookahead] == "-" {
                    exponent.append(characters[lookahead])
                    lookahead += 1
                }
                var exponentDigits = ""
                while lookahead < characters.count, Self.isDigit(characters[lookahead]) {
                    exponentDigits.append(characters[lookahead])
                    lookahead += 1
                }
                if !exponentDigits.isEmpty {
                    text += exponent + exponentDigits
                    index = lookahead
                }
            }
            if text.hasPrefix(".") { text = "0" + text }
            if text.hasSuffix(".") { text += "0" }
            guard let value = Double(text) else { throw CalculatorError.unexpected(characters[index - 1]) }
            return value
        }

        /// Letters, then letters or digits ("log2"); lowercased.
        mutating func parseName() -> String {
            var name = ""
            while index < characters.count,
                  characters[index].isLetter || (!name.isEmpty && Self.isDigit(characters[index])) {
                name.append(characters[index])
                index += 1
            }
            return name.lowercased()
        }

        static func isDigit(_ character: Character) -> Bool {
            character.isASCII && character.isNumber
        }
    }
}

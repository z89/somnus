//  SleepAssertionParser.swift
//  SomnusKit: shared parser for `pmset -g assertions`.
//
//  What it parses:
//
//      Assertion status system-wide:
//         PreventUserIdleSystemSleep     1
//      Listed by owning process:
//         pid 353(powerd): [0x0000c3050001987c] 01:01:43 PreventUserIdleSystemSleep named: "Powerd - …"
//         	Details: caffeinate asserting for 300 secs
//      Kernel Assertions: 0x4=USB
//         id=684  level=255 0x4=USB creat= description=… owner=iPhone
//
//  Only the "Listed by owning process" section produces assertions. The parser
//  accepts rows without an elapsed time or `named:` clause.
//
//  The process-name group is bounded by the literal `): [0x` that always
//  follows it and is *lazy*, so a name containing parentheses survives intact
//  while a `named:` string that happens to contain `): [0x` cannot swallow the
//  row it belongs to.
//
//  `SleepAssertion` is a stable contract keyed on an owning pid and process
//  name; a kernel assertion has neither. Reporting one as `pid 0` invents a pid
//  that belongs to no process and that a script cannot distinguish from a real
//  one without also parsing the type string. Both surfaces now agree to leave
//  the kernel section alone rather than guess at it. `somnus why` documents
//  this in its usage text, so the omission is stated rather than silent.

import Foundation

public enum SleepAssertionParser {

    private static let processSectionHeader = "Listed by owning process:"

    /// Groups: 1 pid, 2 process name, 3 assertion id, 4 type, 5 `named:` text.
    /// The elapsed-time field is non-capturing and optional.
    private static let processPattern = try? NSRegularExpression(
        pattern: #"^\s*pid\s+(\d+)\((.*?)\):\s*\[(0x[0-9A-Fa-f]+)\]\s*(?:[0-9:]+\s+)?([A-Za-z][A-Za-z0-9_]*)(?:\s*named:\s*"(.*)")?\s*$"#)

    /// Every process-owned assertion pmset listed, in the order it listed them.
    /// Junk, empty input and "nothing is holding the Mac awake" all yield `[]`.
    public static func parse(_ text: String) -> [SleepAssertion] {
        guard let expression = processPattern else { return [] }

        var results: [SleepAssertion] = []
        var inProcessSection = false
        var seenIdentifiers = Set<String>()

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix(processSectionHeader) {
                inProcessSection = true
                continue
            }
            if endsProcessSection(trimmed) {
                inProcessSection = false
                continue
            }
            guard inProcessSection, !trimmed.isEmpty else { continue }

            let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            guard let match = expression.firstMatch(in: rawLine, range: range) else {
                // A continuation line ("Details: …", "Localized=…", "Timeout
                // will fire in …") belongs to the assertion above it.
                if let detail = continuationDetail(trimmed), let last = results.popLast() {
                    results.append(SleepAssertion(id: last.id,
                                                  pid: last.pid,
                                                  processName: last.processName,
                                                  type: last.type,
                                                  detail: merge(last.detail, detail)))
                }
                continue
            }

            let pid = Int32(capture(match, 1, in: rawLine) ?? "") ?? -1
            let processName = capture(match, 2, in: rawLine) ?? "unknown"
            let identifier = capture(match, 3, in: rawLine) ?? "unknown"
            let type = capture(match, 4, in: rawLine) ?? "unknown"
            let named = capture(match, 5, in: rawLine)

            // SleepAssertion is Identifiable; a duplicate id in a SwiftUI list
            // is a runtime hazard, so make it unique rather than trusting pmset.
            var uniqueIdentifier = identifier
            var suffix = 2
            while !seenIdentifiers.insert(uniqueIdentifier).inserted {
                uniqueIdentifier = "\(identifier)#\(suffix)"
                suffix += 1
            }

            results.append(SleepAssertion(id: uniqueIdentifier,
                                          pid: pid,
                                          processName: processName.isEmpty ? "unknown" : processName,
                                          type: type,
                                          detail: named.flatMap { $0.isEmpty ? nil : $0 }))
        }

        return results
    }

    // MARK: - Private

    /// Any header that means "the process list is over". `pmset` prints either
    /// `Kernel Assertions: …` or `No kernel assertions.` depending on whether
    /// there are any, and re-prints the system-wide block in some variants.
    private static func endsProcessSection(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("Kernel Assertions") { return true }
        if trimmed.hasPrefix("Assertion status system-wide") { return true }
        return trimmed.lowercased().hasPrefix("no kernel assertions")
    }

    private static func capture(_ match: NSTextCheckingResult,
                                _ index: Int,
                                in line: String) -> String? {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: line) else { return nil }
        return String(line[range])
    }

    private static func continuationDetail(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("Details:") else { return nil }
        let value = trimmed.dropFirst("Details:".count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func merge(_ existing: String?, _ addition: String) -> String {
        guard let existing, !existing.isEmpty else { return addition }
        return "\(existing): \(addition)"
    }
}

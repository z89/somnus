//  Output.swift
//  somnus CLI: stdout/stderr plumbing.
//
//  The output contract, because someone will pipe this into a script:
//    * every line stdout emits is `key: value` (status) or a TAB-separated
//      record (why). Nothing else goes to stdout: diagnostics go to stderr.
//    * ANSI escapes and column padding are emitted ONLY when stdout is a TTY.
//      Redirect it and the bytes are plain ASCII with single TAB separators.

import Foundation

enum Output {

    /// `true` only when stdout is a terminal. Checked once: a process's stdout
    /// cannot change underneath it, and re-checking per line would be noise.
    static let stdoutIsTTY: Bool = isatty(FileHandle.standardOutput.fileDescriptor) == 1

    // MARK: Writing

    static func line(_ text: String) {
        write(text + "\n", to: FileHandle.standardOutput)
    }

    /// Diagnostics, prefixed like every other well-behaved Unix tool.
    static func error(_ text: String) {
        write("somnus: " + text + "\n", to: FileHandle.standardError)
    }

    /// Human-only commentary (column headers, "nothing to report"). Suppressed
    /// entirely when stdout is redirected so it can never pollute a pipeline.
    static func note(_ text: String) {
        guard stdoutIsTTY else { return }
        write(dim(text) + "\n", to: FileHandle.standardError)
    }

    private static func write(_ text: String, to handle: FileHandle) {
        handle.write(Data(text.utf8))
    }

    // MARK: Styling: no-ops unless stdout is a TTY

    static func dim(_ text: String) -> String { style(text, "\u{001B}[2m") }
    static func green(_ text: String) -> String { style(text, "\u{001B}[32m") }
    static func yellow(_ text: String) -> String { style(text, "\u{001B}[33m") }
    static func red(_ text: String) -> String { style(text, "\u{001B}[31m") }

    private static func style(_ text: String, _ code: String) -> String {
        guard stdoutIsTTY else { return text }
        return code + text + "\u{001B}[0m"
    }

    // MARK: Records

    /// `key: value`, with the value styled only for a human reader.
    static func field(_ key: String, _ value: String, style: (String) -> String = { $0 }) {
        line("\(key): \(style(value))")
    }

    /// One record per line. TAB-separated when piped; padded into columns when a
    /// human is looking. The field *values* are byte-identical either way.
    static func table(_ rows: [[String]], headers: [String]) {
        guard stdoutIsTTY else {
            for row in rows { line(row.joined(separator: "\t")) }
            return
        }
        guard !rows.isEmpty else { return }
        var widths = headers.map { $0.count }
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        note(zip(headers, widths).map { pad($0, to: $1) }.joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces))
        for row in rows {
            let cells = row.enumerated().map { index, cell -> String in
                // Never pad the last column: trailing spaces are pure noise.
                index == row.count - 1 ? cell : pad(cell, to: widths[index])
            }
            line(cells.joined(separator: "  "))
        }
    }

    private static func pad(_ text: String, to width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}

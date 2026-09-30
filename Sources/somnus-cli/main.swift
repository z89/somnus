//  main.swift
//  somnus CLI: entry point only.
//
//  Everything real lives in CLI.swift; top-level code exists here solely because
//  Swift requires the executable's entry point to be in a file called main.swift.

import Foundation

exit(await SomnusCLI.run(arguments: CommandLine.arguments))

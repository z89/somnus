//  PowerEngineBridge.swift
//  Somnus: app-to-engine bridge.
//
//  The one place in Sources/Somnus/App/ that names the concrete power-engine
//  type. Everything else in this folder is written against
//  `PowerEngineObserving` from SomnusKit, so the app shell has no idea how
//  power is monitored and makes no IOKit or pmset calls of its own.

import SomnusKit

enum PowerEngineBridge {

    /// The app's single power engine, seen only through the stable protocol.
    @MainActor
    static var engine: any PowerEngineObserving {
        PowerEngine.shared
    }

    /// Additive diagnostics that cannot live on the stable shared protocol.
    /// Reading this from a SwiftUI body observes the concrete `@Observable`
    /// engine without spreading that concrete type through the app shell.
    @MainActor
    static var health: PowerEngineHealth { PowerEngine.shared.health }

    /// Whether the latest Stay Awake value came from a successful live read.
    /// This diagnostic is intentionally kept off the stable shared protocol.
    @MainActor
    static var stayAwakeIsKnown: Bool { PowerEngine.shared.stayAwakeIsKnown }

    /// Touches the engine so it is constructed (and therefore starts watching)
    /// at launch rather than lazily when the preferences window first opens.
    /// The safety net has to be armed whether or not anyone opens a window.
    @MainActor
    static func activate() {
        // `PowerEngine.shared` starts itself and queues its own first refresh.
        _ = engine
    }
}

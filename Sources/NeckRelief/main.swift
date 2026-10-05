import NeckReliefCore

// Top-level code is nonisolated; the process starts on the main thread.
MainActor.assumeIsolated {
    NeckReliefMain.run()
}

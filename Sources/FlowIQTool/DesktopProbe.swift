import CoreGraphics

/// `desktop-probe --ausfuehren` (AirPods test 16.11.): starts the ScreenCaptureKit sound of `DesktopSource` for 3 s
/// and prints buffers, peak or the error's domain and code; only on that explicit flag, never in tests.
enum DesktopProbe {
    static func run(_ args: Args) async throws {
        guard args.flags.contains("ausfuehren") else { throw ToolError("nur mit --ausfuehren: 3 s Desktop-Ton") }
        print("bildschirmaufnahme_freigegeben: \(CGPreflightScreenCaptureAccess())")
        let counted = Mutex((buffers: 0, peak: Float(0))), source = DesktopSource()
        do {
            try await source.start(deliver: { chunk in counted.withLock {
                $0 = ($0.buffers + 1, max($0.peak, chunk.samples.map(abs).max() ?? 0)) } },
                                   onEnd: { print("ende: \($0)") })
        } catch {
            let e = error as NSError
            return print("start_fehlgeschlagen: domain=\(e.domain) code=\(e.code) fehler=\(error)")
        }
        try await Task.sleep(for: .seconds(3))
        await source.stop()
        let result = counted.withLock { $0 }
        print("puffer: \(result.buffers) spitze: \(result.peak)")
    }
}

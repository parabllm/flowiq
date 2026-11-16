import FlowIQCloud

/// `nachlauf-vergleich --senden --audio <a,b> [--modelle <id,id>] [--wurzel <local/…>]` (16.11.): OpenRouter
/// models on the given audio with the production key; text, seconds and cost per model. Never without `--senden`.
enum Compare {
    static func run(_ args: Args) async throws {
        guard args.flags.contains("senden") else { throw ToolError("nur mit --senden: jeder Lauf kostet Guthaben") }
        let audio = (args.values["audio"] ?? "").split(separator: ",").map { URL(filePath: String($0)) }
        let keys = CloudKeys(keychain: SystemKeychain(), profile: .production, provider: .openRouter)
        guard !audio.isEmpty, keys.hasKey else { throw ToolError("--audio fehlt oder kein OpenRouter-Schlüssel") }
        let out = try Output(args, "nachlauf-vergleich"), meter = UsageMeter(folder: out.folder, fs: out.fs)
        var rows: [[String: String]] = []
        for model in (args.values["modelle"] ?? "elevenlabs/scribe-v2").split(separator: ",").map(String.init) {
            var settings = Settings.defaults(for: .production)
            settings[.room] = ModeConfig(live: .appleLocal, post: .elevenLabs, language: .de)
            (settings.postService, settings.openRouterModel) = (.openRouter, model)
            let policy = CloudPolicy(settings: settings, hasKey: false, openRouterKey: true)
            let post = try CloudGate.batchService(profile: .production, order: nil, policy: { policy },
                                                  pieces: { [out] in try AudioPieces.cut($0, $1, $2, fs: out.fs,
                                                  folder: out.folder.appending(path: "stuecke")) }, costs: meter)
            let before = await meter.costUSD("openrouter"), started = ContinuousClock.now
            let result = try await post.process(PostJob(audio: audio, language: "de", terms: [], mode: .room))
            let lines = result.segments.map { "[\(Int($0.start))] \($0.speaker): \($0.text)" }
            _ = try out.data(model.replacing("/", with: "_") + ".md", Data(lines.joined(separator: "\n").utf8))
            let usd = await meter.costUSD("openrouter") - before
            rows.append(["modell": model, "sekunden": "\(Int((ContinuousClock.now - started) / .seconds(1)))",
                         "usd": String(format: "%.4f", usd)])
            print("nachlauf-vergleich: \(model) fertig")
        }
        print("datei: \(try out.json("vergleich.json", rows).path)")
    }
}

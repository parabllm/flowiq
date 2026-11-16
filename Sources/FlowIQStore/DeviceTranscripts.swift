/// Device transcripts (A.9, A.11, 05b 1.1): `<stamp>-raum-<label>.md`, never overwritten, not even under `archive/`.
extension Aftercare {
    /// `post` is the devices switch (R-064): on, the file waits for the after-run, off it ends `final-lokal`.
    public func fileDevice(device: String, label: String, originalName: String, sha256: String, deviceSHA256: String,
                           recordedAt: Date, seconds: Double, audio: URL, segments: [LiveSegment],
                           language: RecordingLanguage, post: Bool) async throws -> URL {
        let folder = store.locations.transcripts, base = VaultDoc.date(recordedAt, "yyyy-MM-dd-HHmm") + "-raum-" + label
        var url = folder.appending(path: base + ".md"), n = 0
        while [folder, folder.appending(path: "archive")].contains(where: {
            TranscriptStore.exists($0.appending(path: url.lastPathComponent)) }) {
            n += 1
            url = folder.appending(path: "\(base)-erneut-\(n).md")
        }
        let stamp = VaultDoc.date(recordedAt, "yyyy-MM-dd HH:mm"), tag = String(label.prefix { $0 != "-" })
        var body = "\n# Transkript: \(device) \(stamp)\n\n"
        for s in segments where !s.words.isEmpty {
            body += VaultDoc.line(Int(s.words[0].start), "Raum", await store.stage(VaultDoc.oneLine(s.text))) + "\n"
        }
        let words = segments.flatMap(\.words), sure = words.compactMap(\.confidence)
        var doc = VaultDoc(fields: [
            "type": "transkript", "status": "unverarbeitet", "panotti_live": "false", "quelle": audio.path,
            "panotti_phase": post ? "live-lokal" : "final-lokal", "aufnahme": "\"\(stamp) (\(originalName))\"",
            "dauer": VaultDoc.clock(Int(seconds.rounded())), "sprecher_erkannt": "1",
            "nachlauf": post ? "wartet" : "aus",
            "sprache": language == .de ? "deu" : "eng", "pipeline": "\(tag)-import+lokal", "geraet": device,
            "quelle_stift_original": originalName, "sha256": sha256,
            "aktive_sprechzeit": VaultDoc.clock(Int(words.reduce(0) { $0 + $1.end - $1.start })),
            "wort_konfidenz_mittel": String(format: "%.2f", sure.reduce(0, +) / Double(max(sure.count, 1))),
            "qualitaet_status": words.isEmpty ? "pruefung-noetig" : "ok"], body: body)
        if sha256 != deviceSHA256 { doc.fields["sha256_geraet"] = deviceSHA256 }
        if n > 0 { doc.fields["neufassung_von"] = base + ".md" }
        doc.others = ["geraet", "quelle_stift_original", "sha256", "sha256_geraet", "aktive_sprechzeit",
                      "wort_konfidenz_mittel", "qualitaet_status", "neufassung_von"]
        try store.fs.claimNew(url, with: doc.data)
        guard post else { return url }
        await queue.put(QueuedJob(id: UUID().uuidString, file: url.path, audio: [audio.path], mode: .device,
                                  language: String(language.rawValue.prefix(2)), seconds: seconds, due: now()))
        await trigger(.timer)
        return url
    }
}
extension Aftercare {
    /// "Nachlauf jetzt" from the main window (16.11.): also for a file that ended local; the upgrade copies
    /// the local version first (E5); `choice` and `model` hold for this run only.
    public func postNow(_ file: URL, mode: RecordingMode, choice: PostService?, model: String?) async throws {
        let doc = VaultDoc(try Data(contentsOf: file)), place = URL(filePath: doc.fields["quelle"] ?? "")
        var tracks = TranscriptStore.list(place).filter { !$0.hasPrefix(".") && !$0.hasSuffix(".aac") }
            .map { place.appending(path: $0).path }
        tracks = tracks.isEmpty ? [place.path] : tracks
        let seconds = Double((doc.fields["dauer"] ?? "").split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) })
        var job = await queue.jobs.first { $0.file == file.path } ?? QueuedJob(id: UUID().uuidString, file: file.path,
            audio: tracks, mode: mode, language: String((doc.fields["sprache"] ?? "de").prefix(2)), seconds: seconds,
            due: now())
        (job.choice, job.model, job.due, job.paused, job.held) = (choice ?? .auto, model, now(), false, false)
        await queue.put(job)
        try await store.edit(file) { $0.fields["nachlauf"] = "wartet" }
        await trigger(.timer)
    }
}

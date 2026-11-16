<!-- TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert -->
# Abnahme-Tests P3 (Audio und Aufnahme)

Kontrollplan-Tests für Paket P3 aus `docs/ARCHITEKTUR.md` (A.4 FlowIQAudio, A.5 FlowIQRecording, B.2, B.3, B.5, F, G) und `docs/ABNAHME.md`. Sie entstanden aus der Beschreibung, bevor Audio- und Aufnahme-Code existiert; der Bau-Agent baut so, dass sie unverändert grün werden.

## Regel: Erwartungswerte unveränderlich

- Der Bau-Agent darf **nur** Zeilen ändern, die `// ASSUMPTION:` tragen (Namen, Labels, Initialisierer, Ereignis- und Feldnamen). Jede Zahl, jedes `#expect` ohne diese Marke bleibt, wie es ist.
- Alle angenommenen Schnittstellen sind in `P3Support.swift` gebündelt; Annahmen in den Testdateien stehen in derselben Zeile wie die Verwendung. Ändert sich ein Name, wird er in allen markierten Zeilen nachgezogen.
- Ist eine Erwartung nach Meinung des Bau-Agenten falsch, wird nicht der Test angepasst, sondern die Frage an den Auftraggeber gestellt.
- Annahmen über Zahlen, die die Architektur offen lässt: Spurwächter Stufe 2 nach spätestens 3 min (und nicht vor 20 s), Desktop-Stille bei stillem Mikrofon in 30 s, Speicherwachstum 3-h-Lauf höchstens 64 MB nach der ersten Viertelstunde. Sie tragen die Marke.

## Einbinden (einmalig, durch den Bau-Agenten)

Testziel `FlowIQP3Tests` in `Package.swift`, `path: "abnahme-tests/p3"`, Abhängigkeiten `FlowIQCore`, `FlowIQLog`, `FlowIQAudio`, `FlowIQRecording`. Die Tests brauchen weder Mikrofon noch Desktop-Ton noch eine Berechtigung: alle Quellen sind `SyntheticSource` (`CaptureSource` mit erzeugten Sinus-, Rausch- und Stille-Puffern auf virtueller Zeitachse, `hostTime` in Nanosekunden). Der 3-Stunden-Test trägt das Tag `slow`.

## Testgruppe zu ABNAHME-Zeile

| Datei | Gruppe | Zeilen |
|---|---|---|
| `LateBuffersTests` | späte Puffer nach Stopp, alle Endpfade, nie leer, nie neu geöffnet, Reihenfolge Quelle ab, dann schließen | R-039, Leitsatz 2, Ä-5 |
| `SizeVsDurationTests` | Größe gegen Dauer (4.000 und 6.000 B/s), `audio_lost`, `audio_verdaechtig` | R-039, R-047 |
| `RescueAndLockTests` | Rettung nach hartem Abbruch (60 s, 10 min), nichts gelöscht, Sperre | R-039, R-006 (Sperre je Profil) |
| `SourceEndTests` | Strom-Ende gleich Schreiber-Ende, Desktop-Neustart, Warnung ins Protokoll | R-040, R-042 |
| `TrackGuardTests` | Spurwächter Stufe 1 und 2, Ton beendet Warnung; Zeitachsen-Wächter (Lücke, Drift) | R-040, R-042 |
| `ConcurrencyTests` | Diktat während Call, Raum plus Call ein Mikrofon, Gerätewechsel und Geräteverlust, Überlauf gezählt | R-042, R-043 (P3-Anteil, B.5, E6) |
| `ValueTypeTests` | Werttypen, keine geteilten Puffer | Leitsatz 3, G02, S20 |
| `LongRecordingTests` | 3 h beschleunigt, Speicher flach, Datei vollständig | R-039, R-047 |
| `CallRoomSessionTests` | zwei Spuren je Call, Raumdatei unbearbeitet, nichts wachsend im Vault | R-037, R-038, R-046 |

## Nur mit echter Hardware (Phase 4, Testfenster T1)

- R-041 Call mit AirPods (Gerät im Protokoll), R-042 Matrix mit echten Geräten (15 Zellen), R-049 Deckel zu, Schlaf mitten in der Aufnahme
- R-039 echter `SIGKILL` nach 1, 30, 120 min und fast volle Platte (Test-Abbild); hier nur abgerissene Dateien nachgestellt
- R-040 Handetiketten-Archiv (K-18, `flowiq-tool spurpruefung`, Fehlalarme je 10 h); hier nur Pegelreihen
- R-044 Geräteeigenschaften vor und nach 10 Aufnahmen, R-083 Berechtigungen nach Updates, R-006 Verträglichkeit mit laufendem Panotti
- R-043 volle Gleichzeitigkeit über 10 min (P5), Pillenmarke für das Gerät (P4/P7)

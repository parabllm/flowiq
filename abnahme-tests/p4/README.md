<!-- TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert -->
# Abnahme-Tests P4 (Diktat: Fn-Abgriff und Gesten, lokale Erkennung live, Einfügen)

Kontrollplan-Tests für Paket P4 aus `docs/ARCHITEKTUR.md` (Kern, Zeitbudget Fn, A.3 FlowIQInput, A.6 FlowIQSpeech, A.8 FlowIQInsert, A.12 App, B.1, B.5, Anhang C, D, G) und `docs/ABNAHME.md`. Sie entstanden aus der Beschreibung, bevor Input-, Insert- und Koordinator-Code existiert; der Bau-Agent baut so, dass sie unverändert grün werden.

## Regel: Erwartungswerte unveränderlich

- Der Bau-Agent darf **nur** Zeilen ändern, die `// ASSUMPTION:` tragen (Namen, Labels, Initialisierer, Importzeilen, Schlüsselnamen des Journals). Jede Zahl, jedes `#expect` ohne diese Marke bleibt, wie es ist.
- Alle angenommenen Schnittstellen stehen gebündelt in `P4Support.swift` (Übersicht im Kommentar "Assumed API surface"); Annahmen in den Testdateien stehen in derselben Zeile wie die Verwendung.
- Ist eine Erwartung nach Meinung des Bau-Agenten falsch, wird nicht der Test angepasst, sondern die Frage an den Auftraggeber gestellt. Die Auslegungen unten sind genau die Stellen, an denen die Architektur offen lässt und der Auftraggeber bestätigen soll.
- Typecheck: alle Dateien bestehen `swiftc -typecheck -swift-version 6` mit `ExistentialAny` gegen die echten P1- bis P3-Module und Stubs der angenommenen P4-Typen (0 Fehler, 0 Warnungen). Gelaufen ist nichts.

## Einbinden (einmalig, durch den Bau-Agenten)

Testziel `FlowIQP4Tests` in `Package.swift`, `path: "abnahme-tests/p4"`, `exclude: ["README.md"]`, Abhängigkeiten `FlowIQCore`, `FlowIQLog`, `FlowIQAudio`, `FlowIQRecording`, `FlowIQInput`, `FlowIQInsert`, `FlowIQSpeech`, `FlowIQStore`, `FlowIQText` und das App-Ziel `FlowIQ` (per `@testable import`; der Koordinator `FlowCoordinator` liegt nach A.12 dort). Wo `DictationRecognizer`/`DictationRun` wirklich liegen, steht in der Importzeile mit Marke.

Laufen lassen: `swift test --filter FlowIQP4Tests`. Die Schwellen in Echtzeit (Pille ≤ 50 ms, Rückruf ≤ 500 ms) stehen in einer seriellen Suite (`TimelineTests`); bei Last ab 20 nicht laufen lassen (Regel Testlast), sonst mit `--no-parallel`. Der 5-Minuten-Test trägt das Tag `slow`.

## Nähte (nichts Echtes im Test)

| Naht | Test-Ersatz | Ersetzt |
|---|---|---|
| Ereignisquelle `KeyEventSource` | `SyntheticKeySource`, eigener Thread wie der Tap | `CGEventTap`, echte Tasten |
| `CaptureSource` | `P4Mic` (Start verzögerbar, in Echtzeit blockierbar, Fehlstart, Spät-Puffer) | Mikrofon; der echte `AudioConductor`, `TrackWriter`, `BusyState` laufen darauf |
| `DictationRecognizer` | `StubRecognizer` (Vorbereitung, Finalisieren verzögerbar, Fehler, hält jeden Puffer) | Apple-Erkenner |
| `TextProcessing` | `StubText` (festgelegte Eingriffe) | Textstufe P2 |
| `PasteboardPort` | `FakePasteboard` (mehrere Items, mehrere Typen, Versprechensdaten, `changeCount`) | `NSPasteboard` |
| `KeyPosting`, `FocusProbing`, `FrontAppProbing` | `FakeTarget` (holt wie eine App ab, träge, nie, Fehler, hängende Probe, Secure Input) | ⌘V, Bedienungshilfen, fremde Apps |
| `PillSink` | `PillRecorder` | Pille |
| Uhr | `ManualClock` (virtuell, `run(for:)` weckt in Fristfolge) | Zeit |

**Vertrag zur Uhr:** jede Wartezeit (Schwanz 110 ms, Doppeltipp-Fenster, Fokusprobe-Frist 50 ms, Rückgabe der Zwischenablage, 2 s ohne Abruf, Mikrofonstart) läuft über die injizierte `Clock`, nie über `Task.sleep` oder `DispatchQueue.after`. Wer das umgeht, lässt die Tests hängen. Die Reihenfolge-Beweise laufen über die Spur (`Trace`), die jede Naht mit Thread-Kennzeichen füllt.

## Testgruppen zu ABNAHME-Zeilen

| Datei | Inhalt | Zeilen |
|---|---|---|
| `GestureMachineTests` | Tabelle des Gestenautomaten: Halten, Tastenwiederholung, Doppeltipp-Sperre, zu später zweiter Druck, einzelner Tipp, Escape (gehalten, gesperrt, leer), Taste plus Leertaste, Prellen (Druck, Loslassen, Tipp), ⌃⌘V, Fn gegen ⌥ rechts (Akkord-Abbruch nur im Entwicklungsprofil); eine Flagge "Taste seit dem Einfügen", kein Textfeld im Ereignis; Zuordnung Rohwerte zu Ereignissen | R-014, R-013 (Taste je Profil), R-015 (Akkord getrennt), A.3 |
| `TimelineTests` | Pille vor jeder Mikrofonarbeit (Spur), kein Mikrofon-, Erkenner- oder Einfügeaufruf auf dem Hauptthread, Pille bei Mikrofonstart mit 130 ms Blockade in Echtzeit ≤ 50 ms, p95 ≤ 50 ms und Höchstwert ≤ 150 ms über 30 Diktate, t1 bis t2 ≤ 5 ms virtuell, 0 gestaute Tastendrücke, `fn.timeline` vollständig und geordnet | R-015, Z-05 (Teil), Anhang C |
| `FirstWordTests` | alle Proben ab Tastendruck beim Erkenner, gleich und in Reihenfolge, bei trägem Mikrofon und Erkenner (5 Fälle, 40 Zufallsläufe), Datei hat alles, kein Überlauf, Kurzdiktate ab 0,5 s, Mikrofon danach frei | R-016, B.1 Schritt 5 |
| `ReleaseToInsertTests` | Schwanz exakt 110 ms (nicht davor, nicht danach), Schwanz-Audio in Erkenner und Datei, Puffer nach dem Stopp auf drei Endpfaden (normal, Escape, Erkenner gescheitert), Loslassen bis Abruf Median ≤ 350 ms und p95 ≤ 800 ms, 5 min ≤ 2 s, Text im Journal vor ⌘V, 10 Diktate dicht hintereinander in Reihenfolge | R-017, R-016 (letztes Wort), R-019, R-020, R-022, Leitsatz 2 |
| `InsertionTests` | Fokusprobe zuerst (Frist 50 ms), nur lesbares Nicht-Textfeld sperrt, unlesbares wird eingefügt, Zwischenablage vollständig gesichert und zurück (+100 ms nach Abruf, 2 s ohne Abruf, nur bei gleichem `changeCount`), Fehler in jeder Stufe, kein ⌘V ins falsche Feld oder in Secure Input, Leerzeichenlogik über 20 Einfügungen, Feldinhalt und Diktat nie im Protokoll | R-019, R-020, A.8, G.2 Insert, `FlowIQInsertTests` |
| `RawVersionTests` | Rohfassung: ⌘Z und Erkennertext unverändert, nur bei gleicher App und ohne Taste seit dem Einfügen, genau einmal, `reject` im Journal mit Zahl der Eingriffe, Zwischenablage zurück | R-034, R-018 (Naht) |
| `DuringCallTests` | Diktat im Call hängt am laufenden Gerät (AirPods gewinnen gegen die Regel), kein zweites Öffnen, kein Gerätewechsel, Mikrofon bleibt offen bei normalem Ende, Escape und Fehler, Call-Spuren ohne Lücke und ohne späten Puffer, Erkenner bekommt nichts von vor der Taste; danach ohne Call öffnet das Diktat selbst | R-024 (P4-Anteil), R-043 (P4-Anteil), B.5, E6 |
| `AbortTests` | Escape, Akkord-Abbruch, Erkenner-Fehler, Mikrofon verweigert: kein Text, Zwischenablage unberührt, Audio und Journal bleiben, Mikrofon frei, Pille aus oder Marke, Fehler im Fehlerprotokoll, nächstes Diktat geht; ohne Textfeld: Marke und ⌃⌘V holt den Text; Einfügefehler: Zwischenablage zurück, Text per ⌃⌘V | R-019, R-022, R-015 (Akkord), R-014 (⌃⌘V), Leitsatz 5 |
| `JournalTests` | 25 Diktate mit Erkennertext, Eingriffen, Endtext, Ergebnis, Zeiten, nur anhängend, nichts gelöscht, keine Datei unter 4.000 B/s, Protokoll textfrei, Journal vor Einfügen über 8 Diktate | R-019 (500 von 500 als 25 hier), R-022, R-023 (Anteil), A.2, A.9 |

## Auslegungen (Architektur lässt offen; der Auftraggeber bestätigt oder korrigiert)

1. **Doppeltipp:** zweiter Druck innerhalb 0,36 s nach dem ersten Druck sperrt (die laufende Aufnahme bleibt). Ein Tipp kürzer als das Fenster stoppt erst, wenn das Fenster ohne zweiten Druck verstrichen ist (Stopp bis zu 0,36 s später). Alternative wäre sofortiger Stopp und zweites Diktat.
2. **Sperre beenden:** der nächste Tastendruck (beim Drücken, nicht beim Loslassen) stoppt.
3. **Taste plus Leertaste** sperrt in beiden Profilen; im Entwicklungsprofil lösen alle anderen Tasten (außer Leertaste und Escape) während des Haltens den Akkord-Abbruch aus, vor dem Drücken oder in der Sperre nicht. Escape ist nie ein Akkord, sondern Abbruch.
4. **Prellen:** Ereignisse innerhalb von unter 10 ms nach dem Gegenereignis sind Rauschen.
5. **Erneut einfügen:** ⌃⌘V im Produktivprofil, ⌃⌥⌘V im Entwicklungsprofil (Anhang D) im Gestenautomaten.
6. **Fenstersprung** zwischen Taste und Einfügen ist in A.8 nicht geregelt; getestet wird nur der Fokus im Moment des Einfügens (kein ⌘V in ein lesbares Nicht-Textfeld, nicht in Secure Input). Rohfassung verlangt dieselbe App wie beim Einfügen.
7. **Abbruch hält Audio:** auch Akkord-Abbruch und Escape lassen die Audiodatei samt Journal-Eintrag stehen (Leitsatz 2, R-022); EndReason `escape` im Journal bei Escape.
8. **Zwischenablage:** ohne Abruf nach 2 s Ergebnis `notFetched` und Original zurück; eine App, die erst danach abruft, bekäme den alten Inhalt. Das ist die Grenze des Entwurfs, kein Testfall.
9. **Leerzeichen:** vor den Text kommt ein Leerzeichen, wenn das Zeichen vor der Schreibmarke existiert und kein Leerraum ist.
10. **Journal-Schlüssel** (`event`, `id`, `ts`, `recognizer_text`, `final_text`, `interventions`, `recognize_ms`, `stage_ms`, `result`, `bytes`, `seconds`, `verdict`, `end_reason`, `interventions_rejected`) und der Wert `noTextFocus` bei nicht eingefügt sind frei wählbar (Marke), die Ereignisnamen nicht (A.9). Jeder Einfügeversuch hängt eine `inserted`-Zeile an.

## Nicht in diesen Tests

- **Speech-Modul:** 160 ms Stille, Finalisieren mit Frist 1,35 s, Rückfall auf Datei-Lauf aus dem Spool: gehören in `FlowIQSpeechTests` des Bau-Agenten (Attrappe der Erkenner-Schnittstelle, G.1). Hier ist der Erkenner die Naht.
- **Wiederholen** eines Diktats aus dem Audio (R-022, Ereignis `retry`): Schnittstelle in der Architektur offen, daher keine Erwartung.
- **Kurzbefehle** (Carbon, Registrierungsfehler): Teil von FlowIQInput, aber nicht im Auftrag dieser Tests.
- **Live-Datei** mit `(Diktat)`-Beitrag (R-024 Rest): P5.
- Zeilen mit Codesuche statt Test: R-018 (0 Aufrufe für Systemtöne, kein Fenster nach vorn), R-021 (Pille ohne Texteingang), R-023 (0 Löschpfade), R-067 (0 Upload-Pfade): `scripts/check.sh`.

## Nur mit echter Tastatur und echtem Mikrofon im Testfenster mit dem Auftraggeber (G-ECHT T2, Phase 5)

- R-013: 50 von 50 Diktate in Claude, Chrome, Slack, Notizen, Terminal an der Schreibmarke; im Entwicklungsprofil mit ⌥ rechts, die echte Fn-Taste (Tastenabgriff, Eingabeüberwachung, `fn`-Flag statt Tastencode, Sicherheitsnetz alle 30 s, abgeschaltete Taps) erst in Phase 5.
- R-015: Taste bis Pille im Bild (Bildwechsel, Fensterserver), p95 ≤ 50 ms und Höchstwert ≤ 150 ms über 200 Diktate, davon 20 nach 30 min Ruhe und 20 nach dem Aufwachen; Hauptthread-Taster (nie > 50 ms) im laufenden Bündel.
- R-016: Anfangsverlust kalt p95 ≤ 40 ms mit echtem `AVCaptureSession`, eingebautes Mikrofon und AirPods getrennt, 100 Läufe; Entscheid halbwarm; 50 von 50 Probe-Diktate mit erstem und letztem Wort mit echter Stimme; leere Einträge "unterbrochen" ≤ 0,5 % über 500 Diktate.
- R-017: Loslassen bis Ziel-App holt ab mit echten Apps (die Naht liefert nur den Anteil bis zur Abholung); 0 eingefrorene Oberfläche.
- R-018: vorderes Programm vor und nach 200 Diktaten gleich; keine Töne.
- R-019, R-020: echte `NSPasteboard`-Rückgabe mit träger Ziel-App (100 von 100), Fokusprobe über Bedienungshilfen in fünf Apps, Secure-Input-Erkennung echt, Marke an der Pille im Bild, Leerzeichen in echten Feldern.
- R-021, R-081: Bildschirmfoto je Pillenzustand (kein Diktattext, Fläche ≤ 120 × 150 pt).
- R-022: echter harter Abbruch (`SIGKILL`) mitten im 20-s-Diktat, 10 Läufe, Wiederholen liefert Text.
- R-025: AirPods verbunden, Musik läuft, Ausgabeformat vorher und nachher gleich (10 von 10).
- R-042 (P4-Anteil): Gerätewechsel mitten im Diktat (AirPods verbinden und trennen, Telefonie-Modus, Kopfhörer).
- R-067: 0 ausgehende Verbindungen während 100 Diktaten (`scripts/netzprobe.sh`).
- R-083: Berechtigungen nach drei Installationen mit Eingabeüberwachung und Bedienungshilfen.
- R-088: Footprint-Spitze ≤ 25 MB p95 und CPU je Diktat, Sprachdienst getrennt.
- R-006: Panotti-Diktate und ein Panotti-Call laufen fehlerfrei, während das Entwicklungsprofil diktiert.

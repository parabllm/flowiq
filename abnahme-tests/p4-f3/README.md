<!-- TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert -->
# Abnahme-Tests P4, Zusätze Fassung 3 (Korrekturfenster, Ersetzen im Zielfeld, Lernen, Diktat bleibt lokal)

Kontrollplan-Tests aus `docs/ARCHITEKTUR.md` Fassung 3 (Anhang I "Abnahmetests, die Fassung 3 ergänzt", N.2 bis N.5, M.1, M.9) und `docs/ABNAHME.md` (R-109 bis R-111, R-102, R-067 neu, R-034 neu gefasst). Sie entstanden aus der Beschreibung, bevor Korrektur-, Ersetzen- und Cloud-Code existiert. Der eingefrorene Ordner `abnahme-tests/p4` bleibt unverändert; dieser Ordner ergänzt ihn (eigenes Testziel, eigene Nähte, nichts geteilt). Gelaufen ist nichts, gebaut wurde nichts: geprüft ist nur `swiftc -parse` je Datei (0 Fehler).

## Regel: Erwartungswerte unveränderlich

- Der Bau-Agent darf **nur** Zeilen ändern, die `// ASSUMPTION:` tragen (Namen, Labels, Initialisierer, Importzeilen, Rohwerte von Journal-Schlüsseln). Jede Zahl und jedes `#expect` ohne diese Marke bleibt, wie es ist. Jede Zeile, die eine angenommene Form benutzt, trägt die Marke in derselben Zeile; "assumed API, see the Support header" heißt: Form und Begründung stehen im Kopf von `P4F3Support.swift`.
- Ist eine Erwartung nach Meinung des Bau-Agenten falsch, wird nicht der Test angepasst, sondern die Frage an den Auftraggeber gestellt. Die Auslegungen unten sind genau die Stellen, an denen die Architektur offen lässt.
- Alle angenommenen Schnittstellen sind im Kopfkommentar von `P4F3Support.swift` gebündelt ("Assumed API surface").

## Einbinden (einmalig, durch den Bau-Agenten)

Testziel `FlowIQP4F3Tests` in `Package.swift`, `path: "abnahme-tests/p4-f3"`, `exclude: ["README.md"]`, Abhängigkeiten `FlowIQCore`, `FlowIQLog`, `FlowIQAudio`, `FlowIQInsert`, `FlowIQSpeech`, `FlowIQStore`, `FlowIQText`, `FlowIQCloud` und das App-Ziel `FlowIQ` (per `@testable import`; `CorrectionSession` und `StatusMenuModel` liegen nach A.12 dort). Laufen lassen: `swift test --filter FlowIQP4F3Tests`. Testlast: höchstens zwei testende Läufe parallel; die Suiten sind seriell genug, das 300-ms-Fenster misst in Echtzeit (bei Last ab 20 nicht laufen lassen).

## Nähte (nichts Echtes im Test)

| Naht | Test-Ersatz | Ersetzt |
|---|---|---|
| Ziel-App und Feld | `FieldTarget` (lesbar, unlesbar, kein Textfeld; Zeichen-Offsets; stille Änderung ohne Taste; Fehler beim Schreiben) | Bedienungshilfen, fremde Apps, ⌘V, ⌘Z |
| Zwischenablage | `FakePasteboard` (mehrere Items und Typen, Versprechensdaten, `changeCount`, Klartext-Hinweis) | `NSPasteboard` |
| Korrekturfenster | `FakeWindowHost` (Fenster wird Key, vorherige App aktivieren) | Fenster und App-Aktivierung |
| Diktat-Verlauf | `StaticHistory` mit `Scripted` (Wortfolge, Eingriffe, Alternativen je Wortposition) | Journal und Verlauf der App |
| Mikrofon | `ToneMic` unter dem echten `AudioConductor` | Mikrofon |
| Cloud-Erkenner | `CountingLive` (zählt nur, was er bekommt) | ElevenLabs Realtime |
| Uhr | `ManualClock` (virtuell) | Zeit; jede Wartezeit läuft über die injizierte Uhr |

Das Fenster-Tempo (R-109 "≤ 300 ms") misst in echter Zeit mit Attrappen; es beweist die Logik, nicht das Zeichnen. Das echte Fenster misst G-UI.

## Testgruppen zu ABNAHME-Zeilen

| Datei | Inhalt | Zeilen |
|---|---|---|
| `CorrectionWindowTests` | öffnet in ≤ 300 ms (10 Läufe, 50 Diktate Verlauf), neuestes Diktat als Wortfolge, Alternativen (höchstens 3, Reihenfolge des Erkenners), nächste bestätigte Einträge (höchstens 3, nur bestätigte), Rohform, freie Eingabe, Spanne über mehrere Wörter, "war richtig" nur an Eingriffen, ein Klick übernimmt 10 von 10, Fokus zurück 10 von 10, Öffnen und Schließen ändert nichts, Diktattext nie im Protokoll, Kurzbefehl und Menü gleich | R-109, R-021 (Teil) |
| `ReplaceInFieldTests` | Weg 1 genau der Bereich im lesbaren Feld (ohne Tasten, Zwischenablage unberührt), Zeichen statt Bytes, Weg 2 ⌘Z und Neu-Einfügen des ganzen korrigierten Textes (stille Feldänderung, unlesbares Feld), Weg 3 Zwischenablage mit Hinweis (Taste getippt, andere App vorn, Secure Input), nichts zu ersetzen, Text außerhalb der Einfügung bleibt, Fehler beim Feldschreiben verliert nichts, Feldinhalt nie gespeichert | R-110, A.8 |
| `CorrectionLearningTests` | Ziel zuerst bestätigt, dann Hörvariante in Bewährung, Variante in Bewährung wirkt noch nicht, nach bestandener Bewährung (echtes `Probation.evaluate`, echte Textstufe) Fehlform 10 von 10 behoben, neue Fehlform zu bewährtem Ziel sofort aktiv, richtiges Wort als Quelle: einmalige Frage und nichts gelernt vor der Antwort, "immer", "nur neben", "nur dieses Mal" (3 von 3), Verwechslung zweier normaler Wörter erzeugt 0 Regeln und wird gezählt, erstes Rückgängig legt still (einziger Eingriff `retired`, mehrere `suspended`, nichts gelöscht, Liste "Zum Prüfen") | R-111 (P4-Anteil), R-114 (Rückgängig-Signal) |
| `RawVersionWindowTests` | "Rohfassung" als Schaltfläche im Fenster ersetzt den ganzen Text durch den Erkennertext, zählt als Ablehnung aller Eingriffe (`reject` mit Zahl), wirkt auf die Varianten wie jede Ablehnung, bei nur noch Zwischenablage zählt die Ablehnung trotzdem, genau einmal, kein Menüpunkt mehr | R-034 (neuer Weg), R-018 (Naht) |
| `CorrectionJournalTests` | Ereignis `correction` mit Art der Wahl und Ergebnis des Ersetzens, `reject_intervention` mit Eintrag und Variante, jede Wahl benannt, alle drei Ersetzen-Wege im Journal, Journal wächst nur, kein Feldinhalt der Ziel-App in Journal oder Protokoll, Protokoll ohne Korrekturtext | A.9, R-109, R-110 (Beleg) |
| `DictationStaysLocalTests` | Richtlinie erlaubt Diktat-Live nie (alle 8 Kombinationen aus Schlüssel, Live, Nachlauf), Diktat-Nachlauf nur mit Schalter und Schlüssel, handeditierte Einstellungsdatei kann Diktat-Live nicht öffnen, 10 Diktate während Cloud-Live im Call: 0 Diktat-Puffer im Cloud-Strom, Diktate lokal erkannt und eingefügt 10 von 10 | R-102, R-067 (Diktat-Live), R-096 (Diktat fest lokal) |

## Auslegungen (Architektur lässt offen; der Auftraggeber bestätigt oder korrigiert)

1. **"war richtig"** heißt: das Wort, das der Erkenner geliefert hat, war richtig; FlowIQs Eingriff an dieser Stelle war falsch. Der Text dort wird zur Rohform, genau dieser Eingriff wird abgelehnt (`reject_intervention`), die Variante wird nach Probation-Regel stillgelegt.
2. **"Erstes Rückgängig legt still"**: bei einer aktiven Hörvariante genügt die erste Ablehnung. War es der einzige Eingriff des Diktats, wird die Variante `retired`, bei mehreren `suspended`; sie wandert auf die Liste "Zum Prüfen", nichts wird gelöscht. Das ist die vorhandene Regel von `Probation.evaluate`; die Tests prüfen sie rein und über das Fenster.
3. **Neue Fehlform zu einem Ziel mit bestandener Bewährung** ist beim Klick sofort `active`; zu einem Ziel, dessen Variante noch in Bewährung ist, ebenfalls Bewährung. Das ist die Lesart von N.3 letzter Punkt für den Klickweg; der automatische Lautabgleich ohne Klick gehört zu P2c.
4. **Quelle ist ein richtiges Wort**: der Text wird sofort ersetzt, gelernt wird erst nach der Antwort (`.once` lernt nichts).
5. **Bereiche** beim Ersetzen zählen Zeichen (`Character`) des eingefügten Textes, nicht Bytes und nicht Feldpositionen; die Einfügung merkt sich, wo sie gelandet ist. Die Reihenfolge der drei Wege steht in N.2; die Taste-seit-Einfügen-Flagge reicht der Aufrufer als Parameter `keySinceInsert` herein (sie lebt im Gestenautomaten, A.3).
6. **Alternativen** hängen an der Wortposition (`segmentAlternatives` in diesen Skripten pro Wort ausgerichtet); die nächsten Einträge sind höchstens 3 bestätigte Einträge nach Klang (nicht vorgeschlagen, nicht zurückgezogen).
7. **Diktat im Cloud-Call**: der Mikrofonstrom zur Cloud bekommt zwischen Tastendruck und Ende des Schwanzes nichts (Zeitfenster nach Host-Zeit, damit die Reihenfolge der Ströme nicht zählt). Ob der Apple-Schatten in dieser Zeit weiterläuft, lässt die Architektur offen und wird hier nicht geprüft.
8. **Rohfassung ohne Ersetzen-Weg**: früher "verweigert, wenn Taste getippt"; jetzt gilt der Zwischenablage-Weg, die Ablehnung zählt trotzdem.
9. **Journal**: Ereignisnamen `correction` und `reject_intervention` stehen in Anhang I; Schlüsselnamen und Rohwerte (`fieldReplaced`, `undoReinserted`, `clipboardHint`, Wahl `alternative`, `lexicon`, `typed`) sind frei wählbar (Marke).

## Nicht in diesen Tests

- Reine Text- und Lexikon-Logik (Familien als Daten, Paar-Ausrichtung, Kontobuch, Schwelle 2 Aufnahmen an 2 Tagen, Signale S1 bis S8 vollständig, Kennzahl W): `abnahme-tests/p2` (P2c), R-114, R-115, R-116.
- Wortwahl und Aussehen des Fensters, Klick-Anzahl, Fokus in echten Apps, ⌘Z in echten Apps: Testfenster mit dem Auftraggeber (G-UI, App-synth in TextEdit und Notizen, R-110 "10 von 10 in TextEdit und Notizen").
- R-021 (Pille ohne Texteingang) und die Netzprobe R-067: `scripts/check.sh` und G-NETZ.
- Das alte Verhalten (Fn, Gesten, Einfügen): eingefrorener Ordner `abnahme-tests/p4`.

<!-- TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert -->
# Abnahme-Tests P5 (Nachlauf und Ablage)

Kontrollplan-Tests für Paket P5 aus `docs/ARCHITEKTUR.md` (E5, A.9 FlowIQStore, A.10 FlowIQPost, B.2, B.3, Anhang D, Anhang L, G.1/G.2 Store und Post) und `docs/ABNAHME.md`. Sie entstanden aus der Beschreibung und dem privaten Vertrag (`local/phase1/05b-vertrag-und-abnehmer.md`, nur Formate und Schlüssel), bevor Store- und Post-Code existiert. Der Bau-Agent baut so, dass sie unverändert grün werden.

## Regel: Erwartungswerte unveränderlich

- Der Bau-Agent darf **nur** Zeilen ändern, die `// ASSUMPTION:` tragen (Namen, Labels, Initialisierer, Ereignisnamen, `throws`). Jede Zahl und jedes `#expect` ohne diese Marke bleibt.
- Die angenommene Schnittstelle ist in `P5Support.swift` gebündelt (`Rig`, `DevRig`, `FakePost`). Die Testdateien benutzen nur diese Hüllen, außer in `DevProfileTests` (`beginLive` direkt).
- Ist eine Erwartung nach Meinung des Bau-Agenten falsch, wird der Test nicht angepasst, sondern die Frage an den Auftraggeber gestellt.
- Kein Netz, kein Mikrofon, kein echter Vault: temporärer Ordner je Test, handgestellte Uhr (`TestClock`), künstlicher Nachlauf-Dienst (`FakePost`), Verweis-Pfad im Temp-Ordner. `/tmp/panotti-live.md` wird nur per `lstat` angesehen (Fingerabdruck davor und danach), nie geschrieben.

## Einbinden (einmalig, durch den Bau-Agenten)

Testziel `FlowIQP5Tests` in `Package.swift`, `path: "abnahme-tests/p5"`, `exclude: ["README.md"]`, Abhängigkeiten `FlowIQCore`, `FlowIQLog`, `FlowIQStore`, `FlowIQPost`.

**Offene Baufrage:** `Aftercare` (der Koordinator aus B.2 Punkt 8: Stopp, Warteschlange, Kopie, Ersetzen, Archiv) braucht Store und Post, doch laut Paketschnitt kennt keines der beiden Module das andere. Wo er liegt, entscheidet der Bau-Agent (Protokoll und Werttypen von `PostTranscriber` nach Core, oder Koordinator in einem Modul, das beide sieht). Der Test bindet nur die Zeilen mit `ASSUMPTION` an; ändert sich die Aufteilung, wird das Testziel um die nötige Abhängigkeit ergänzt.

## Ausgelegte Entscheidungen (zur Bestätigung durch den Auftraggeber)

1. **Audio geht beim Stopp ins Archiv, auch wenn der Nachlauf scheitert** (Panotti-Befund: Archivierung nur nach Erfolg). Der Auftrag liest das Audio dann aus dem Archiv. Die Architektur nennt "Kopie, final-elevenlabs, dann Archiv" nur für den Erfolgsfall; `ArchiveTests.archiveDoesNotDependOnTheUploadResult` und `FailureQueueTests.audioMovesToTheArchiveEvenWhenTheServiceFails` legen den Stopp-Zeitpunkt fest.
2. `final-lokal` trägt `nachlauf: aus`; `quelle` zeigt in jeder Endphase auf einen vorhandenen Pfad im Archiv.
3. Ein beim Stopp offener Satzanfang ("spricht gerade") wird ein fertiger Beitrag, nicht gelöscht.
4. "Netz zurück", Klick und App-Start wiederholen sofort (ohne Wartezeit); `angehalten` (Kontingent, Schlüssel) wartet auf Klick oder den nächsten Tag (Test: nach 25 h).
5. Journal der Warteschlange: nur Zeilenzahl und Wiederaufnahme werden geprüft, nicht das Zeilenformat.
6. Die Live-Datei bietet `flush()` (alles Übergebene ist auf der Platte); nur der 5-s-Test und der Stopp-Test verzichten darauf.

## Testdatei zu ABNAHME-Zeile

| Datei | Gruppe | Zeilen |
|---|---|---|
| `ContractTests` | Dateinamen, Kollision (auch unter `archive/`), Kopfzeilen je Phase (`live-stream`, `live-lokal`, `recovered-wal`, `final-elevenlabs`, `final-lokal`), Statuswerte, nie `verarbeitet`, Beitragsformat, Stundenwechsel, `(Diktat)`, 20 Aufnahmen gleich 20 Dateien, Phasen nur vorwärts | R-052, R-024 (Live-Anteil), R-059/R-060 (Köpfe), Z-11 |
| `LiveFileTests` | nur anhängend (Zufallsfolgen, Präfix-Eigenschaft), flüchtige Schlusszeile, gleiche Datei (Inode), 5-s-Grenze, Stopp ohne Verlust, Diktat im Call | R-053, R-024, E5 |
| `LiveLinkTests` | Verweis auf laufende Datei, zwei Live-Dateien, Rückfall, Verweis nach Ende, atomarer Wechsel (nie fehlend), Fehler im Verweis | R-053, Prüfbericht G-12 |
| `AftercareTests` | Nachlauf an (Kopie vor Ersetzen, dann `final-elevenlabs`, gleiche Datei), leeres Ergebnis ersetzt nie, Anfrage (Sprache, Spuren), Begriffe höchstens 100 und kein Rückweg ins Lexikon, Nachlauf aus (10 von 10, 0 Aufrufe), Sammel-Nachzug | R-059, R-060, R-061, R-033, R-065 (Attrappe) |
| `FailureQueueTests` | Netz weg, Kontingent leer, Schlüssel fehlt, Serverfehler: Warteschlange, sichtbarer Status, `nachlauf:`, Wartezeiten 1/5/15/60 min dann stündlich, nie aufgegeben, Auslöser, Wiederaufnahme nach Neustart, abgerissene Zeile, Protokoll ohne Text | R-062, Z-11 |
| `ArchiveTests` | Audio wandert immer (Call-Ordner, Raum), byte-gleich, nie überschrieben, nie gelöscht, Größe gegen Dauer (6.000 B/s), leere Spur, Archiv blockiert, `quelle` existiert | R-059, R-060, R-039 (Archivteil) |
| `NoSilentLossTests` | jeder lokale Text bleibt in Datei oder Kopie, schwieriger Text, 3.000 Zeilen, Fehlversuche lassen den Rumpf unberührt, zweite Aufwertung | E5, R-062, R-060 |
| `DevProfileTests` | Entwicklungsprofil schreibt nie in einen Vault außerhalb seines Ordners, Verweis nur erlaubt, Panottis Verweis unverändert, alles im Temp-Ordner | R-006, R-005, Anhang D |

## Nicht in diesen Tests (braucht App oder Hardware)

R-024 Zeit- und Lückenwerte, R-043, R-048, Z-03, R-053 Dauermessung über 60 min, R-058, R-060 Wortfehlerrate, R-063, R-064 (P6), R-066 und R-067 (Code- und Netzprüfung per `check.sh`, G-NETZ), R-095 (Netzprobe), Z-11 über 7 Tage: Messungen im Testfenster T3 und in Phase 5.

# FlowIQ

Diktat, Call- und Raumaufnahme mit Live-Mitschrift für macOS. Eine kleine App in der Menüleiste, ohne Konto und ohne
Fremdbibliotheken; die Erkennung läuft auf dem Mac.

- **Diktat:** Fn halten, sprechen, loslassen: der Text steht im gerade aktiven Textfeld.
- **Call und Raum:** Aufnahme per Kurzbefehl, die Mitschrift wächst live als Markdown-Datei mit.
- **Geräte-Import:** Aufnahmen von einem angesteckten Diktiergerät werden kopiert, geprüft und transkribiert.
- **Lernendes Wörterbuch:** Eigennamen einmal bestätigen oder korrigieren, danach schreibt FlowIQ sie richtig.

## Voraussetzungen

- macOS 26.0 oder neuer (`Package.swift`, `LSMinimumSystemVersion`).
- Xcode mit Swift-Werkzeugen ab 6.2 (`swift-tools-version` in `Package.swift`), also Xcode 26 oder neuer. Gebaut und
  geprüft ist der Stand mit Xcode 27.2 (Swift 6.4.2). Es gibt kein Xcode-Projekt, nur das Swift-Paket.
- Kein Apple-Entwicklerkonto nötig. Mit einer Signatur ist der Alltag aber bequemer, siehe unten.

## Bauen und installieren

1. Klonen und in den Ordner wechseln: `git clone <adresse> flowiq && cd flowiq`
2. Bauen: `scripts/bundle.sh prod` erzeugt `build/FlowIQ.app`. Der erste Bau dauert einige Minuten.
3. Installieren: `scripts/install.sh prod` kopiert die App nach `~/Applications/FlowIQ.app`.
4. Starten: Doppelklick im Finder oder `open ~/Applications/FlowIQ.app`.

Nach einer Änderung am Code: App über ihr Menü beenden, dann Schritte 2 bis 4 erneut. `bundle.sh` baut nur,
`install.sh` kopiert nur; keines der beiden startet oder beendet etwas. `bundle.sh` bricht ab, solange die App läuft,
wenn die schnelle Prüfung (`scripts/check.sh --static`) rot ist oder der Mac stark ausgelastet ist.

**Ohne Signatur (geht sofort):** Findet `bundle.sh` keine Apple-Development-Identität im Schlüsselbund, signiert es
lokal (ad hoc) und sagt das am Ende. macOS vergibt die vier Rechte dann je Bau: nach jedem Neubau müssen Mikrofon,
Bedienungshilfen, Eingabeüberwachung und Bildschirmaufnahme neu erlaubt werden.

**Mit Signatur (empfohlen, kostenlos):** In Xcode unter Einstellungen > Accounts eine Apple-ID eintragen und dort
ein Zertifikat "Apple Development" anlegen. Der nächste Lauf von `bundle.sh` findet es von selbst, merkt es sich in
`local/signing.env` und signiert damit; die Rechte bleiben dann über Neubauten erhalten. Die Zeile `CONFIRMED=yes`
in dieser Datei schaltet den Hinweis auf die Bestätigung ab.

Es gibt zwei Profile. `prod` ist die App für den Alltag. `dev` (`scripts/bundle.sh dev`, "FlowIQ Dev") läuft
daneben mit eigenem Datenordner und eigenen Tasten und trägt sich nie in den Autostart ein: gut zum Ausprobieren.

## Erster Start: vier Rechte

Beim ersten Start öffnet sich "Einrichten". Jedes Recht hat genau einen Zweck:

| Recht | Wozu |
|---|---|
| Mikrofon | Diktat, Call und Raum aufnehmen. |
| Bedienungshilfen | Den erkannten Text in das aktive Feld einfügen. |
| Eingabeüberwachung | Fn und die Kurzbefehle erkennen; Tastatureingaben werden nicht gespeichert. |
| Bildschirmaufnahme | Nur für Calls: den Ton der Gegenseite aufnehmen. Es entsteht kein Bild vom Bildschirm. |

Nach manchen Rechten verlangt macOS einen Neustart der App; "Einrichten" zeigt das an. Fehlt das Sprachmodell für
eine Sprache, bietet das Menü "Sprachmodell laden" an; macOS lädt es dann einmalig.

## Tasten

| Taste | Wirkung |
|---|---|
| Fn halten | Diktat, solange die Taste gehalten wird |
| Fn Fn | freihändig diktieren, bis Fn noch einmal gedrückt wird |
| ⌘⌥U | Call-Aufnahme starten und stoppen |
| ⌘⌥R | Raum-Aufnahme starten und stoppen |
| E dazu (⌘⌥U oder ⌘⌥R mit E) | dieselbe Aufnahme auf Englisch |
| ⌘⌥K | letztes Diktat korrigieren |

In "FlowIQ Dev" ist die Diktiertaste die rechte ⌥-Taste, die Kurzbefehle tragen zusätzlich ⌃.

## Schlüssel für Cloud-Dienste (optional)

Ohne Schlüssel läuft alles lokal mit der Spracherkennung von macOS. Wer eine genauere Fassung will, trägt in den
Einstellungen der App einen Schlüssel für ElevenLabs oder OpenRouter ein. Der Schlüssel liegt nur im Schlüsselbund
des Macs, nie in einer Datei und nie im Repo.

## Wo die Daten liegen

- `~/Library/Application Support/FlowIQ/` (Dev: `FlowIQ-Dev/`): Einstellungen, Diktate mit Audio (`diktate/`),
  Wörterbuch (`lexikon/`), Protokoll (`protokoll/`), laufende Aufnahmen (`laufend/`).
- Mitschriften und fertige Aufnahmen: der in den Einstellungen gewählte Ordner, sonst `~/Documents/FlowIQ/`.
- `/tmp/flowiq-live.md`: Verweis auf die gerade wachsende Mitschrift.

## Datenschutz

Ohne Schlüssel verlässt nichts den Mac: Aufnahme, Erkennung, Wörterbuch und Ablage bleiben lokal. Erst mit
eingetragenem Schlüssel und eingeschalteter genauerer Fassung oder Live-Erkennung über ElevenLabs geht der Ton der
betreffenden Aufnahme an den gewählten Dienst. Der gesamte Netz-Code liegt im Modul `FlowIQCloud`; `check.sh`
lehnt Netzaufrufe an jeder anderen Stelle ab.

## Entwickeln

```bash
git config core.hooksPath .githooks   # einmal: Datenschutz-Prüfung bei Commit und Push
scripts/check.sh                      # alles: Datenschutz, Zeilenbudget, Verbote, Bau ohne Warnungen, Tests
scripts/check.sh --static             # nur die schnellen Prüfungen ohne Bau
scripts/zeilenbudget.sh               # Zeilen je Modul gegen budget.tsv
```

Swift 6 Sprachmodus, Warnungen sind Fehler. `check.sh` ist rot bei jedem Treffer und wenn weniger Tests laufen, als
`pruefgrenzen.tsv` verlangt. Das Zeilenbudget (`budget.tsv`) begrenzt jedes Modul und die Summe: wächst ein Modul
über seine Grenze, wird gekürzt oder gestrichen, nicht die Grenze verschoben.

| Modul | Inhalt |
|---|---|
| `FlowIQCore` | Profile, Pfade, Einstellungen, Schreibhülle `SafeFS` (einziger Ort für Schreibzugriffe) |
| `FlowIQLog` | Protokoll als NDJSON, Messung von RAM und CPU |
| `FlowIQInput` | Fn-Abgriff, Gesten (halten, doppelt tippen), Kurzbefehle |
| `FlowIQAudio` | Mikrofon und Desktop-Ton, Gerätewahl, Puffer |
| `FlowIQRecording` | AAC-Dateien schreiben, Rettung nach Absturz, Call- und Raum-Sitzung |
| `FlowIQSpeech` | lokale Erkennung für Diktat, Datei und Live-Mitschrift |
| `FlowIQText` | Textstufe: Wörterbuch, Namensregeln, Lernen aus Korrekturen (rein, ohne Oberfläche) |
| `FlowIQInsert` | Einfügen ins aktive Feld, Zwischenablage sichern und zurückgeben |
| `FlowIQStore` | Ablage: Mitschriften, Diktat-Journal, Wörterbuch-Datei, Nachlauf-Warteschlange |
| `FlowIQCloud` | einziges Netzmodul: ElevenLabs, OpenRouter, Schlüsselbund, Verbrauch |
| `FlowIQDevices` | Import von Diktiergeräten |
| `FlowIQ` | die App: Menü, Pille, Fenster, Einrichten, `Theme/` mit allen Farben und Maßen |
| `flowiq-tool` | Kommandozeilen-Werkzeug für Auswertungen |

Tests liegen unter `Tests/`, die vor dem Code geschriebenen Abnahmetests unter `abnahme-tests/`. Mehr dazu:
`docs/ARCHITEKTUR.md` (Aufbau und Entscheidungen), `docs/ABNAHME.md` (prüfbare Anforderungen),
`docs/LEXIKON-KONZEPT.md` (Wörterbuch), `docs/PRUEFLISTE.md` (Dateiformat "Mit Claude prüfen"),
`docs/ENTSTEHUNG.md` (Bauverlauf). Schrift: DM Sans unter `Resources/Fonts/`, SIL Open Font License 1.1.

## Anpassen mit einem KI-Assistenten

Das Repo ist dafür gebaut, mit einem KI-Assistenten (Claude Code oder ähnliche) verändert zu werden. Die Regeln
dafür stehen in `AGENTS.md`: `check.sh` grün vor jedem Commit, Zeilenbudget halten, Tests nicht aufweichen, Aussehen
nicht ungefragt ändern, nichts Privates committen. Eigene Zusatzregeln gehören in `local/AGENTS-privat.md`, eigene
Namen, die nie ins Repo dürfen, zeilenweise in `local/datenschutz-muster.txt`. Der Ordner `local/` ist privat, per
`.gitignore` ausgeschlossen und wird beim ersten Bau angelegt. In den Dokumenten heißt die App, die FlowIQ ablöst,
"die Vorgänger-App"; im Code trägt sie den Namen Panotti.

Weitergeben ohne Historie: `scripts/weitergabe.sh [zielordner]` legt einen sauberen Abzug des letzten Commits mit
einem einzigen neutralen Commit an und prüft ihn auf private Daten.

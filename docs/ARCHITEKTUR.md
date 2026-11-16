# FlowIQ v1: Architektur

**Fassung 3**, Stand 2026-11-13 abends, Architekt-Agent. Fassung 3 ergänzt die Wahl der Live-Erkennung je Betriebsart (Apple lokal oder ElevenLabs Realtime), den Korrektur-Kreislauf und die allgemeine Behandlung von Namen; Fassung 2 (Commit 0cf006b) war die Antwort auf die Prüfung von Fassung 1 (Commit c59b75e). Bindend ist das Anforderungs-Register (R-001 bis R-095, privat in `local/phase1/08-anforderungen.md`); die prüfbare Fassung je Anforderung steht in [`ABNAHME.md`](ABNAHME.md), das Zeilenbudget in [`../budget.tsv`](../budget.tsv).

Für das Repo geschrieben: keine Diktattexte, keine Namen von Kontakten oder Kunden, Pfade mit `~` und `<vault>` (Vault-Wurzel als Einstellung). Der Besitzer des Repos erscheint nur als Rolle bei Freigaben (Entscheid K-23).

**Zum Lesen:** `local/` ist ein privater Arbeitsordner des Besitzers, per `.gitignore` ausgeschlossen und in keinem Klon enthalten; jeder Verweis darauf nennt nur die Herkunft und lässt sich ohne den Ordner nicht nachschlagen. "Der Besitzer" ist die Person, für die FlowIQ zuerst gebaut wurde und die Freigaben erteilt. "Die Vorgänger-App" ist die App, die FlowIQ ablöst; im Code heißt sie Panotti (Bezeichner wie `panotti_phase`, `panottiLink`, Menüpunkt "Panotti-Daten übernehmen"). "Prüfung" und "Gegenprüfung" sind Durchsichten durch getrennte KI-Agenten, "Projektsteuerung" ist die Sitzung, die die Agenten beauftragt hat. Der Bauverlauf steht in [`ENTSTEHUNG.md`](ENTSTEHUNG.md).

Kürzel wie B07, G01, M06 (Bausteine, Gefahrenmuster, Garantien), S1 (Störfälle) und Rxx-Quellen verweisen auf die privaten Phase-1-Register unter `local/phase1/` (05a, 02, 08); sie sind im Repo nicht enthalten.

**Belegstufen:** [G] gemessen (Protokoll oder Lauf, Quelle genannt), [K] Korpus-Auswertung, [T] Typecheck-Probe (`swiftc -typecheck -swift-version 6`, Ziel macOS 26, privat unter `local/phase2/proben/`), [C] Code oder SDK-Schnittstelle gelesen, [D] Doku oder Fremdquelle, nicht nachgemessen, [E] Entwurf oder Annahme. Für Abnahmen gelten die Stufen aus Anhang H (App-echt, App-synth, Korpus, Test, Code, Hand).

## Änderungen Fassung 2 zu Fassung 3

Auslöser: Wünsche des Besitzers vom 13.11. (Live-Erkennung je Betriebsart umschaltbar, "für die Zukunft sicher"; falsch Erkanntes soll einmal korrigiert und dann behoben bleiben; Namen waren nur Beispiele) und die Entscheidung der Projektsteuerung zum Diktat-Nachlauf. Wortlaut privat in `local/phase2/abnahme-quellen.md`, Abschnitt Fassung 3. Recherche zu ElevenLabs Realtime: `local/phase2/recherche-elevenlabs-realtime.md` (nur offizielle Doku, kein Aufruf).

| Nr | Änderung | Wo |
|---|---|---|
| F3-1 | Schnittstelle `LiveRecognizer` in `FlowIQCore`; Umsetzungen Apple lokal (`FlowIQSpeech`) und ElevenLabs Realtime (`FlowIQCloud`), weitere ohne Umbau möglich. `PostTranscriber` heißt `PostProcessor` | M.2 |
| F3-2 | Wahl je Betriebsart: Call und Raum wählen Live-Erkenner, Nachlauf und Sprache; Diktat wählt den Nachlauf (Vorgabe an, Entscheid der Projektsteuerung), die Live-Erkennung bleibt beim Diktat lokal; Geräte wählen den Nachlauf | M.1 |
| F3-3 | Wechsel der Live-Quelle auch mitten in einer Aufnahme: Apple läuft bei Cloud-Live als Schatten mit, Übergabe wortgenau an einer Zeitmarke; Sprache nur vor dem Start | M.3 |
| F3-4 | Rückfall ohne Lücke in zwei Stufen: Wiederverbindung mit Nachsenden, sonst Übergabe an den Apple-Schatten | M.5 |
| F3-5 | Cloud-Marke an Pille und Menüleiste, solange Audio gesendet wird | M.6 |
| F3-6 | Schlüssel nur im Schlüsselbund, nur als Kopfzeile, nie in Datei, Protokoll oder URL | M.7 |
| F3-7 | Verbrauchszähler je Quelle in v1 (bisher R-063 Soll, jetzt R-101 Muss), Monatsgrenze mit lückenlosem Rückfall | M.8 |
| F3-8 | `FlowIQPost` wird `FlowIQCloud`: einziges Modul mit Netz (Realtime, Nachlauf, Schlüssel, Zähler, Richtlinie) | M.9, Anhang F |
| F3-9 | Vertrag: neue Kopfzeilen `live_quelle`, `live_wechsel`, `nachlauf_quelle`, `cloud_minuten`; Wechselzeilen kursiv; Phasen, Status, Pipeline und Zeilenmuster unverändert | M.10, Anhang L |
| F3-10 | Korrektur-Kreislauf: Fenster "Letztes Diktat korrigieren", Ersetzen im Zielfeld wenn möglich, Lernen über das bestätigte Ziel, Nachlauf nur als Vorschlagsquelle, Reparatur mit Prüfliste, Kennzahl Wiederholungsfehler | Anhang N |
| F3-11 | Die Textstufe läuft auf allen Texten: Diktat, jeder fertige Live-Beitrag beider Quellen, lokale Endfassung, Nachlauf-Ergebnis, Geräte-Transkript | N.4 |
| F3-12 | Namen allgemein: Familienregeln sind Daten im Lexikon (IQ ist eine Familie unter vielen); R-029 zählt alle Namensstellen des Goldsatzes, die früher einzeln genannten Namen nur noch als Unterzeile, Schwellen unverändert | A.7, `ABNAHME.md` |
| F3-13 | R-067 neu gefasst (Entscheid der Projektsteuerung): Diktat-Audio verlässt den Mac nur mit eingeschaltetem Diktat-Nachlauf | M.1, `ABNAHME.md` |
| F3-14 | Zeilenbudget: der Bedarf passt nicht in 9.000; Zahlen und Vorschlag für den Besitzer | E.5 |
| F3-15 | Pakete: P2c (Korrektur-Logik), P4 mit Korrekturfenster, P5 geteilt in P5a (Ablage, Nachlauf, Apple-Live) und P5b (Cloud-Live); Liste der Abnahmetests, die zu ergänzen sind | Anhang I |
| F3-16 | Streichliste: R3 Sprechform-Abgleich bleibt (Messung der Prüfung: ohne Lautabgleich behebt der Kreislauf nur 42 %); gestrichen werden R-045 Pegelregler und Pegeltest, R-061 Sammel-Nachzug, "Rohfassung einfügen" als eigener Weg (geht im Korrekturfenster auf) | Anhang K |

## Änderungen Fassung 1 zu Fassung 2

Nummern nach dem Prüfbericht (Abschnitt 11, Ä-1 bis Ä-11), dazu der Abgleich mit dem Lexikon-Konzept (L-1 bis L-6).

| Nr | Änderung | Wo |
|---|---|---|
| Ä-1 | Anhang H (Zuordnung) ersetzt durch das Abnahme-Register `ABNAHME.md`: eine Zeile je Muss- und Soll-Anforderung mit Zahl, Belegstufe, Messgeschirr; Kriterien per Prüfsumme eingefroren; alle 11 fehlenden Muss-Kriterien und die abgeschwächten (R-073) oder verschärften (R-017) Zeilen auf den Wortlaut des Registers zurückgesetzt | `ABNAHME.md`, Anhang I |
| Ä-2 | P2 rechnet nicht mehr auf dem vorbearbeiteten Rohtext der Vorgänger-App: vor P2 wird das Audio neu erkannt und als `Recognition` abgelegt; K-01 (Erkenner) fällt vor P2; Maßstab ist die eingefrorene `zaehlregel-v1`, bei Namen nie ElevenLabs | A.7, A.13, Anhang I, K-01 |
| Ä-3 | Naht `CaptureSource` im Audio-Dirigenten (Mikrofon, Desktop, Datei nur im Entwicklungsprofil), Selbsttest mit künstlicher Taste, Auswertung per Befehl aus dem Protokoll, getrennte Belegstufen App-echt und App-synth, geplante Testfenster | A.4, A.12, Anhang H |
| Ä-4 | Neue Messgröße **Anfangsverlust in ms** (Tastenereignis bis erste aufgenommene Probe) mit Zielwert p95 ≤ 40 ms; Stufe **halbwarm** im Dirigenten von Anfang an vorgesehen (Lease mit Nachhaltezeit), Einschalten nur mit Ja des Besitzers; K-17 hängt jetzt an der Messung K-04, nicht an K-02; Schwanz nach dem Loslassen fest 110 ms wie die Vorgänger-App | A.4, Anhang C, K-04, K-17 |
| Ä-5 | Leere Audios (Vorgänger-App S1) vollständig behandelt: Schreiber wird genau einmal exklusiv angelegt, **nie `eraseFile`** (Verbot in `check.sh`), späte Puffer verworfen und gezählt, Schließen auf allen Endpfaden, Prüfung Größe gegen Dauer, Journal-Ereignis `audio_lost`, Pflichttest "späte Puffer" auf allen Endpfaden, Zählung als fester Befehl; Leitsatz 2 neu gefasst | Leitsätze, A.5, A.13, Anhang G |
| Ä-6 | **Raum plus Call: ein Mikrofon für beide**, Gerät an der Pille sichtbar, Gerätewechsel gilt für beide; Rückruf-Queue getrennt von der Steuer-Queue; begrenzte Ströme für Aufnahmen mit gezähltem Überlauf; Lückenfüllung ohne 30-s-Grenze (außer Schlaf); Füllen nur bei Zeitsprung über fester Schwelle; Neustart des Desktop-Stroms; Rangfolge der Erkenner bei Knappheit (K-19); einheitliche Erkennungsfilter; Regel für den Live-Verweis bei zwei Live-Dateien; Spurwächter zweistufig | A.4, A.6, A.9, Anhang B.5 |
| Ä-7 | Profil ausfallsicher (fehlender Schlüssel heißt Entwicklung); Schreibzugriffe nur über eine Hülle mit Erlaubnisliste samt `/tmp`-Verweis; Vault-Schnappschuss je Paket; **Regel für Test-Abbilder**; R-006- und R-083-Proben in P3 bis P5; Akkord-Abbrüche getrennt gezählt; echte Fn-Taste als Restmessung in Phase 5; Signatur über Team-Kennung statt Fingerabdruck; Entwicklungsprofil registriert nie Autostart | A.1, A.3, Anhang D, E |
| Ä-8 | `budget.tsv` mit Puffergrenze je Modul und harter Zeile `GESAMT` (9.000), `check.sh` bricht ab; Zählregel festgelegt; Streichliste mit fester Reihenfolge; Budgets umverteilt (App und Werkzeug höher, sieben Module niedriger), Summe bleibt 8.500 | Kern, Anhang E.5, Anhang K |
| Ä-9 | Datenschutz: Pre-Push-Hook über die ganze Historie und Commit-Texte, private Musterliste aus Lexikon erzeugt, Autor-Adresse vor dem ersten Push (K-24), Protokoll textfrei per Schema-Test, erweiterte Netz-Verbotsliste plus Laufzeit-Netzprobe, Feldinhalt fremder Apps nur vergleichen, nie speichern | A.2, A.8, Anhang F |
| Ä-10 | Vertrag ergänzt: `pipeline`-Werte, Sprechername als Einstellung, Gerätefelder im lokalen Fall, `dauer: laufend` während live, Kennzeichen für wartenden Nachlauf, Vorfassung auch unter `archive/` suchen; **Wechsel-Checkliste** mit `final-lokal` und Skill `vorlesung-verarbeiten` | A.9, A.11, Anhang L |
| Ä-11 | Vor Tor 2 geliefert werden: R-058, R-060, R-075 (lokal gegen vorhandene ElevenLabs-Fassungen, kein Cloud-Aufruf), K-02, K-03; Torgröße für RAM ist der **Footprint** | Anhang J, `ABNAHME.md` |
| 1.3 | Belegstufen herabgesetzt, wo die Prüfung recht hat: Spike-Zeiten ohne Audio laden das Modell nicht [G nur für den Aufruf]; Finalisieren aus Fremdquelle [D]; die 245 ms der Vorgänger-App sind kein Einfügemaß | Kern, Anhang C |
| L-1 | Schutzliste über das Systemwörterbuch: kleiner Adapter in der App fragt neue Wortformen vor `process` nach (Weg A der Prüfung), die Textstufe bleibt rein | A.7, A.12 |
| L-2 | Eigene Lautfaltung statt Kölner Phonetik | A.7 |
| L-3 | Regel "englischer Stamm plus deutsche Endung" als Schutzschicht angenommen | A.7 |
| L-4 | Schwellen der Textstufe vorläufig; endgültig nur am Goldsatz-Teil "einstellen" mit neu erkanntem Rohtext; der zurückgehaltene Teil bleibt gesperrt | A.7, Anhang I |
| L-5 | Strittige Namen bestätigt der Besitzer in FlowIQs eigener Vorschlagsliste (ein Klick je Name), verfügbar ab P2 im Entwicklungsprofil | A.7, A.12, Anhang I |
| L-6 | Mengenbremse zählt nur R3-Kandidaten (sonst bricht `process(process(x)) == process(x)`); Apples Alternativen werden je Segment gespeichert, wie die API sie liefert | A.7 |

---

## Kern (eine Seite)

### Leitsätze

1. **Ein Besitzer je Ressource.** Mikrofon und Desktop-Ton gehören dem Audio-Dirigenten, jede Datei genau einem Actor, der Hauptthread nur der Darstellung.
2. **Schreiben läuft mit, Einfügen kommt nach dem Sichern.** Jeder Audiopuffer wird geschrieben, während er erkannt wird; bei einem Absturz fehlt höchstens 1 s. Jeder Text steht im Journal, bevor er eingefügt wird.
3. **Werte statt geteilter Puffer.** Audio wandert als `AudioChunk` (Werttyp, `Sendable`) zu jedem Verbraucher; kein `AVAudioPCMBuffer` wird geteilt. Der Absturz der Vorgänger-App vom 25.10. kam aus einem geteilten Puffer [C].
4. **Durchreichen ist der Normalfall.** Die Textstufe greift nur ein, wenn Quelle verdächtig, Ziel bestätigt und Übereinstimmung stark ist.
5. **Nie still.** Kein unkommentiertes `try?`, kein stilles Löschen, kein stilles Ende einer Spur, kein stiller Überlauf. Jeder Fehler geht ins Protokoll und als Marke an Pille oder Menü.
6. **Vertrag vor Neuerung.** Vault-Dateien behalten von der Vorgänger-App Namen, Schlüssel, Phasen und Zeilenformat. Neu sind nur die Endphase ohne Nachlauf und zwei Kennzeichen (Anhang A.9).
7. **Ein Programm, zwei Profile.** Dasselbe Binär läuft als FlowIQ oder als Entwicklungsprofil; im Zweifel gilt das Entwicklungsprofil.
8. **Messen ist eingebaut.** Jede Diktatphase, jeder Gerätewechsel, jeder Nachlauf trägt Zeitstempel, Footprint und CPU im eigenen, textfreien Protokoll. Abnahmezahlen kommen per Befehl aus dem Protokoll, nie von Hand.
9. **Cloud ist eine Wahl, keine Abhängigkeit.** Apple lokal läuft immer mit; was den Mac verlässt, ist eingeschaltet, sichtbar und gezählt.
10. **Einmal korrigiert, bleibt behoben.** Eine bestätigte Korrektur wirkt in jeder Betriebsart und wird als Dauerfall bei jeder Änderung mitgeprüft.

### Modulschnitt (Swift-Paket, Swift 6, Ziel macOS 26)

| Modul (Ordner unter `Sources/`) | Zweck | hängt ab von | Budget / Grenze |
|---|---|---|---|
| `FlowIQCore` | Profil, Pfade, Schreibhülle `SafeFS`, Einstellungen, Sprachwahl je Aufnahme, Belegt-Zustand, Werttypen | Foundation | 330 / 380 |
| `FlowIQLog` | textfreies Ereignisprotokoll (NDJSON, rollierend), Fehlerdatei, Fn-Zeitleiste, Footprint und CPU | Core | 300 / 340 |
| `FlowIQInput` | Tastenabgriff (CGEventTap auf eigenem Thread), Gestenautomat, globale Kurzbefehle | Core, Log | 370 / 420 |
| `FlowIQAudio` | Audio-Dirigent mit `CaptureSource`-Naht, Leases mit Nachhaltezeit, Geräte-Zustandsautomat, Spurwächter, Zeitachsen-Wächter | Core, Log | 1.020 / 1.170 |
| `FlowIQRecording` | ADTS-Schreiber (exklusiv, ohne `eraseFile`), `laufend/` mit Sperre, Umpacken mit Dauerprüfung, Abliefern, Rettung | Core, Log, Audio | 630 / 700 |
| `FlowIQSpeech` | lokale Erkennung (SpeechAnalyzer), Reservierung, Diktat-Lauf, Live-Lauf je Quelle, Datei-Lauf, Rangfolge | Core, Log, Audio | 580 / 660 |
| `FlowIQText` | Textstufe, rein und deterministisch, Spur je Eingriff, Schutzschichten, Kanon-Lexikon, Kandidaten, Bewährung | Core | 1.000 / 1.200 |
| `FlowIQInsert` | Fokusprobe, Zwischenablage mit Bereitstellung auf Abruf, ⌘V, Leerzeichen, Secure Input | Core, Log | 370 / 420 |
| `FlowIQStore` | Vault-Vertrag, Live-Datei, Phasen, Archiv, Fassungskopien, Diktat-Journal, Lexikon-Datei, Vorgänger-Lesepfad | Core, Log, Text | 630 / 720 |
| `FlowIQCloud` (bis P5 Ordner `FlowIQPost`) | einziges Modul mit Netz: ElevenLabs Realtime als `LiveRecognizer`, Nachlauf als `PostProcessor`, Warteschlange, Schlüsselbund, Verbrauchszähler, Cloud-Richtlinie, Echo-Filter | Core, Log | 500 / 570 |
| `FlowIQDevices` | Geräte-Import DVT1600 und ZEPHYR nur lesend, Journal, Ignorierliste, Uhrkorrektur, Übernahme aus der Vorgänger-App | Core, Log | 770 / 880 |
| `FlowIQ` (App) | Koordinator, Menüleiste, Pille, Einstellungen, Einrichten, Vorschlagsliste, Wort-Orakel, Selbsttest, Theme | alle | 1.600 / 1.800 |
| `flowiq-tool` (`FlowIQTool`) | `replay`, `erkennen`, `spurpruefung`, `protokoll`, `abnahme`, `vertrag`, `schutzliste`, `vorschlaege` | Core, Log, Text, Store, Audio | 400 / 460 |
| **GESAMT** | | | **8.500 / 9.000** (Z-06, bindet immer) |

Die Werte sind die heutigen aus `budget.tsv` (Stand Commit `511c65b`); Änderungen mit Begründung je Modul, Zählregel und Durchsetzung in Anhang E.5. Die Modulgrenzen sind nur Puffer und gelten zusammen mit der Gesamtgrenze. **K-33 entschieden (13.11.2026, Commit `33b40fb`):** Der Bedarf von Fassung 3 passt nicht in 9.000 (E.5: rund 9.570 Zeilen nach allen vertretbaren Streichungen). Besitzer: "so klein wie möglich, du hast Spiel"; der Assistent hat deshalb nicht die vorgeschlagenen 10.000 genommen, sondern Summe der Budgets 9.570 und harte Gesamtgrenze 9.800 (40 % unter der Vorgänger-App).

### Abhängigkeiten

```
FlowIQCore ◀── alle
FlowIQLog  ◀── alle außer Core und Text
FlowIQText ◀── Store, App, flowiq-tool          (Text kennt nur Core)
FlowIQAudio ◀── Recording, Speech, App, flowiq-tool (nur reine Teile)
Recording, Speech, Insert, Store, Post, Devices, Input ◀── App
```
Speech, Store, Post und Devices kennen einander nicht; der Koordinator verbindet sie über Schnittstellen. Jedes Modul ist ohne die anderen testbar.

### Die wichtigsten Entscheidungen

| Nr | Entscheidung | Warum (Beleg) |
|---|---|---|
| E1 | **Audio-Dirigent mit Leases.** Ein Actor öffnet ein Gerät höchstens einmal; jeder Verbraucher bekommt einen Lease mit eigenem `AsyncStream<AudioChunk>`. Rückrufe kommen auf einer eigenen Queue, Start und Stopp auf einer Steuer-Queue | geteilter Puffer führte zum Absturz der Vorgänger-App, Mikrostart im Hauptthread [C]; Muster ohne `@unchecked Sendable` baubar [T Probe 1] |
| E2 | **Kein verwerfender Vorlauf-Ring hinter dem Mikrofon,** dazu eine eigene Messgröße für den Verlust **vor** dem Mikrofon. Der Diktatstrom puffert ab dem ersten Puffer, bis der Erkenner andockt. Was vor dem ersten Puffer gesprochen wird, misst der Anfangsverlust in ms; reicht der Kaltstart nicht (p95 > 40 ms), kommt die Stufe halbwarm mit Ja des Besitzers | Der Ring der Vorgänger-App wirft ab 1,2 s die ältesten Puffer weg [C, `AudioCore.swift` 814 bis 863]. Die 81 Diktate, in denen ElevenLabs auf derselben Datei ein Anfangswort mehr hat, sind eine Restkategorie-Heuristik und eine Untergrenze nur für Verlust **hinter** dem Mikrofon [K, Nachzählung der Gegenprüfung 1.1]; Verlust vor dem ersten Puffer sieht diese Methode nie |
| E3 | **Pille ohne Wartezeit.** Der Tastenabgriff schaltet die Pille über einen einzigen Sprung in den Hauptthread; Mikrostart, Erkennung, Dateien, Bedienungshilfen, Zwischenablage laufen nie dort | Die Vorgänger-App ruft `startRunning` im Hauptthread (Hauptdatei der Vorgänger-App, Zeile 409) [C]; der Aufruf kehrt im Median nach 71 ms zurück, in 40 Diktaten höchstens nach 130 ms, gezählt ab Aufbau der Capture-Sitzung, nicht ab Tastendruck [G, Phase-1-Messung A2] |
| E4 | **Textstufe als reines Paket mit Spur,** Schutz über ein Wort-Orakel in der App, das nur Antworten liefert. Dieselbe Bibliothek läuft in der App, in Bewährungsläufen und in `flowiq-tool replay` | R-028, R-031, R-035; die Textstufen der Vorgänger-App brachten netto keinen Gewinn und speicherten keinen Eingriff [K] |
| E5 | **Vertrag exakt, Live-Datei nur anhängend,** neue Endphase `final-lokal` mit Archivierung, Kopie vor jeder Aufwertung | Die Vorgänger-App schreibt die ganze Datei je Segment neu und lässt 16,8 % auf `live-lokal` hängen [C, G] |
| E6 | **Raum plus Call teilen ein Mikrofon.** Das zuerst gewählte Gerät gilt für beide, das Gerät steht an der Pille, ein Wechsel im Menü gilt für beide | zwei gleichzeitige Capture-Sitzungen auf zwei Geräten sind ungemessen, und ein AirPods-Eingang zieht die AirPods für beide Aufnahmen in den Telefonie-Modus; der Fall ist selten, sichtbar ist besser als still [E] |
| E8 | **Apple läuft immer mit.** Bei Cloud-Live schreibt ElevenLabs, Apple läuft als Schatten; Wechsel und Rückfall tauschen nur die schreibende Quelle an einer Zeitmarke | lückenloser Rückfall und Wechsel ohne Neustart; Kosten des Schattens im Call bei der Vorgänger-App rund 2,5 % CPU im Sprachdienst [G, Phase-1-Messung A1] |
| E9 | **Korrektur über das bestätigte Ziel.** Der Kreislauf lernt zuerst das Ziel, dann Hörvarianten; der Lautabgleich fängt neue Fehlformen; der Nachlauf liefert nur Vorschläge | reines Paar-Gedächtnis behebt 42 % der wiederkehrenden Fehler, Fehlformen eines Namens wechseln (133 Fehlformen für 54 Einträge) [K, Prüfung, `local/phase2/wiederkehrende-fehler.md`] |
| E7 | **Abnahme per Messgeschirr.** Datei-Quelle und künstliche Taste im Entwicklungsprofil, Auswertung per Befehl, Rohdaten in `local/abnahme/`, im Repo nur die Summenzeile | ohne Geschirr werden 500 Diktate zu 50 oder zu einer Attrappe mit dem Etikett "App" (Prüfbericht 7) |

Dazu: **stabile Signatur** über die Team-Kennung der Apple-Development-Identität (ohne Identität seit 16.11.2026 eine Behelfssignatur je Bau, Anhang D), nie `tccutil`; **Laufzeitprüfung der Actor-Isolation bleibt an** (anders als die Vorgänger-App und Talkie, K-06).

### Zeitbudget Fn (Kurzfassung, Details Anhang C)

| Strecke | Vorgänger-App (Vergleich, Messstelle) | FlowIQ Muss | FlowIQ Ziel |
|---|---|---|---|
| Taste bis Pille sichtbar (`t0` bis `t2`) | ab Sitzungsaufbau mindestens 71 ms Median bis Hauptthread frei [G]; ab Taste nicht gemessen | p95 ≤ 50 ms, max ≤ 150 ms | p95 ≤ 25 ms |
| Anfangsverlust (Taste bis erste aufgenommene Probe) | ab Sitzungsaufbau 79 ms Median bis erster Puffer, Untergrenze [G] | p95 ≤ 40 ms kalt, sonst halbwarm | halbwarm ≤ 0 ms (Probe vor der Taste) |
| Loslassen bis Ziel-App holt ab (`t7` bis `t13`) | kein Vergleichswert: die 245 ms der Vorgänger-App enden an einem eigenen Zwischenablage-Zugriff, nicht am Einfügen [G, Gegenlesung 8.2] | Median ≤ 350 ms, p95 ≤ 800 ms (Diktate bis 30 s), ≤ 2 s bis 5 min | Median ≤ 250 ms |
| Loslassen bis ⌘V gepostet (`t7` bis `t12`, eigene Leistung) | | ausgewiesen, keine eigene Schwelle | Median ≤ 200 ms |
| Textstufe | | p95 ≤ 15 ms | p95 ≤ 5 ms |

---

## Anhang A: Module im Detail

Schnittstellen sind Skizzen [E]. Fan-out, Erkenner-Lauf und Tastenabgriff sind als Probe typgeprüft [T].

### A.1 `FlowIQCore`

- **Profil:** `enum Profile { case production, development }`. `production` gilt nur, wenn der `Info.plist`-Schlüssel `FlowIQProfile` `production` sagt **und** die Bundle-Kennung die Produktivkennung ist. Fehlt eins davon (Tests, `flowiq-tool`, falsch gebündelt), gilt `development`. Test dafür in `FlowIQCoreTests`.
- **Pfade:** `struct Paths` mit `support` (`~/Library/Application Support/FlowIQ/` bzw. `FlowIQ-Dev/`), `laufend`, `diktate`, `protokoll`, `nachlauf`, `fassungen`, `lexikon`, dazu Live-Verweis und Vault-Pfade aus den Einstellungen. Tests bekommen immer einen Temp-Ordner als Wurzel.
- **Schreibhülle `SafeFS`:** jeder Schreibzugriff (anlegen, schreiben, verschieben, kopieren, löschen, Verweis setzen, Ordner anlegen) läuft durch sie. Erlaubnisliste je Profil: Entwicklung = `support` plus genau der Dev-Live-Verweis; Produktion = `support`, die drei Vault-Ziele (`raw`, `transcripts`, Archiv) und `/tmp/panotti-live.md`. Alles andere wirft und wird protokolliert. `claimNew(url)` legt nur an, wenn der Pfad nicht existiert. `check.sh` verbietet direkte Schreibaufrufe außerhalb von `SafeFS.swift` (Heuristik, Anhang F); der Beweis ist der Vault-Schnappschuss je Paket.
- **Einstellungen:** `struct Settings: Codable, Sendable` mit Versionsfeld in `settings.json` (atomar über `SafeFS`). Felder: Mikrofon-Regel oder UID, Vault-Pfade, Live an, Nachlauf Aufnahmen, Nachlauf Geräte, Geräte an, Uhrzeit stellen (K-12), **Sprechername der Mikrofonspur** (Vorgabe: erstes Wort des Kontonamens; die Übernahme aus der Vorgänger-App setzt ihn ausdrücklich), Audio-Aufbewahrung (Vorgabe unbegrenzt, K-13), Nachhaltezeit halbwarm (Vorgabe 0, K-17). Lesefehler: Datei bleibt, Kopie `settings.unlesbar-<zeit>.json`, Vorgaben im Speicher.
- **Sprache je Aufnahme:** `RecordingLanguage` (`de-DE`, `en-US`). Menü-Vorwahl gilt nur für die nächste Aufnahme, Kurzbefehl gewinnt immer, kein gespeicherter Dauerwert (R-056, R-057).
- **Belegt-Zustand:** `actor BusyState` mit Gründen (`recording`, `import`, `post`, `dictation`), gespiegelt in `laufend/.belegt` (PID und Startzeit) für `bundle.sh`; `ThrottleGate` leitet daraus ab, wann Hintergrundarbeit laufen darf.

### A.2 `FlowIQLog`

- `EventLog`: Eingang über einen nicht blockierenden Strom, NDJSON in `protokoll/`, fünf Dateien zu je 10 MB, eigene `fehler.ndjson` (R-089).
- **Textfrei:** Ereignisse tragen Zahlen, Kennungen und Enum-Werte, nie Diktattext, nie Feldinhalt, nie Dateinamen aus dem Vault, nie Gerätenamen (nur Art plus Kurz-Hash). Ein Schema-Test lehnt Freitextfelder ab (Prüfbericht D-4).
- `FnTimeline`: Zeitstempel `t0` bis `t13` je Diktat in `mach_continuous_time` (Anhang C).
- `ResourceProbe`: **Footprint** (`phys_footprint`, das Maß der Aktivitätsanzeige) ist die Torgröße; RSS wird mitgeschrieben. Je Diktat vorher, Spitze (Abtastung alle 50 ms nur während des Diktats), nachher; CPU-Zeit. Apples Sprachdienst getrennt, soweit lesbar (R-088).
- Ereignisse für Abnahmen: `audio_lost`, `audio_verdaechtig`, `late_buffers`, `overflow`, `gap_filled`, `device_switch`, `desktop_restart`, `chord_abort`, `insert_result`, `nachlauf_state`. `flowiq-tool abnahme <paket>` wertet sie aus.

### A.3 `FlowIQInput`

- **Tastenabgriff:** `CGEventTap` (`.listenOnly`) auf eigenem Thread, auf diesem Thread erzeugt und betrieben, Griff im `Mutex` [T Probe 2]. Abgeschaltete Taps schaltet der Rückruf selbst wieder an; Sicherheitsnetz alle 30 s.
- **Taste je Profil:** FlowIQ `fn`, Entwicklungsprofil `⌥ rechts` mit Akkord-Abbruch (andere Taste während des Haltens verwirft das Diktat). Akkord-Abbrüche werden als `chord_abort` gezählt und aus allen Abnahmezahlen ausgeschlossen. Alle Fn-Zahlen der Pakete entstehen mit `⌥ rechts`; die echte Fn-Taste wird in Phase 5 nachgemessen und gilt bis dahin nicht als erfüllt.
- **Gestenautomat:** `GestureMachine`, rein, Port von der Vorgänger-App B03 mit Bounce-Schutz: Halten, Doppeltipp in 0,36 s sperrt, Taste plus Leertaste sperrt, Escape bricht ab, ⌃⌘V fügt erneut ein (R-014). Kein Zeichen wird gespeichert; gezählt wird nur "Taste seit dem Einfügen ja oder nein".
- **Kurzbefehle:** Carbon `RegisterEventHotKey`, jedes Ergebnis geprüft, "belegt" wird gemeldet. FlowIQ: ⌘⌥U Call DE, ⌘⌥R Raum DE; Englisch mit E dazu (⌘⌥ halten, E und U bzw. R gleichzeitig unten, Reihenfolge egal; der Besitzer 16.11.); dieselbe Taste stoppt, mit oder ohne E; dazu "Letztes Diktat korrigieren" ⌘⌥K (K-29, Anhang N.2). Carbon kennt keine zwei Buchstaben: registriert sind U, R, E und K mit ⌘⌥, `LanguageChord` entscheidet. Ist E schon unten, gilt sofort Englisch; kommt U oder R zuerst, wartet die Entscheidung `LanguageChord.window` (150 ms) auf ein E, sonst Deutsch. Läuft oder startet die Aufnahme dieser Art, stoppt die Taste sofort ohne Warten. ⌘⌥E ist registriert, damit E nie in die vordere App fällt; allein bewirkt es nichts. Die Live-Quelle wechselt nur noch im Menü.
- **Ausgang:** `AsyncStream<InputAction>` an den Koordinator plus direkter Pillen-Auslöser (Anhang C).

### A.4 `FlowIQAudio` (Audio-Dirigent)

```swift
public struct AudioChunk: Sendable { let hostTime: UInt64; let sampleRate: Double; let samples: [Float] }

public protocol CaptureSource: Sendable {                 // die Naht für Messgeschirr und Tests
    var kind: SourceKind { get }                          // .microphone(InputDevice), .desktop, .file(URL)
    func start(deliver: @escaping @Sendable (AudioChunk) -> Void) async throws
    func stop() async                                     // nach Rückkehr kommt kein Puffer mehr
}
public actor AudioConductor {                             // Steuer-Executor; Rückrufe auf eigener Queue je Quelle
    public func acquireMic(for purpose: MicPurpose) async throws -> MicLease
    public func acquireDesktop() async throws -> DesktopLease
    public var events: AsyncStream<AudioEvent> { get }
}
public struct MicLease: Sendable { let id: UInt64; let chunks: AsyncStream<AudioChunk>; let device: InputDevice
                                   func release(hold: Duration) async }   // hold > 0 nur mit halbwarm
```

- **Quellen:** `MicrophoneSource` (`AVCaptureSession`, 32-bit Float, mono, Sitzung bleibt konfiguriert, Start und Stopp auf der Steuer-Queue, Puffer auf eigener Rückruf-Queue), `DesktopSource` (`SCStream` nur Audio, 2 × 2 Pixel, 1 Bild je s, 48 kHz), `FileSource` (nur Entwicklungsprofil und Tests: spielt eine Datei in Echtzeit oder schneller als Chunks ab, mit künstlichen Zeitstempeln). Die Trennung von Steuer- und Rückruf-Queue verhindert, dass Puffer stauen, während `startRunning` oder ein Umbau blockiert (Prüfbericht G-4); Test: Gerätewechsel während Aufnahme verliert 0 Puffer, gezählt aus der Lückenlosigkeit der Zeitstempel.
- **Fan-out:** jeder Puffer einmal als `AudioChunk` kopiert und an alle Leases verteilt [T]. **Diktatstrom** unbegrenzt mit Sicherheitsgrenze 30 s (danach Datei-Lauf aus dem Spool). **Aufnahmeströme** begrenzt auf 30 s Audio (`.bufferingOldest`), jeder verworfene Puffer wird über das `YieldResult` gezählt und als `overflow` gemeldet (Prüfbericht G-5).
- **Halbwarm:** `release(hold:)` hält das Mikrofon N Sekunden offen; solange hält ein Ring die letzten 500 ms, ein Folgediktat beginnt mit Ton vor der Taste. Vorgabe N = 0 (aus). Einschalten nur mit Ja des Besitzers (K-17), weil die orange Anzeige dann N Sekunden länger steht. 58 % der Diktate folgen binnen 60 s auf das vorige [K, Phase-1-Messung D].
- **Geräteregel (rein):** `DevicePolicy.choose(...)`, Port von der Vorgänger-App B07: ausdrückliche Wahl gewinnt; sonst bei Bluetooth als Standard und offenem Deckel das eingebaute Mikrofon für Diktat und Raum; beim Call der Standard-Eingang; **läuft schon ein Gerät, hängt sich jeder neue Lease daran** (E6). Weicht das Gerät von dem ab, was die Regel für den neuen Zweck gewählt hätte, zeigt die Pille das Gerät als Marke und das Menü eine Zeile; ein Wechsel im Menü gilt für alle laufenden Leases.
- **Geräte-Zustandsautomat:** `idle`, `starting`, `running(device, format)`, `switching`, `lost`. Ereignisse aus Core-Audio-Beobachtern (nur lesend), Capture-Laufzeitfehlern, Deckel (IOKit `AppleClamshellState`), Schlaf und Aufwachen. Während einer Aufnahme Wechsel nur bei Verlust (Rückfall auf eingebautes Mikrofon), sonst nur per Menü. Formatwechsel (HFP 24 kHz) baut nur den Wandler neu, Dateiformate bleiben.
- **Nur lesen:** keine Abtastrate, Puffergröße oder Systemeinstellung wird gesetzt (R-044).
- **Zeitachsen-Wächter (rein):** füllt eine Lücke mit Stille, wenn der Zeitstempel um mehr als 200 ms springt, **ohne obere Grenze**, und markiert sie; Schlaf wird nicht gefüllt, nur markiert. Uhrendrift unter der Schwelle wird nie gefüllt (Drift-Fixture im Test, Prüfbericht G-6, G-7).
- **Desktop-Neustart:** endet der `SCStream` (`didStopWithError`, Sperre, Freigabe beendet), versucht der Dirigent einen Neustart nach 1, 5 und 15 s, danach jede Minute; die Spur wird bis dahin mit Stille gefüllt und markiert, die Pille zeigt die Marke erst nach dem ersten gescheiterten Versuch. Test: Strom künstlich beenden, Spur läuft weiter (Prüfbericht G-8).
- **Spurwächter (rein, zweistufig):** Mikrofon: unter -60 dBFS seit Start oder 10 s lang, Warnung an der Pille in ≤ 15 s (ein lebendes Mikrofon hört immer Raumrauschen). Desktop: digitale Stille (alle Proben 0 oder unter -90 dBFS) seit Start 10 s lang, Warnung in ≤ 15 s; digitale Stille mitten im Call erst nach 3 Minuten, solange das Mikrofon Ton hat, weil eine stumme Gegenseite oft digital still ist (Prüfbericht G-13). Schwellen werden mit `flowiq-tool spurpruefung` an handgeprüften Etiketten eingestellt (K-18), das Abnahmekriterium aus R-040 bleibt.

### A.5 `FlowIQRecording`

- **`actor TrackWriter`** mit Zuständen `open`, `closing`, `closed`:
  1. Datei genau einmal beim Start der Aufnahme anlegen, nie im Puffer-Rückruf: `SafeFS.claimNew`, dann `ExtAudioFileCreateWithURL` **ohne** `kAudioFileFlags_EraseFile`; existiert der Pfad, ist das ein Fehler, keine Überschreibung. `eraseFile` steht auf der Verbotsliste in `check.sh`.
  2. ADTS-AAC Rahmen für Rahmen (nach Absturz lesbar): Call und Raum 96 kbit/s mono (≈ 43 MB je Stunde), Diktat 64 kbit/s.
  3. Reihenfolge beim Ende: Quelle abmelden (Lease frei, nach `stop()` kommt kein Puffer mehr), Warteschlange leeren, schließen. Was nach `closing` noch ankommt, wird verworfen und als `late_buffers` gezählt, nie neu geöffnet.
  4. Schließen auf **jedem** Endpfad: normales Ende, Ende ohne Erkenner-Sitzung, Escape, Frist abgelaufen, Erkenner gescheitert, App beendet; dazu im `deinit`. Frames zählen erst, wenn sie geschrieben sind.
  5. **Prüfung Größe gegen Dauer** nach dem Schließen: unter 50 % des Nennwerts (Diktat: 4.000 Byte je s; Call und Raum: 6.000 Byte je s) heißt `audio_verdaechtig`, nur Kopf oder unter 10 % heißt `audio_lost`; beides ins Journal und an die Pille, nie Status "gesichert". Herleitung: Vorgänger-Diktate mit nutzbarem Audio liegen im Median bei 8.474 Byte je s, p0,5 bei 4.252, p1 bei 5.640 (n = 2.272) [K, `local/korpus/index.tsv`].
- `RecordingLock` (`flock` auf `laufend/.sperre`, je Profil eigener Ordner), `remuxToM4A` (löscht die `.aac` erst nach Dauerprüfung ≤ 0,5 s), `deliver` (wirft, gibt nie still die Quelle zurück), `Rescue.run` (beim Start alles aus `laufend/`, Menüzeile "n Aufnahmen gerettet").
- `RecordingSession`: hält Leases, Schreiber und Wächter einer Call- oder Raumaufnahme; die Raumdatei bekommt das unveränderte Signal (R-038).
- Plattenplatz: unter 1 GB frei Warnung, unter 200 MB sauberer Abschluss.

### A.6 `FlowIQSpeech`

```swift
public actor SpeechEngine {
    public func warmUp(_ langs: [RecordingLanguage]) async throws    // reservieren, Status
    public func dictate(_ chunks: AsyncStream<AudioChunk>) async -> DictationRun
    public func live(source: SourceID, lang: RecordingLanguage, _ chunks: AsyncStream<AudioChunk>) -> AsyncStream<RecognizedSegment>
    public func transcribeFile(_ url: URL, lang: RecordingLanguage, gate: ThrottleGate) async throws -> [RecognizedSegment]
}
```

- **API-Stand:** Laufzeit macOS 26.7.1, Bau mit Xcode 27.2, SDK macOS 27.2, Swift 6.4.2 [G]. Schnittstellen mit `@available(anyAppleOS 27, *)` sind verboten (`AnalyzerInputConverter`, Eingabe aus `CMReadySampleBuffer`, `Options.ignoresResourceLimits`) [C].
- **Reservierung:** `AssetInventory.reserve(locale:)` für de-DE und en-US beim Start (sonst Warnung "unallocated locales", künftig Fehler) [G, Spike 1]. Download nur im Einrichten, nie beim Tastendruck.
- **Erkenner fürs Diktat** hinter `RecognizerProfile`: `.speech` (`SpeechTranscriber`) oder `.dictation(customLM:)` (`DictationTranscriber`; nur dieser Weg nimmt ein eigenes Sprachmodell mit Aussprachen an [C]). Die Wahl fällt in K-01 **vor P2**, am neu erkannten Goldsatz-Teil "einstellen" mit allen Varianten, und schließt eine Netzprobe ein: der gewählte Weg darf während Diktaten keine Verbindung nach außen öffnen (R-067, Prüfbericht D-6). Der zweite Erkenner-Typ steht auf der Streichliste, falls K-01 ihn nicht braucht.
- **Vorbereitung:** `prepareToAnalyze` ohne Audio kostete 32 bis 137 ms, **lädt das Modell aber nicht wirklich** [G für den Aufruf, Spike 1 und 2]. Ob ein vorbereiteter Standby-Analyzer etwas bringt und was er kostet, misst K-04. Bis dahin gilt: Analyzer wird beim Tastendruck vorbereitet, das Audio wartet im Diktatstrom.
- **Ende des Diktats:** Schwanz fest 110 ms (Garantie M06), dann 160 ms Stille, `finalizeAndFinishThroughEndOfInput()` mit Frist 1,35 s; bei Ablauf `cancelAndFinishNow()` und Datei-Lauf über die Spool-Datei. Wie lange Finalisieren dauert, ist für FlowIQ nicht gemessen (Fremdwert 47 bis 49 ms bei 15,6 s [D]); es geht als `t9` ins Protokoll.
- **Live ab Fassung 3:** `AppleLiveRecognizer` setzt die Schnittstelle `LiveRecognizer` um (Anhang M.2); der reine `LiveRouter` in diesem Modul führt Apple und eine Cloud-Quelle zusammen (Schatten, Übergabe an einer Zeitmarke, M.3). Das Modul bleibt netzfrei.
- **Live:** genau ein Erkenner je Quelle und Sprache; Raum und Call auf demselben Mikrofon teilen ihn. Alle 3 s `finalize(through:)` bis 1 s vor jetzt, damit Sätze nach rund 4 s fest sind [C, API]. Rotation alle 10 Minuten an einer festgeschriebenen Grenze.
- **Erkennungsfilter (einheitlich):** alle Mikrofon-Erkenner bekommen dieselbe Kette, Vorgabe nur Hochpass 80 Hz; Pegelregelung nur, wenn die Korpus-Wiedergabe Gewinn zeigt (K-22). Dateien bekommen nie Filter. Damit kann ein geteilter Erkenner Raum und Call bedienen (Prüfbericht G-11).
- **Rangfolge bei Knappheit** (K-19 misst, wie viele Analyzer macOS 26 gleichzeitig trägt): Aufnahme-Schreiben nie betroffen; Diktat vor Live; Live vor Import und Nachlauf-Vorbereitung. Ein gescheiterter Live-Erkenner beendet nie eine Aufnahme, er wird als Marke gemeldet und neu versucht.
- **Ausgabe neutral:** `Recognition` mit Text, Tokens (Text, Zeitbereich, Sicherheit) und den Alternativen **je Segment, so wie die API sie liefert** (`Result.alternatives` ist eine Liste ganzer Segmenttexte [C]); eine Zuordnung auf einzelne Wörter rechnet erst die Auswertung.

### A.7 `FlowIQText` (Textstufe)

Fachliche Vorlage ist das Lexikon-Konzept (privat, `local/phase2/LEXIKON-KONZEPT.md`); die Gegenprüfung hat es auf Machbarkeit geprüft (`local/phase2/pruefung-lexikon-opus.md`). Hier steht, wie es in das Modul passt.

```swift
public struct TextStage: Sendable {
    public init(lexicon: LexiconSnapshot, protection: FrozenWordSet, config: TextStageConfig)
    public func oracleQueries(for input: Recognition) -> Set<OracleQuery>          // welche Wortformen unbekannt sind
    public func process(_ input: Recognition, answers: OracleAnswers) -> TextStageResult  // rein, deterministisch
}
public struct TextStageResult: Sendable, Codable { let text: String; let interventions: [Intervention]
    let nearMisses: [NearMiss]; let stageTexts: [String]; let micros: Int }
public struct CandidateDetector: Sendable { public func candidates(in history: [JournalView]) -> [Candidate] }
public enum Probation { public static func evaluate(_ v: HearingVariant, over history: [JournalView]) -> ProbationVerdict }
```

- **Ablauf in `process`:** (1) Normalisieren: nur Zögermarken und Steuerreste des Erkenners (`\letter`). (2) Schützen je Token. (3) Abgleich von links, längste Spanne zuerst: bestätigte Hörvariante, R1 Formvariante, R2 Familie (Familienregeln sind Daten im Lexikon: Anker plus Stämme der bestätigten Mitglieder; IQ ist eine Familie unter vielen, der Code kennt keinen Anker), R3 Sprechform. (4) Zusammensetzung Z1 (Z2 aus). (5) Mengenbremse, Spur. Keine Grammatik-Glättung, keine Stotter-Entfernung, kein Wort-auf-Wort ohne bestätigten Eintrag.
- **Schutz in drei Schichten:** P1 Systemwörterbuch, P2 vertraute Wortformen (Goldsatz, Klick "richtiges Wort", unentschiedene Kandidaten, Einträge selbst), P3 regelhaft Gebildetes: Zusammensetzung aus zwei geschützten deutschen Teilen; **englischer Stamm plus deutsche Endung** (`-en -e -t -st -te -ten -et`, auch `ge-` plus Stamm plus `-t`/`-et`), Stamm mindestens 4 Buchstaben und im englischen Wörterbuch bekannt (L-3, schützt genau die Klasse, die die Vorgänger-App zerschossen hat). Im Zweifel geschützt.
- **Wort-Orakel (L-1, Entscheid zu Weg A der Prüfung):** `FlowIQText` fragt nie selbst ein Wörterbuch. `oracleQueries(for:)` nennt die noch nie gesehenen Wortformen samt der P3-Stämme, die geprüft werden müssen (klein und mit großem Anfangsbuchstaben, nie in Großbuchstaben, weil `NSSpellChecker` jede Großbuchstabenfolge als richtig meldet [T, Lexikon-Konzept 2.2]). Die App beantwortet sie über `SystemWordOracle` (eine Datei, eigene serielle Queue, nie Hauptthread, Frist 5 ms je Diktat, bei Fehler oder Fristablauf "geschützt"), übergibt die Antworten an `process` und hängt sie an die eingefrorene Menge `FrozenWordSet` an. Damit bleibt die Textstufe rein und wiederholbar: gleiche Eingabe, gleiche Antworten, gleicher Text. Aufwand: im Mittel 2,3 neue Formen je Diktat, 95 % höchstens 8, 0,10 bis 0,11 ms je Wort und Sprache [T, Lexikon-Konzept]. `check.sh` erlaubt `NSSpellChecker` genau in `Sources/FlowIQ/SystemWordOracle.swift` und in `FlowIQTool`.
- **Abkürzungsschutz:** reine Großbuchstabenfolgen bis 5 Zeichen ohne Ziffer sind nie R3-Quelle; Einträge der Art Abkürzung nur über die Buchstabier-Lesart erreichbar.
- **Lautfaltung (L-2):** eigene, feste Faltungstabelle (deutsche Lautklassen, Vokale bleiben als Klassen erhalten) mit gewichtetem Editierabstand (Vokal 0,5, Konsonant 1,0), Ziffern und Einzelbuchstaben deutsch und englisch ausgesprochen. Kölner Phonetik wird nicht portiert: sie wirft Vokale weg und liefert nur einen Code, keinen gewichteten Abstand.
- **Mengenbremse (L-6):** zählt nur R3-Kandidaten (mehr als 6 oder R3-Spannen über 15 % der Tokens: alle R3 dieses Diktats entfallen). Zählte sie alle Eingriffe, würde ein zweiter Durchlauf nach angewandten R1-Eingriffen die R3 wieder zulassen und die Idempotenz brechen. Eigenschaftstest `process(process(x)) == process(x)`.
- **Schwellen (L-4):** alle Werte in `TextStageConfig` mit Versionsnummer sind **vorläufig**. Sie wurden am Vorgänger-Rohtext eingestellt, der schon von der ersten Textstufe der Vorgänger-App bearbeitet ist, und an allen Diktaten geprüft. Endgültig eingestellt werden sie nur am Goldsatz-Teil "einstellen" (`local/korpus/goldsatz/referenz-einstellen.jsonl`, 239 Diktate) mit Rohtext, der neu aus dem Audio erkannt ist, mit dem nach K-01 gewählten Erkenner. Der zurückgehaltene Teil (159 Diktate) liegt gesperrt in `local/korpus/tresor/` und bleibt beim Entwickeln zu; er wird einmal bei der Abnahme gelesen. Jede Schwellenänderung braucht einen Vorher-Nachher-Lauf.
- **Strukturbefehle** ("neue Zeile", "neuer Absatz") entfallen in v1: 0 Vorkommen in Roh-, End- und ElevenLabs-Text der 2.500 Diktate [K].
- **Lernen mit Bremse:** Einträge und Schreibweisen nur per Klick. Kandidaten aus wiederkehrenden Nichtwörtern, Familienmustern, Beinahe-Treffern und (einmalig) den Regeln der Vorgänger-App, deren Ziel ein bestätigter Eintrag ist. Hörvarianten starten in Bewährung; `Probation.evaluate` ist rein, die App lässt sie im Leerlauf mit niedriger Priorität über das Journal laufen (Nutzen mindestens 2 Treffer in 2 Diktaten, kein Treffer auf Geschütztem, keine Ablehnung); der stärkere Lauf mit Goldsatz läuft in `flowiq-tool replay`. Erstes Rückgängig legt still.
- **Bestätigung strittiger Namen (L-5):** nur in FlowIQs eigener Vorschlagsliste (A.12), ein Klick je Name, nie als Liste im Chat. Die Antworten wirken im Lexikon und werden für den Goldsatz exportiert (A.13 `vorschlaege`).
- **Grenzen:** p95 ≤ 15 ms (R-036), keine Regex je Diktat, keine Ein-Ausgabe, 1.200 Zeilen Grenze; R3 wird nur gebaut, wenn der Drei-Wege-Lauf auf neu erkanntem Audio seinen Mehrwert zeigt (Streichliste).

### A.8 `FlowIQInsert`

- Eigene serielle Queue, nie Hauptthread: (1) Fokusprobe über Bedienungshilfen (Frist 50 ms); nur ein lesbares Nicht-Textfeld verhindert das Einfügen, ein unlesbares Feld (Electron, Web) wird eingefügt. (2) Alte Zwischenablage vollständig sichern. (3) Text als **Bereitstellung auf Abruf** schreiben (`NSPasteboardItem` mit Datenlieferant, Kennung "vorübergehend"); ruft die Ziel-App die Daten ab, ist das `t13` und der Beweis, dass eingefügt wurde [E, K-07]. (4) ⌘V posten (`t12`). (5) Alte Zwischenablage zurück, sobald die Daten abgeholt sind plus 100 ms, oder nach 2 s ohne Abruf; nur wenn `changeCount` seit dem eigenen Schreiben gleich ist.
- Ergebnis: `landed` (abgeholt, bei lesbarem Feld zusätzlich bestätigt), `notFetched`, `noTextFocus`, `secureInput`, `failed`. Nur `landed` zählt als eingefügt; sonst bleibt der Text über ⌃⌘V abrufbar und die Pille zeigt "nicht eingefügt" (R-019).
- **Feldinhalt fremder Apps** wird nur verglichen, nie gespeichert und nie protokolliert (Test, Prüfbericht D-7).
- Leerzeichenlogik Port B36, Secure-Input-Erkennung Port B35, "Rohfassung einfügen" (Menüpunkt): nur wenn die Ziel-App noch vorne ist und seit dem Einfügen keine Taste kam, dann ⌘Z und Erkennertext einfügen; zählt als Ablehnung aller Eingriffe dieses Diktats. Kein Systemton, kein Fenster nach vorn.

### A.9 `FlowIQStore` (Ablage)

- **Vertrag als reine Funktionen:** Dateinamen `YYYY-MM-DD-HHMM-call.md` und `-raum.md` mit Suffix `-2`; Geräte `...-raum-dvt1600-<orig>-<sha8>.md` und `...-raum-zephyr-<sha8>.md`; Neufassung `-erneut-<n>.md` mit `neufassung_von:`; vor jedem neuen Namen wird auch unter `transcripts/archive/` nach gleichem Namen und gleicher Vorfassung gesucht (Garantie M11). Rohordner `YYYY-MM-DD HH-mm-ss Call/` mit `<stamp> mikrofon.m4a` und `<stamp> desktop.m4a`, Raum `YYYY-MM-DD HH-mm-ss raum.m4a`. Beitragszeile `**[MM:SS] Sprecher:** Text`, ab einer Stunde `HH:MM:SS`.
- **Kopfzeilen** in der Reihenfolge der Vorgänger-App. Ergänzt und festgelegt:

| Schlüssel | Wert |
|---|---|
| `panotti_phase` | `live-stream`, `live-lokal`, `recovered-wal`, `final-elevenlabs`, neu `final-lokal` (Name K-11) |
| `pipeline` | Call und Raum: `panotti-live`, nach Nachlauf `panotti-live+elevenlabs-scribe-v2`, Endphase lokal `panotti-live+lokal`; Geräte: `dvt1600-import+elevenlabs-scribe-v2` bzw. `dvt1600-import+lokal`, ZEPHYR entsprechend |
| `dauer` | während `live-stream` der Wert `laufend` (Schlüssel vorhanden, Datei bleibt nur anhängend), ab Stopp `MM:SS` bzw. `HH:MM:SS` |
| `sprache` | echte Sprache der Aufnahme; Call und Raum `de`/`en`, Geräte wie bisher dreistellig `deu`/`eng` |
| Sprecher | Mikrofonspur: Sprechername aus den Einstellungen (Übernahme aus der Vorgänger-App setzt den bisherigen Wert); Desktop `Gegenseite`; Raum `Raum` |
| Gerätefelder lokal | `sprecher_erkannt: 1`, `wort_konfidenz_mittel` aus Apples Sicherheit, `aktive_sprechzeit` aus den Token-Zeitbereichen, `qualitaet_status` aus lokalen Prüfungen |
| `nachlauf` (neu) | `wartet`, `angehalten` (Kontingent oder Schlüssel), `aus`; fehlt nach Erfolg. Macht "wartet" für Abnehmer von "hängt" unterscheidbar (Prüfbericht 9) |

- **`actor LiveTranscript`:** Kopfzeilen beim Start einmal geschrieben; fertige Beiträge nur angehängt; höchstens eine kursive Schlusszeile "spricht gerade" wird per Kürzen und Anhängen ersetzt. Prüfregel: der Text bis vor die flüchtige Zeile ist in jedem Stand Anfang des nächsten (R-053). Journal `laufend/live-<id>.jsonl` für die Rettung.
- **Live-Verweis:** `/tmp/panotti-live.md` bzw. `/tmp/flowiq-dev-live.md`, gesetzt per neuem Verweis und atomarem Umbenennen. Bei zwei Live-Dateien zeigt er auf die zuletzt gestartete; endet sie, zurück auf die noch laufende (Prüfbericht G-12).
- **Stopp und Endphasen:** Stopp schreibt die Datei einmal ganz (`unverarbeitet`, `live-lokal`, `dauer`). Nachlauf an: Kopie der lokalen Fassung nach `fassungen/` im Datenordner, dann `final-elevenlabs`. Nachlauf aus: `final-lokal`. In beiden Fällen wandert das Audio aus `raw/` ins Archiv.
- **Diktat-Journal:** `diktate/<jahr>/<monat>/<id>.aac`, `diktate/journal-YYYY-MM.jsonl`, nur anhängend, nie gekürzt (R-022, R-023). Ereignisse `begin`, `audio` (Bytes, Dauer, Ergebnis der Größenprüfung), `audio_lost`, `recognized` (Felder wie Lexikon-Konzept Abschnitt 5: Erkennertext vor jeder Stufe, Tokens, Segment-Alternativen, Versionen, Orakel-Antworten, Eingriffe, Beinahe-Treffer, Endtext, Laufzeit), `inserted`, `retry`, `reject`. Schreiben vor dem Einfügen per `write` ohne `fsync` (übersteht einen App-Absturz), `fsync` gebündelt danach. Das Journal liegt im Datenordner und ist privat; das Protokoll (A.2) bleibt textfrei.
- **Vorgänger-Lesepfad:** Decoder für `diktat-history.json` und `vocabulary.json` (nur Lesen).
- **Lexikon-Datei:** `LexiconStore` (`lexikon.json`, `vorschlaege.json`, eingefrorene Wortmenge), liefert Schnappschüsse an die Textstufe und höchstens 100 bestätigte Begriffe an den Nachlauf.
- **Ab Fassung 3:** jeder fertige Live-Beitrag geht vor dem Anhängen durch die Textstufe (Anhang N.4); neue Kopfzeilen `live_quelle`, `live_wechsel`, `nachlauf_quelle`, `cloud_minuten` und kursive Wechselzeilen nach Anhang M.10; das Kontobuch des Korrektur-Kreislaufs liegt im `LexiconStore` (N.3).
- **Diktat in Live-Datei:** Diktat während Call oder Raum wird als Beitrag angehängt (R-024), Sprecher mit Zusatz `(Diktat)` (K-16).

### A.10 `FlowIQCloud`, Teil Nachlauf (bisher `FlowIQPost`)

Ab Fassung 3 ist der Nachlauf ein Teil von `FlowIQCloud` (Anhang M.9), die Schnittstelle heißt `PostProcessor`. Der Nachlauf ist je Betriebsart schaltbar, auch für Diktate (M.1); sein Ergebnis geht durch die Textstufe (N.4) und liefert Vorschläge für den Korrektur-Kreislauf (N.3).


- Schnittstelle `PostProcessor`, eine Umsetzung `ElevenLabsBatch`, eine Attrappe für Tests, kein Erweiterungssystem.
- **Warteschlange** dauerhaft in `nachlauf/warteschlange.jsonl`; Auslöser Stopp, App-Start, Netz zurück (`NWPathMonitor` nur solange etwas wartet), Klick. Wartezeiten 1, 5, 15, 60 Minuten, dann stündlich; Kontingent leer oder Schlüssel fehlt: angehalten bis Klick oder nächster Tag, Kennzeichen `nachlauf:` in der Datei, immer sichtbar.
- Hochladen als Datei-Strom; Call als zwei Spuren, danach Echo-Filter (Port B51). Begriffsliste nur aus bestätigten Einträgen, höchstens 100; der Aufklapper in den Einstellungen sagt, dass diese Namen an den Dienst gehen (Prüfbericht D-10).
- Zwei Schalter (Aufnahmen, Geräte), Sammel-Nachzug (Soll), Zähler je Quelle und Monat im Protokoll (Soll).
- Schlüssel nur im Schlüsselbund, eigener Dienstname je Profil, Übernahme aus Datei nur auf Klick.
- **Grenzen:** kein Codepfad lädt Diktat-Audio hoch; Netzzugriffe kommen nur in diesem Modul vor (Verbotsliste Anhang F); Beenden wartet nie auf den Nachlauf.

### A.11 `FlowIQDevices` (Geräte-Import)

- Erkennung über Einhängen plus Geräteprofile (Volume-UUID, SCSI-Kennung, Format) in `geraete.json` im Datenordner, nie im Code.
- Ablauf je Datei: Stabilitätsprüfung, Schnellfingerabdruck, 64-KB-Stromkopie mit SHA-256 und `F_NOCACHE`, Gegenprüfung, WAV-Kopf-Reparatur beim ZEPHYR, atomare Ablage über `SafeFS`, Journal je Phase. Identität nur über SHA-256 plus Größe.
- **Nur lesen auf dem Gerät:** kein Verschieben, Umbenennen, Löschen in v1; einzige mögliche Schreibstelle ist `Time.txt` des DVT1600 (K-12). Zeitkorrektur beim Import.
- Transkription lokal per `transcribeFile`; Nachlauf nur mit Geräte-Schalter. Ablage über Store mit Geräte-Namensmuster und Suche unter `archive/`.
- Drosselung über `ThrottleGate`; Fortschritt als Ereignis für den Ring an der Pille.
- **Übernahme aus der Vorgänger-App:** liest aus einem gewählten Ordner Journal, Ignorierliste, Einstellungen (als Datei gewählt, keine fremde Bundle-Kennung im Code), ZEPHYR-Versatz und Sprechername; Trockenlauf zeigt die Zuordnung, dann ein Klick.
- **Regel für Test-Abbilder:** ein Test-Abbild heißt nie `DVT1600`, `ZEPHYR` oder `NO NAME` und bildet nie die Ordnerstruktur oder die Dateinamen der echten Geräte nach (die Vorgänger-App erkennt den Stift auch über Volume-Name plus Ordner-Signatur und importiert beim Einhängen mit Nachlauf und Ablage im Vault [C, `ExternalRecorder.swift` 297 bis 298]). Das Skript `testgeraet.sh` (Skript nicht im Repo) legt Abbilder nur als `FLOWIQTEST` an, verweigert jeden der drei Namen grundsätzlich und hängt kein Abbild ein, solange die Vorgänger-App läuft und der Name auch nur einem Geräteprofil ähnelt. Erkannt wird das Abbild im Entwicklungsprofil nur über seine eigene UUID.
- Schalter aus: kein Beobachter aktiv. Im Entwicklungsprofil sind echte Geräteprofile fest aus.

### A.12 `FlowIQ` (App)

- **Koordinator:** `actor FlowCoordinator` mit Zustandsautomat der Betriebsarten (`idle`, `dictating`, `recording(call|room)`, Kombinationen, `importing` als Nebenzustand); UI-Zustände als Strom an ein `@MainActor`-Modell. Seit 16.11. (Besitzer) fragt keine Pille mehr nach: ein Klick auf die Spalte öffnet das Menü, Stoppen geht über das Menü ("Call beenden", "Raum beenden") oder dieselbe Taste, ohne Nachfrage. Nur das Beenden der App bei Aufnahme, Import oder Nachlauf fragt nach (R-050). Abweichung von der Vorgänger-App bewusst: keine 120-s-Notbremse beim Beenden, weil der Nachlauf in der dauerhaften Warteschlange überlebt und Aufnahmen in höchstens 2 s schließen (Garantie M08 ersetzt).
- **Menüleiste:** `NSStatusItem` mit `NSMenu` (AppKit, wenig Speicher). Bei Aufnahme ändert sich nur das Symbol, Laufzeit im Menü (R-051). Einträge: Call DE, Call EN, Raum DE, Raum EN (Start oder Stopp), Sprache der nächsten Aufnahme, Mikrofon, Live-Transkript zeigen, letzte Aufnahme im Finder, Vorschläge (n), letztes Diktat erneut, Rohfassung einfügen, Nachlauf Aufnahmen und Geräte, Warteschlange (n), Verbrauch je Quelle (ausklappbar), Einstellungen, Beenden.
- **Pille:** nicht aktivierendes `NSPanel` (wird nie Key, alle Spaces, `animationBehavior = .none`), beim Start einmal angelegt und über Ebenen-Deckkraft geschaltet, gezeichnet mit `CALayer`. Stand 16.11. (Besitzer, Vorlage `local/design/pille-neu.html`): drei schmale Pillen ohne Symbole und ohne Text in einer festen Spalte am linken Rand, Call oben, Diktat in der Mitte (immer sichtbar, Umriss in Ruhe, rot beim Diktat, weißer Punkt bei freihändig), Raum unten. Einzige Schrift: "EN" für 5 s nach einem Englisch-Start. Ein Problem färbt die betroffene Pille orange, der Grund steht nur im Menü. Nach dem Stopp füllt sich am Platz der Pille ein Kreis bis gespeichert; der Geräte-Import zeigt denselben Kreis neutral neben der Diktat-Pille. Marken, Karten, Nachfrage und Erinnerungstexte gibt es nicht mehr.
- **Hinweise im Menü (16.11.):** alles, was die Pille nicht mehr sagt, steht oben im Menü. Hinweiszeilen (`AppAlert`): Zeile 1 was los ist, Zeile 2 der eine Schritt, ein Klick führt ihn aus. Reihenfolge nach Dringlichkeit (`AppAlert.rank`): Aufnahme verliert Ton, dann fehlende Rechte und Tasten, dann Gescheitertes (Diktat nicht erkannt mit "Erneut erkennen", Geräte-Import mit "Erneut versuchen", Live-Text, Netz, Ordner, Schlüssel), dann Wartendes (genauere Fassung, Diktat ohne Textfeld, Schlaf-Pause einer Aufnahme). Darunter Infozeilen ohne Warnfarbe für das, was gerade läuft (`AppModel.activity`): Diktat freihändig, Start, Speichern, genauere Fassung, Geräte-Import mit Anteil; je laufender Aufnahme Laufzeit und Fakten (Gerät, bei Raum plus Call "Mikrofon mit Call geteilt", Live-Quelle). Orange an der Pille gibt es nur mit einer Hinweiszeile im Menü.
- **Einstellungen:** SwiftUI in einem `NSWindow` 440 × 520 pt, drei Bereiche (Aufnahme, Wörter, Geräte; Geräte nur sichtbar, wenn an), Erklärungen nur hinter Aufklappern, Schriftgrößen 11, 12, 14 pt aus `FlowIQTheme`, DM Sans gebündelt.
- **Einrichten:** eine Liste der nötigen Berechtigungen (Mikrofon, Bedienungshilfen, Eingabeüberwachung, Bildschirmaufnahme "nur für Calls", Spracherkennung nur falls K-05 sie verlangt), je Knopf und Haken, Stand neu gelesen beim Aktivieren der App; Ordnerwahl nur, wenn der Zielordner fehlt.
- **Vorschlagsliste (Bereich "Wörter"), ab P2 im Entwicklungsprofil:** je Vorschlag die gehörten Formen mit Anzahl, ein Schreibvorschlag (nie aus ElevenLabs), ein Feld zum Ändern und vier Knöpfe: "Name, so schreiben", "gehört zu <Eintrag>", "richtiges Wort", "nicht mehr fragen". Ein Klick je Name. Nie Dialog, nie während eines Diktats, höchstens ein Hinweis am Tag. Der Bereich wird vorgezogen, damit der Besitzer die strittigen Namen des Goldsatzes vor Tor 2 in FlowIQ selbst bestätigt (L-5); P7 gibt ihm nur noch die endgültige Form. Ab Fassung 3 trägt der Bereich auch die Prüfliste der Reparatur und die Vorschläge aus dem Korrektur-Kreislauf (Anhang N); das Korrekturfenster selbst ist ein eigenes kleines Fenster (N.2).
- **Ab Fassung 3:** Wahl je Betriebsart und Cloud-Marke (Anhang M.1, M.6), Fenster "Letztes Diktat korrigieren" (N.2), Liste "Zum Prüfen" (N.5).
- **`SystemWordOracle`:** eine Datei, die einzige Stelle mit `NSSpellChecker` in der App (A.7).
- **Selbsttest (nur Entwicklungsprofil):** auf eine verteilte Mitteilung von `flowiq-tool abnahme` hin postet FlowIQ Dev künstliche `⌥ rechts`-Ereignisse, schaltet die Mikrofonquelle auf `FileSource` mit vorbereiteten Dateien (künstliche Sprache per `say`) und fügt in TextEdit ein. Läuft nur, wenn `laufend/` der Vorgänger-App keine Datei jünger als 60 s hat (nur `stat`, nie lesen) und die Last unter 20 liegt. Ohne Lautsprecher-Wiedergabe, damit nichts in eine laufende Vorgänger-Aufnahme gelangt.
- **Autostart** (`SMAppService`, K-14) nur im Produktivprofil; das Entwicklungsprofil registriert sich nie.
- Fenster `.accessory`, `.regular` nur bei offenem Fenster; App Nap über `beginActivity` verhindert.

### A.13 `flowiq-tool`

- `erkennen --audio <ordner> --erkenner <profil> --aus <ordner>`: erkennt die Diktat-Audios der Datenkopie neu und legt je Diktat eine `Recognition` ab (Voraussetzung für P2, Ä-2). Läuft nur ohne wachsende Vorgänger-Aufnahme und unter Last 20.
- `replay`: Drei-Wege-Tabelle auf neu erkanntem Rohtext (Durchreichen = neu erkannt, Vorgänger-App = gespeicherter Endtext, FlowIQ = `TextStage`), Zählregel `zaehlregel-v1` mit Prüfsumme, Teil `einstellen` beim Entwickeln, Teil `zurueckgehalten` nur bei der Abnahme; N je Kennzahl in der Ausgabe.
- Die Wortausrichtung liegt ab Fassung 3 als `PairAligner` in `FlowIQText` (Anhang N.3), das Werkzeug ruft sie nur.
- `spurpruefung`, `protokoll` (Wochenzahlen, 0-Byte-Anteil, Bytes je s, Überläufe, späte Puffer), `abnahme <paket>` (wertet das Protokoll gegen `ABNAHME.md` aus, Rohdaten nach `local/abnahme/<paket>/`), `vertrag`, `schutzliste`.
- `vorschlaege --import <datei>` füllt die Vorschlagsliste des Entwicklungsprofils (strittige Namen, Regel-Kandidaten der Vorgänger-App); `--export` schreibt Klicks des Besitzers für den Goldsatz zurück nach `local/`.

---

## Anhang B: Datenflüsse

### B.1 Diktat (Leerlauf)

1. Taste gedrückt: Abgriff-Thread, Gestenautomat ergibt `start`; Pillen-Auslöser schaltet die rote Pille. Sonst nichts im Hauptthread.
2. Koordinator: Diktat-ID, `BusyState`, Journal `begin`.
3. Dirigent: `acquireMic(.dictation)`; im Leerlauf Gerät nach Regel, sonst das laufende Gerät; Start auf der Steuer-Queue.
4. `TrackWriter` wird angelegt (exklusiv), bevor der erste Puffer verteilt wird. Jeder Puffer geht an Schreiber, Diktatstrom und Pegel.
5. Analyzer wird vorbereitet und dockt an; der Strom hält das Audio bis dahin.
6. Taste losgelassen: Schwanz 110 ms, Lease frei (danach kein Puffer mehr), Schreiber schließen mit Größenprüfung, 160 ms Stille, Finalisieren mit Frist.
7. Orakel-Fragen, Antworten, `TextStage.process`; Journal `recognized` per `write`.
8. Einfügen mit Bereitstellung auf Abruf; Ergebnis ins Journal; Pille aus oder Marke.
9. Hintergrund: `fsync`, `FnTimeline`, Bewährung im Leerlauf.

### B.2 Call (⌘⌥U Deutsch, ⌘⌥ mit E und U Englisch)

1. Kurzbefehl im Hauptthread, sofort weiter an den Koordinator; Sprache aus dem Kurzbefehl (gewinnt gegen die Menü-Vorwahl).
2. Bildschirmaufnahme-Recht prüfen (erst beim ersten Call fragen). `RecordingLock`, `BusyState` plus `recording`.
3. `acquireMic(.call)` (Standard-Eingang, also die AirPods, wenn der Call sie nutzt; läuft schon ein Gerät, dieses, siehe B.5) und `acquireDesktop()`.
4. Zwei `TrackWriter` in `laufend/<stamp> Call/`, exklusiv angelegt, je mit Spurwächter und gemeinsamem Zeitachsen-Wächter; Aufnahmeströme begrenzt, Überlauf gezählt.
5. Live: je Quelle ein Erkenner in der gewählten Sprache; Segmente durch den Echo-Filter, dann `LiveTranscript.append` mit dem Sprechernamen der Mikrofonspur und `Gegenseite`. Live-Verweis gesetzt.
6. Endet der Desktop-Strom, Neustart nach A.4, Spur bis dahin mit Stille gefüllt und markiert.
7. Stopp (Kurzbefehl, Menü, Pille mit Nachfrage): Schreiber schließen mit Größenprüfung, umpacken mit Dauerprüfung, Ordner nach `raw/` abliefern, Live-Datei auf `live-lokal` mit `dauer`.
8. Nachlauf an: Auftrag in die Warteschlange (`nachlauf: wartet`); bei Erfolg Kopie der lokalen Fassung, dann `final-elevenlabs`, dann Archiv. Nachlauf aus: `final-lokal`, dann Archiv.

### B.3 Raum (⌘⌥R Deutsch, ⌘⌥ mit E und R Englisch)

Wie B.2 mit einer Mikrofonspur `... raum.aac` und ohne Desktop; Geräteregel wie beim Diktat (eingebautes Mikrofon bei offenem Deckel). Die Datei bekommt das unveränderte Signal; der Erkenner bekommt die einheitliche Filterkette (A.6). Sprecher `Raum`.

### B.4 Geräte-Import

1. Einhängen, Profil passt (UUID und SCSI), Schalter an. Test-Abbilder nur nach der Regel in A.11.
2. Kandidaten gegen Journal und Ignorierliste (SHA-256 und Größe); neue Dateien in die Importliste.
3. Je Datei an `ThrottleGate`: Stabilitätsprüfung, Stromkopie mit SHA-256, Gegenprüfung, Journal `kopiert`; Ring an der Pille zeigt den Anteil.
4. Lokale Transkription (`transcribeFile`, `.background`, pausiert bei Diktat), Vault-Datei mit Geräte-Namensmuster nach Suche unter `archive/`, Journal `transkribiert`; Ring pulsiert.
5. Nachlauf nur mit Geräte-Schalter; WAV ins Archiv; Journal `fertig`; Ring verschwindet.
6. Auf dem Gerät wird nichts verändert (einzige mögliche Ausnahme `Time.txt` nach K-12).

### B.5 Gleichzeitigkeit

| Fall | Ablauf |
|---|---|
| Diktat während Call oder Raum | Der Diktat-Lease hängt sich an das laufende Gerät; kein zweites Öffnen, kein Wechsel. Ergebnis wird eingefügt und als `(Diktat)`-Beitrag angehängt |
| Raum plus Call (E6) | Ein Mikrofon für beide: das Gerät der zuerst gestarteten Aufnahme. Weicht es von der Regel des zweiten Zwecks ab (Raum läuft auf dem eingebauten Mikrofon, Call würde die AirPods nehmen, oder umgekehrt), zeigt die Pille das Gerät als Marke und das Menü "Call nimmt über <Art> auf". Ein Mikrofonwechsel im Menü gilt für beide. Ein gemeinsamer Mikrofon-Erkenner speist beide Live-Dateien; der Live-Verweis zeigt auf die zuletzt gestartete |
| Import während Aufnahme oder Diktat | `ThrottleGate`: Pause zwischen 64-KB-Blöcken während eines Diktats, `.background` während Aufnahmen, höchstens ein zusätzlicher Erkenner, Rangfolge A.6 |
| Gerät verschwindet | `lost`, Rückfall auf eingebautes Mikrofon in ≤ 1 s, Lücke gefüllt und markiert, Ereignis, Pillenmarke; ohne Ersatzgerät wird bis zum Ende oder bis zur Rückkehr gefüllt |
| Neues Gerät während Aufnahme | kein automatischer Wechsel, Angebot im Menü |
| Telefonie-Modus | nur Wandler neu, Dateiformat bleibt |
| Deckel zu | eingebautes Mikrofon verstummt: Wechsel auf AirPods oder USB, sonst Marke; Schlaf: Schreiber leeren, ohne Füllen weiter, Lücke markiert |
| Die Vorgänger-App diktiert, während FlowIQ Dev aufnimmt | Die Vorgänger-App stellt beim Diktat die Abtastrate des Geräts um (05a B08); FlowIQ baut den Wandler neu, die Datei bleibt lückenlos (Testfall im Testfenster T2) |

---

## Anhang C: Fn-Pfad mit Zeitbudget

**Messpunkte** (`FnTimeline`): `t0` Zeitstempel des Tastenereignisses, `t1` Rückruf im Abgriff, `t2` Pille geschaltet, `t3` Mikrostart gerufen, `t4` erster Puffer (mit dessen Aufnahme-Zeitstempel `t4a`), `t5` Erkenner angedockt, `t6` erstes Ergebnis, `t7` Loslassen, `t8` Strom geschlossen, `t9` Erkennung fertig, `t10` Textstufe fertig, `t11` Journal geschrieben, `t12` ⌘V gepostet, `t13` Ziel-App holt die Daten ab.

**Anfangsverlust** = `t4a` minus `t0`: Zeitspanne vom Tastenereignis bis zur ersten aufgenommenen Probe, aus den Zeitstempeln des ersten Puffers. Ist er negativ, hat der Ring der Stufe halbwarm Ton von vor der Taste geliefert. Gelegentlicher Kalibrierlauf (nur wenn die Vorgänger-App nicht aufnimmt): bekannter Dauerton aus einer zweiten Quelle läuft schon vor dem künstlichen Tastenereignis, und es wird geprüft, dass die ersten Proben der Spool-Datei wirklich Ton enthalten und keine Anlauf-Nullen.

| Schritt | Ort | Budget | Stand |
|---|---|---|---|
| `t0` bis `t1` | Fenstersystem, Abgriff-Thread | ausgewiesen | wird gemessen |
| `t1` bis `t2` | Abgriff-Thread, ein Sprung in den Hauptthread, Ebenen-Deckkraft | ≤ 5 ms | [E] |
| bis Bild | Bildschirm | ≤ 1 Bildwechsel | |
| **`t0` bis `t2`** | | **Muss p95 ≤ 50 ms, max ≤ 150 ms** | R-015 |
| **Anfangsverlust** | Steuer-Queue, Gerät | **p95 ≤ 40 ms kalt**, sonst halbwarm | Messauftrag K-04; für die Kaltvariante ist nichts gemessen [E] |
| `t4` bis `t5` | Speech | ausgewiesen | `prepareToAnalyze` mit Audio unbekannt; Audio wartet im Strom |
| Schwanz | Dirigent | fest 110 ms | Garantie M06; Sparregel erst nach Vorher-Nachher-Lauf (Anhang K) |
| `t8` bis `t9` | Speech | ausgewiesen, Frist 1,35 s | Fremdwert [D] |
| `t9` bis `t10` | aufrufender Actor | ≤ 15 ms | R-036 |
| `t10` bis `t11` | Store | ≤ 3 ms | [E] |
| `t11` bis `t12` | Insert | ≤ 50 ms Frist | [E] |
| **`t7` bis `t13`** | | **Muss Median ≤ 350 ms, p95 ≤ 800 ms (bis 30 s), ≤ 2 s (bis 5 min)** | R-017 |

**Kalt gegen halbwarm (Messauftrag K-04):** Anfangsverlust kalt nach 30 Minuten Ruhe, nach dem Aufwachen und mit kurzem Abstand, je eingebautes Mikrofon und AirPods (Deckel zu, mit Wechsel in den Telefonie-Modus); `AVCaptureSession` gegen `AVAudioEngine`; dazu Kosten von halbwarm je Minute (CPU, Energie-Kennzahl, Dauer der orangen Anzeige). Ergebnis an den Besitzer mit Vorschlag für N.

**Nie im Hauptthread:** Mikrofon- und Desktop-Start und -Stopp, Core-Audio-Abfragen, Gerätewahl, Erkennung, Datei-Ein-Ausgabe, `fsync`, Bedienungshilfen, Zwischenablage, `CGEvent`-Posten, Hashing, Netzwerk, JSON, Protokoll, Wort-Orakel. `DispatchQueue.main.sync` verboten. Ein Hauptthread-Taster misst während jedes Diktats im Entwicklungsprofil, ob der Hauptthread länger als 50 ms blockiert.

---

## Anhang D: Entwicklungsprofil neben der Vorgänger-App

| Punkt | FlowIQ | Entwicklungsprofil |
|---|---|---|
| Bundle-Kennung (K-09) | `de.flowiq.app` | `de.flowiq.app.dev` |
| Profil-Vorgabe | nur mit Schlüssel und passender Kennung | alles andere |
| Datenordner | `~/Library/Application Support/FlowIQ/` | `~/Library/Application Support/FlowIQ-Dev/` |
| Diktiertaste | Fn | ⌥ rechts halten, Akkord-Abbruch, Abbrüche getrennt gezählt (K-10) |
| Kurzbefehle | ⌘⌥U, ⌘⌥E U, ⌘⌥R, ⌘⌥E R, ⌘⌥K, ⌃⌘V | ⌃⌥⌘U, ⌃⌥⌘E U, ⌃⌥⌘R, ⌃⌥⌘E R, ⌃⌥⌘K, ⌃⌥⌘V |
| Geräte-Import | Einstellung | echte Profile fest aus, nur Test-Abbild `FLOWIQTEST` (A.11) |
| Schreibziele | Vault-Pfade aus Einstellungen | nur `FlowIQ-Dev/` (Test-Vault darunter) und `/tmp/flowiq-dev-live.md` (`SafeFS`) |
| Nachlauf | Schalter | aus, eigener Schlüsselbund-Dienst, kein Aufruf ohne Auftrag |
| Mikrofon | Regel A.4 | eingebautes Mikrofon |
| Autostart | K-14 | nie |
| Sperre, Belegt-Datei | eigener `laufend/` | eigener `laufend/` |

**Proben je Paket ab P3:** Vault-Schnappschuss vorher und nachher (Liste mit Größe und Änderungszeit der Pipeline- und Transkript-Ordner, nur lesend): 0 neue oder geänderte Dateien durch FlowIQ Dev. Vorgänger-Prüfsumme gleich. In den Testfenstern zusätzlich: Vorgänger-Diktate und ein Vorgänger-Call laufen fehlerfrei, während das Entwicklungsprofil aufnimmt (R-006).

**Berechtigungen:** Belege der Stufe App gelten nur aus dem Bündel, gestartet über LaunchServices; ein direkt aus der Shell gestartetes Binär misst die Rechte der Shell.

**Signatur:** zwei Wege (Stand 16.11.2026, `scripts/bundle.sh`). **Mit Apple-Development-Identität:** beide Profile werden damit signiert. Die Designated Requirement wird beim Signieren ausdrücklich gesetzt: Kennung plus Apple-Anker plus **Team-Kennung** (`certificate leaf[subject.OU]`), nicht der Fingerabdruck. Damit überlebt sie die jährliche Erneuerung des Zertifikats [E, im P1-Lauf zu bestätigen]. `bundle.sh` liest Identität (SHA-1) und erwartete Team-Kennung aus `local/signing.env` (beim ersten Lauf aus dem Schlüsselbund angelegt), prüft beide und bricht bei Abweichung ab. Vorgehen bei Erneuerung: neue SHA-1 in `local/signing.env` eintragen, Team bleibt, ein Bündel bauen, Berechtigungen prüfen; fragt macOS doch neu, ist das eine Zeile an den Besitzer, keine Reparatur am Skript. **Ohne Apple-Development-Identität** (oder mit `FLOWIQ_SIGN=adhoc`): lokale Behelfssignatur (`codesign -s -`), keine Referenzprüfung; macOS bindet die vier Rechte dann an den einzelnen Bau, nach jedem Neubau müssen sie neu erteilt werden. Bis 16.11.2026 brach der Bau ohne Identität ab ("nie Ad-hoc"); die Behelfssignatur kam dazu, damit das Repo ohne Apple-Entwicklerkonto baubar ist. Nie `tccutil`.

---

## Anhang E: Bau ohne Xcode-Projekt

### E.1 Paket

```swift
// swift-tools-version: 6.2
let strict: [SwiftSetting] = [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"),
                              .treatAllWarnings(as: .error)]
// platforms: [.macOS("26.0")]
// Bibliotheken: FlowIQCore, FlowIQLog, FlowIQInput, FlowIQAudio, FlowIQRecording, FlowIQSpeech,
//               FlowIQText, FlowIQInsert, FlowIQStore, FlowIQPost, FlowIQDevices (je swiftSettings: strict)
// .executableTarget("FlowIQ", swiftSettings: strict + [.defaultIsolation(MainActor.self)])
// .executableTarget("flowiq-tool", swiftSettings: strict)
// .testTarget je Modul
```

Diese Einstellungen hat die Paketbeschreibung mit dem installierten SwiftPM angenommen [T, `swift package dump-package`]. Keine `unsafeFlags`, insbesondere kein `-disable-dynamic-actor-isolation` (die Vorgänger-App setzt es, Talkie auch, K-06). Keine Fremdbibliotheken.

### E.2 Ordner

```
Package.swift
Sources/<Modul>/            je Modul ein Ordner, Dateien unter 400 Zeilen
Sources/FlowIQ/             Koordinator, UI/, Theme/
Sources/FlowIQTool/        flowiq-tool
Tests/<Modul>Tests/         mit Fixtures/ (nur künstliche Daten)
Resources/Info.plist.in     Vorlage mit Platzhaltern für Profil und Kennung
Resources/Fonts/            DMSans-Regular.ttf, DMSans-Medium.ttf, DMSans-SemiBold.ttf, OFL.txt
Resources/AppIcon.icns, AppIcon-Dev.icns
scripts/bundle.sh, install.sh, weitergabe.sh, check.sh, zeilenbudget.sh, datenschutz-check.sh, korpus-lauf.sh, Messgeschirr (Anhang H)
budget.tsv                 Zeilenbudget (E.5)
local/                      privat, gitignored
```

### E.3 `scripts/bundle.sh dev|prod`

1. Wächter: Last aus `uptime` unter 20; die App des Zielprofils läuft nicht; `laufend/.belegt` des Zielprofils leer oder die PID darin lebt nicht mehr, sonst Abbruch mit Grund (Aufnahme, Import, Nachlauf; R-050).
2. `scripts/check.sh --static` (Datenschutz, verbotene Aufrufe nach Anhang F, Dateilängen, Zeilenbudget nach E.5).
3. `swift build -c release --product FlowIQ`.
4. Bündel zusammensetzen: `Contents/MacOS/FlowIQ`, `Contents/Info.plist` aus der Vorlage, `Contents/Resources/Fonts/*`, Symbol, `PkgInfo`.
5. Bau-Kennung stempeln: Git-Kennung, sauber oder geändert, Bauzähler, Datum (Plan 7: „eingebaut“ nur mit Commit- und Bau-Kennung).
6. Signieren. Mit Apple-Development-Identität: Identität aus `local/signing.env` (`codesign --force --sign <SHA-1>`) und ausdrücklich gesetzte Designated Requirement über Kennung, Apple-Anker und Team-Kennung (Anhang D); kein `--deep`; passt die Team-Kennung nicht oder ist die Datei unlesbar, bricht das Skript ab. Danach `codesign --verify --strict` und Vergleich der Designated Requirement mit `local/designated-requirement-<profil>.txt`: fehlt die Referenz, legt der erste Bau sie an; eine Abweichung bricht ab; ersetzen nur mit `--neue-referenz`. Ohne Identität (oder mit `FLOWIQ_SIGN=adhoc`): Behelfssignatur `codesign --sign -`, keine Referenzprüfung, Hinweis auf die Rechte je Bau.
7. `bundle.sh` installiert und startet nichts. Installieren ist ein eigener Schritt: `scripts/install.sh dev|prod` kopiert das Bündel aus `build/` nach `~/Applications/` (legt den Ordner an), bricht ab, solange die App läuft, und startet nichts. (Fassung 3 sah hier das Installieren im selben Skript samt Beenden der laufenden Instanz vor; das wurde nicht gebaut.) `FLOWIQ_BUILD_DIR=<ordner>` lenkt Bündel und Bauzähler in einen anderen Ordner als `build/`.
8. Kein Härtungs-Runtime in v1 (nur lokal, keine Notarisierung; spart die Mikrofon-Berechtigung als Entitlement) [E].

### E.4 `Info.plist`

| Schlüssel | Wert |
|---|---|
| `CFBundleIdentifier` | aus Profil (Anhang D) |
| `CFBundleName`, `CFBundleDisplayName`, `CFBundleExecutable` | FlowIQ bzw. FlowIQ Dev, `FlowIQ` |
| `CFBundlePackageType`, `CFBundleShortVersionString`, `CFBundleVersion` | `APPL`, Version, Bauzähler |
| `LSMinimumSystemVersion` | `26.0` |
| `LSUIElement` | `true` |
| `NSHighResolutionCapable` | `true` |
| `NSSupportsAutomaticTermination`, `NSSupportsSuddenTermination` | `false` |
| `NSMicrophoneUsageDescription` | Pflicht |
| `NSSpeechRecognitionUsageDescription` | bleibt drin (schadet nicht); ob eine Freigabe nötig ist, misst K-05 |
| `ATSApplicationFontsPath` | `Fonts` |
| `CFBundleIconFile` | `AppIcon` bzw. `AppIcon-Dev` |
| `FlowIQProfile` | `production` oder `development`; `production` wirkt nur mit der Produktivkennung (A.1) |
| `FlowIQBuild`, `FlowIQCommit` | Bau-Kennung |

Nicht drin: `NSAudioCaptureUsageDescription` (kein Process-Tap, 05a Abschnitt 3), `NSAppleEventsUsageDescription` (keine Apple Events). Bildschirmaufnahme braucht keinen Schlüssel, macOS fragt beim ersten `SCShareableContent`.

### E.5 Zeilenbudget

**Änderungen gegenüber Fassung 1** (Summe der Budgets unverändert 8.500; Belegstufe der Schätzungen [E], P1-Stand [G, `scripts/zeilenbudget.sh` am 13.11.]):

| Modul | Fassung 1 | Fassung 2 Budget / Grenze | Begründung |
|---|---|---|---|
| `FlowIQCore` | 350 | 330 / 380 | P1 steht bei 201 Zeilen; dazu kommen `SafeFS`, `BusyState`, `ThrottleGate` |
| `FlowIQLog` | 300 | 300 / 340 | P1 steht bei 277 und ist fast vollständig; offen sind nur Schema-Test und neue Ereignisarten |
| `FlowIQInput` | 400 | 370 / 420 | Gestenautomat ist ein Port, Akkord-Abbruch klein |
| `FlowIQAudio` | 1.150 | 1.150 / 1.320 | neue Pflichten (`CaptureSource`, halbwarm, Desktop-Neustart, zwei Queues) gegen Wegfall der 30-s-Logik; bleibt, Ventil ist die Streichliste |
| `FlowIQRecording` | 550 | 500 / 570 | Schreiber, Sperre, Umpacken, Rettung sind schmal; Größenprüfung kostet wenige Zeilen |
| `FlowIQSpeech` | 650 | 580 / 660 | zunächst ein Erkenner-Typ; der zweite steht auf der Streichliste |
| `FlowIQText` | 1.000 | 1.000 / 1.200 | Dateiplan im Lexikon-Konzept summiert sich auf 1.000 |
| `FlowIQInsert` | 400 | 370 / 420 | Bereitstellung auf Abruf ersetzt Fristlogik |
| `FlowIQStore` | 700 | 630 / 720 | Vertrag als reine Funktionen, Journal nur anhängend |
| `FlowIQPost` | 550 | 500 / 570 | eine Umsetzung, Warteschlange schlicht |
| `FlowIQDevices` | 750 | 770 / 880 | Prüfbericht: knapp gegen die 1.783 der Vorgänger-App bei mehr Pflichten (Übernahme, Uhrkorrektur, Test-Abbild-Regel) |
| `FlowIQ` (App) | 1.450 | 1.600 / 1.800 | P1 belegt schon 775 (Theme 277, Einrichten 224); neu sind Vorschlagsliste ab P2, Wort-Orakel, Selbsttest |
| `flowiq-tool` | 250 | 400 / 460 | Prüfbericht: 250 unrealistisch; jetzt acht Befehle inklusive Wortausrichtung und Drei-Wege-Tabelle |
| **GESAMT** | 8.500 / 9.000 | **8.500 / 9.000** | Z-06 |

- **Zählregel:** physische Zeilen aller `.swift`-Dateien unter `Sources/<modul>/`, Leer- und Kommentarzeilen eingeschlossen, wie die 16.290 bei der Vorgänger-App. `flowiq-tool` zählt mit. Tests zählen nicht; Testhilfen tragen keine Produktlogik. Skripte außerhalb von `Sources/` zählen mit, sobald die App sie zur Laufzeit braucht (geplant: keine). Zeilenlänge höchstens 120 Zeichen.
- **Durchsetzung:** `budget.tsv` (Spalten `modul`, `budget`, `grenze`; letzte Zeile `GESAMT`) liest `scripts/zeilenbudget.sh`. Über der Puffergrenze eines Moduls oder über der Grenze von `GESAMT` bricht `check.sh` ab; fehlt die Zeile `GESAMT`, bricht es ebenfalls ab. Über dem Budget wird nur gemeldet, ab 85 % des Budgets gewarnt. Ein Ordner ohne Zeile bricht ab.
- **Änderung der Datei:** nur im eigenen Commit mit Ja des Besitzers; der Pre-Commit-Hook lehnt Commits ab, die `budget.tsv` zusammen mit anderen Dateien ändern. Die Summe der Budgets bleibt höchstens 8.500.
- **Nach jedem Paket:** eine Zeile Verbrauch gegen Budget mit Hochrechnung im Paketbericht.
- **Änderungsprotokoll:**
  - 13.11.2026, Commit `511c65b`, Ja des Besitzers: Der AAC-Kodierer gehört fachlich zu `FlowIQRecording`. Der P3-Bau hatte ihn nach `FlowIQAudio` gelegt, um unter der Grenze von Recording zu bleiben; die Prüfung hat das als Budget-Kosmetik erkannt (ehrlich gerechnet Recording 692). Umverteilt: `FlowIQRecording` 500/570 auf 630/700, `FlowIQAudio` 1.150/1.320 auf 1.020/1.170. Summe der Budgets 8.500 und Gesamtgrenze 9.000 unverändert.
  - 13.11.2026, Commit `33b40fb`, K-33 (Besitzer: "am effizientesten, so klein wie möglich, du hast Spiel"): Budgets nach der Spalte "mit Streichungen" (Summe 9.570), Gesamtgrenze 9.800 statt 10.000, Modulgrenzen rund 5 bis 10 % über dem Budget, `FlowIQText` 1.270/1.400. Die Streichungen aus Anhang K (Standby-Analyzer, eigener Rohfassungs-Weg, R-045, R-061) gelten damit.
  - 13.11.2026, Commit `a526506`, Fassung 4: Der Verschlankungsplan (Paket V) rechnet mit allen Funktionen bis Ende P7 trotz Paket V und Vermeidungsregeln rund 9.950 bis 10.110 Zeilen (Spanne 9.650 bis 10.250). Der Assistent hat deshalb die Gesamtgrenze auf 10.100 gesetzt (38 % unter der Vorgänger-App), Ziel nach V 9.920. Paket V ist Pflicht vor P6 und P7; Entwicklungszeit-Auswertungen ohne Apple-API laufen als Python unter `scripts/korpus/` und zählen nicht; Vault-Vertrag und Nachlauf-Ablage gehören in `FlowIQStore`. Modulgrenzen werden nach V enger gezogen.

**Fassung 3: Bedarf gegen Budget** (Entscheid beim Besitzer). Gemessen [G, `scripts/zeilenbudget.sh` am 13.11. um 15:37, Gesamt 4.987 Zeilen]; Bedarf je Modul [E] aus Fassung 3, Schätzung im Lexikon-Konzept 11.7 und den gebauten Paketen.

| Modul | Budget heute | gemessen | Bedarf Fassung 3 ohne Streichung | mit Streichungen (Vorschlag) | was dazu kommt oder wegfällt |
|---|---|---|---|---|---|
| `FlowIQCore` | 330 | 356 | 410 | 410 | `LiveRecognizer`, Betriebsart-Wahl, Belegt-Zustand |
| `FlowIQLog` | 300 | 284 | 300 | 300 | neue Ereignisarten |
| `FlowIQInput` | 370 | 2 | 390 | 390 | zwei Kurzbefehle (Live-Quelle, Korrigieren) |
| `FlowIQAudio` | 1.020 | 1.020 | 1.040 | 1.040 | Pausenerkennung für Cloud-Commits |
| `FlowIQRecording` | 630 | 681 | 690 | 690 | gebaut |
| `FlowIQSpeech` | 580 | 202 | 640 | 600 | `LiveRouter` (Schatten, Übergabe); Standby-Analyzer gestrichen |
| `FlowIQText` | 1.000 | 1.147 | 1.270 | 1.270 | `PairAligner` aus dem Werkzeug hierher (Lexikon-Konzept 11.7) |
| `FlowIQInsert` | 370 | 2 | 410 | 380 | Ersetzen im Zielfeld; "Rohfassung" kein eigener Weg mehr |
| `FlowIQStore` | 630 | 32 | 850 | 850 | Kontobuch, Dauerfälle, Prüfliste (11.2 bis 11.4), neue Kopfzeilen |
| `FlowIQCloud` | 500 | 2 | 730 | 680 | Realtime-Client, Verbrauch, Richtlinie; R-061 gestrichen |
| `FlowIQDevices` | 770 | 2 | 770 | 770 | unverändert |
| `FlowIQ` (App) | 1.600 | 838 | 1.980 | 1.850 | Korrekturfenster, Cloud-Wahl und Marke, Prüfliste; R-045, R-061, Rohfassung gestrichen |
| `flowiq-tool` | 400 | 419 | 340 | 340 | Ausrichtung wandert nach Text |
| **Summe** | **8.500** | **4.987** | **≈ 9.780** | **≈ 9.570** | |

Ergebnis: **Fassung 3 passt nicht in die Gesamtgrenze 9.000**, auch nicht nach allen vertretbaren Streichungen (rund 570 Zeilen darüber); die Summe 8.500 ist nicht zu halten. Unter 9.000 käme man nur, wenn einer der beiden neuen Kernwünsche entfällt (Cloud-Live rund 470 Zeilen oder das Korrekturfenster mit Kontobuch rund 650 Zeilen) oder der Lautabgleich R3 gestrichen wird, den der Korrektur-Kreislauf laut Messung der Prüfung braucht. Dazu überschreitet `FlowIQText` mit 1.270 seine Grenze 1.200 (Register 08, U-01).

Vorschlag an den Besitzer (K-33): Gesamtgrenze 10.000 (immer noch 39 % unter den 16.290 der Vorgänger-App), Summe der Budgets 9.570 nach den Streichungen in Anhang K, Grenze `FlowIQText` 1.400. Bis zum Entscheid gilt `budget.tsv` wie oben. Innerhalb der heutigen Modulgrenzen baubar sind P2c ohne `PairAligner` (Paare aus Klicks brauchen keine Ausrichtung; `FlowIQText` steht schon bei 1.147 von 1.200) und P4. P5a (Kontobuch braucht `FlowIQStore` rund 850 von heute 720) und P5b (Cloud-Live) warten auf K-33.

---

## Anhang F: Nebenläufigkeit, Verbote, Datenschutz

**Isolation:** Hauptthread nur UI. Je Ressource ein Actor. Capture-Delegates sind `final class ...: NSObject, ..., Sendable` mit nur unveränderlichen Feldern [T]. Keine geplanten Ausnahmen; jede spätere (`@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency import`) braucht `// SAFETY:` und einen Test.

**`scripts/check.sh` blockiert** (Ergänzungen gegenüber Fassung 1 fett):
- `try?` ohne `// try?-ok:`, `AudioObjectSetPropertyData`, `tccutil`, `DispatchQueue.main.sync`, `NSLog`, Ausnahmen ohne `// SAFETY:`, feste Farb- und Größenwerte außerhalb `Theme/`, Dateien über 800 Zeilen, Budget überschritten, Datenschutz-Treffer.
- **`eraseFile` und `kAudioFileFlags_EraseFile` überall.**
- **`NSSpellChecker` außer in `Sources/FlowIQ/SystemWordOracle.swift` und `Sources/FlowIQTool/`.**
- **Netz außerhalb `FlowIQCloud` (bis zur Umbenennung `FlowIQPost`): `URLSession`, `NSURLConnection`, `import Network`, `CFNetwork`, `WKWebView`, `Process(`, `posix_spawn`, `Data(contentsOf:` mit anderer als einer Datei-URL (Heuristik).**
- **Direkte Schreibaufrufe außerhalb `SafeFS.swift` und `TrackWriter` (`createFile`, `moveItem`, `copyItem`, `removeItem`, `createSymbolicLink`, `createDirectory`, `.write(to:`, `FileHandle(forWritingTo`, `ExtAudioFileCreateWithURL` nur in `TrackWriter` nach `claimNew`).**
- **Zeilen über 120 Zeichen.**

**Datenschutz im Repo (Prüfbericht D-1 bis D-3):** Pre-Commit prüft die gestuften Dateien; **Pre-Push prüft die ganze Historie und alle Commit-Texte**; die private Musterliste (`local/datenschutz-muster.txt`) wird aus Lexikon und Namenskandidaten erzeugt und bleibt lokal; vor dem ersten Push wird die Autor-Adresse auf eine GitHub-Noreply-Adresse gestellt (K-24). Laufzeit-Beleg für R-067 und R-095 ist die Netzprobe (`nettop` je Minute, nur FlowIQ und Apples Sprachdienst), nicht die Suche.

**Antwort auf die Gefahrenmuster der Vorgänger-App (05a Abschnitt 4):** G01 kein Abschalten der Prüfung; G02 Werttypen und Actors; G03 keine Singletons, Abhängigkeiten als Parameter; G04 Anhang C; G05 Ereignisse statt Abfragen, jede Frist mit Meldung; G06 nur anhängen, Kopie vor Ersetzen, Löschen nur mit Nachweis; G07 stabile Signatur; G08 Pfade als Einstellung; G09 private Daten nur im Datenordner; G10 Prüfung vor Rückgabe der Zwischenablage; G11 kein `pkill`; G12 Anhängen statt Neuschreiben, Protokoll rollierend; G13 Oberflächentext nur aus Verhalten mit Test.

**Antwort auf die Störfälle (02):** S1 exklusives Anlegen ohne `eraseFile`, späte Puffer gezählt, Größenprüfung und Pflichttest (A.5); S2, S3 Journal ohne Verdichtung, Rettung, Datei-Lauf aus dem Spool; S4 Geräteregel; S5 Fristen an jedem Warten; S8 bis S11 Spurwächter; S12 Nachfrage beim Pillenklick; Abweichung von Garantie M08 (keine 120-s-Notbremse) begründet in A.12; S13, S22 `final-lokal` und Warteschlange; S15 Warteschlange für Geräte; S16 Identität über SHA; S17 Übernahme der Ignorierliste; S18 keine Lernschicht im Hintergrund, Messung je Diktat; S19 Hauptthread frei; S20 keine geteilten Puffer; S21 eigenes Protokoll mit Fehlerdatei; S23 bis S25 Vertragstests.

---

## Anhang G: Teststrategie

### G.1 Grundlage je Modul

| Modul | Im Repo (künstliche Daten, `swift test`) | Nur lokal (Korpus, Hardware) |
|---|---|---|
| Core | Einstellungen: Vorgaben, Version, Lesefehler lässt Datei stehen; `guardWritable` wirft im Entwicklungsprofil außerhalb des Datenordners; Sprache fällt nach jeder Aufnahme auf Deutsch zurück | |
| Log | Rotation bei 10 MB, NDJSON-Schema, Wochenzahlen auf künstlichem Protokoll | Wochenzahlen auf echtem Protokoll in ≤ 10 s |
| Input | Gestenautomat als Tabelle (Halten, Doppeltipp, Sperre, Escape, Fn plus Leertaste, Akkord-Abbruch bei ⌥ rechts, Bounce); Zuordnung Registrierungsfehler | echte Tasten in Phase 4 |
| Audio | `DevicePolicy` über alle Kombinationen (AirPods, Deckel, ausdrücklich, Zweck, laufendes Gerät); `TrackGuard` auf künstlichen Pegelreihen; `TimelineGuard` Lückenfüllung; Fan-out verliert nichts; Wandler 48 kHz zu 24 kHz zu 48 kHz mit Sinus, Länge stimmt | `spurpruefung` über 164 Archiv-Calls (7 bekannte Fälle, Fehlalarme je 10 h); Gerätematrix mit AirPods und Kopfhörern |
| Recording | Kill-Test: Kindprozess schreibt, `SIGKILL`, Datei bis höchstens 1 s vor Abbruch dekodierbar; Umpacken mit Dauerprüfung; zweite Instanz scheitert an der Sperre; `deliver` in schreibgeschützten Ordner wirft; Rettung | 1, 30 und 120 Minuten Kill-Test im Entwicklungsprofil |
| Speech | Attrappe der Erkenner-Schnittstelle; Frist und Rückfall; Integrationstest mit zur Laufzeit per `say` erzeugter deutscher Sprache (nur wenn das Modell installiert ist, Schalter in der Umgebung) | Korpus-Wiedergabe für K-01, K-02; lokale Endfassung gegen ElevenLabs an Archiv-Aufnahmen (R-060, R-075) |
| Text | Schutzfälle (eingedeutschte Verben, „musst“, „möchte“), Namen über Fixture-Lexikon mit erfundenen Namen, Familienregel, ausgesprochene Ziffern, Idempotenz (`process(process(x)) == process(x)`), leeres Lexikon ändert nichts, Zeit p95 auf 300-Wörter-Eingabe | `flowiq-tool replay`: Drei-Wege-Tabelle, Goldsatz, Schadensrate, Namenstreffer auf zurückgehaltenen Diktaten |
| Insert | Zwischenablage über Protokoll-Attrappe (Sichern, Rückgabe nur bei gleichem `changeCount`); Entscheidungsfunktion `landed`, `unverifiable`, `noTextFocus`; Leerzeichenlogik | fünf Ziel-Apps, 100 Einfügungen |
| Store | Goldene Dateien für Namen, Frontmatter, Zeilen; Zeilenmuster der Abnehmer (`^\*\*\[\d`, Phasen, Status) als Fixture; Anhänge-Eigenschaft der Live-Datei über zufällige Folgen; flüchtige Zeile; Phasenwechsel; Kopie vor Aufwertung; Journal mit abgerissener letzter Zeile; Vorgänger-Decoder mit künstlichem Altformat | Lesen der 2.500 alten Diktate aus der Sicherungskopie |
| Post | Anfrage-Bau (Datei-Strom, Sprache, höchstens 100 Begriffe); Antwort-Parser mit künstlichem JSON; Warteschlange mit Attrappe (Netz weg, Kontingent, Schlüssel fehlt, Wiederholung); keine Ersetzung ohne Kopie | ein echter Lauf nur mit Auftrag |
| Devices | Stromkopie und SHA mit Temp-Dateien; WAV-Kopf-Reparatur; Journal-Altformat; gleicher Name neuer Inhalt wird importiert, gleicher Inhalt nie; Gerät schreibgeschützt eingehängt, kein Schreibversuch; Uhrkorrektur; Übernahme-Trockenlauf mit künstlichem Vorgänger-Ordner | Testgerät als FAT32-Disk-Image; echte Geräte erst in Phase 4 und 5 |
| App | Zustandsautomat des Koordinators (Betriebsarten und Kombinationen); Sprache gewinnt per Kurzbefehl | Bildschirmfotos je Zustand, Messung am gerenderten Element |
| flowiq-tool | `replay` auf künstlichem Mini-Korpus im Repo | volle Läufe über `scripts/korpus-lauf.sh` mit Pfaden in `local/` |

Jeder behobene Fehler aus Fehler- und Störfall-Register bekommt einen Test, der ohne die Korrektur rot wird (R-091). Ein eigener Test-Agent schreibt Tests aus dieser Beschreibung, nicht aus dem Code.

### G.2 Pflichttests aus der Prüfung von Fassung 1

| Modul | Neuer Pflichttest |
|---|---|
| Core | Profil ohne Schlüssel oder mit fremder Kennung ist `development`; `SafeFS` wirft außerhalb der Erlaubnisliste; `claimNew` scheitert auf vorhandenem Pfad |
| Audio | Gerätewechsel während Aufnahme verliert 0 Puffer (Zeitstempel lückenlos, `FileSource`); Überlauf eines begrenzten Stroms wird gezählt und gemeldet; Lücke über 30 s wird gefüllt und markiert; Drift unter der Schwelle wird nie gefüllt; Desktop-Strom künstlich beendet, Spur läuft weiter; Spurwächter mit Pegelreihen beider Stufen |
| Recording | **Späte Puffer:** Quelle liefert nach dem Stopp weiter, für alle Endpfade (normal, ohne Erkenner-Sitzung, Escape, Frist, Erkenner gescheitert): Datei bleibt vollständig, `late_buffers` gezählt, nie neu geöffnet; Größenprüfung erkennt künstlich gekürzte Dateien als `audio_lost` |
| Text | Idempotenz mit Mengenbremse (Fall: viele R1 plus R3); gleiche Antworten ergeben gleichen Text; Großbuchstabenfolgen sind nie R3-Quelle; eingedeutschte Verben sind geschützt |
| Insert | Bereitstellung auf Abruf: Rückgabe erst nach Abruf; ohne Abruf `notFetched`; Feldinhalt erscheint in keinem gespeicherten oder protokollierten Wert |
| Log | Schema-Test: kein Freitextfeld im Protokoll |
| Devices | Test-Abbild mit verbotenem Namen wird verweigert |
| Store | `dauer: laufend` während live; `nachlauf:`-Kennzeichen; Suche unter `archive/`; Live-Verweis bei zwei Live-Dateien |

---

## Anhang H: Messgeschirr und Belegstufen

| Stufe | Bedeutung | Gilt mindestens für |
|---|---|---|
| App-echt | laufendes Bündel, echte Stimme, echtes Mikrofon, echte Taste, in einem Testfenster mit dem Besitzer | erstes und letztes Wort 50 von 50, fünf Ziel-Apps, AirPods-Matrix, Deckel, Schlaf, Call mit AirPods, Berechtigungen |
| App-synth | laufendes Bündel, künstliche Taste, `FileSource` mit künstlicher Sprache, Ziel TextEdit | Zeiten über 200 und mehr Diktate, 500 Diktate für 0 Byte, Gleichzeitigkeit, Lücken, Live-Latenz |
| Korpus | Lauf über die eingefrorene Datenkopie oder das Archiv | Textstufe, Spurwächter-Schwellen, Gütemessungen |
| Test | `swift test` | Verträge, Automaten, Fehlerpfade |
| Code | Suche oder Lesen | Verbote, Budget |
| Hand | Der Besitzer entscheidet | Logo, Güte am Tor, Zurückstellungen |

**Geschirr:** `flowiq-tool abnahme <paket>` (Auswertung aus dem Protokoll), Selbsttest (A.12), Ablage-Schnappschuss (Skript nicht im Repo), Wächter-Skript für die Vorgänger-App (nicht im Repo) (Prüfsumme des Binärs, `stat` auf `laufend/` ohne Lesen, `git status` des Vorgänger-Repos), `netzprobe.sh` (Skript nicht im Repo), `testgeraet.sh` (Skript nicht im Repo), Kill-Test im Testziel, Hauptthread-Taster. Rohdaten jedes Laufs liegen in `local/abnahme/<paket>/`; ins Repo kommt nur die Summenzeile in `ABNAHME.md`.

**Testfenster mit dem Besitzer** (je rund 20 Minuten, Termin auf Zuruf): T1 nach P3 (Gerätematrix, Call mit AirPods, Deckel, Schlaf, Vorgänger-Call neben Dev-Call), T2 nach P4 (50 Diktate erstes und letztes Wort, fünf Ziel-Apps, AirPods mit Musik, Vorgänger-Diktate neben Dev-Aufnahme), T3 nach P5 (Call plus Diktat, Raum plus Call, englische Aufnahme, Berechtigungen nach drei Installationen). Phase 5: echte Fn-Taste und echte Geräte.

**Regeln:** Ein verfehltes Kriterium bleibt rot und geht als Zeile an den Besitzer. Eine Zahl in `ABNAHME.md` wird nie im selben Commit geändert wie Code, der sie verfehlt; Änderungen nur als Zeile im Änderungsprotokoll dort, mit Ja des Besitzers und Datum.

---

## Anhang I: Paketreihenfolge Phase 3

Höchstens zwei Bau-Agenten gleichzeitig. Ab Fassung 3: P2c neben P4, dann P5a neben P6, dann P5b neben P7. Abnahmekriterien je Paket stehen in `ABNAHME.md` (Spalte Paket); hier nur Inhalt und Voraussetzungen.

| Paket | Inhalt | Voraussetzung |
|---|---|---|
| P1 Gerüst | Paket, Core mit `SafeFS` und Profil-Vorgabe, Log, App-Hülle, `bundle.sh`, `check.sh`, `budget.tsv` | läuft (Nachzug: Profil-Vorgabe, Designated Requirement über Team, Verbotsliste-Ergänzungen) |
| P2 Textstufe und Vorschlagsliste | `FlowIQText`, `flowiq-tool erkennen`, `replay`, `schutzliste`, `vorschlaege`, `SystemWordOracle`, Vorschlagsliste im Entwicklungsprofil | **K-01 entschieden**; Goldsatz-Teil "einstellen" und Gesamtkorpus neu erkannt; strittige Namen über die Vorschlagsliste bestätigt; Tresor bleibt zu bis zur Abnahme |
| P3 Audio und Aufnahme | `FlowIQAudio` mit `CaptureSource`, `FlowIQRecording`, Call und Raum ohne Live, Selbsttest-Grundlage | K-18 (Handetiketten stiller Spuren) |
| P2c Korrektur-Logik | Paare aus Klicks (der `PairAligner` folgt mit P5a, E.5), Dauerfälle, Reparatur-Signale, Familien als Daten (`FlowIQText`), Kontobuch (`FlowIQStore`, Lexikon-Teil) | Lexikon-Konzept Fassung 2 Abschnitt 11 |
| P4 Diktat und Korrekturfenster | `FlowIQInput`, Diktat-Lauf, `FlowIQInsert` mit Ersetzen im Zielfeld, Journal, Pille, Fenster "Letztes Diktat korrigieren" (N.2) | K-04 begonnen; P2c |
| P5a Nachlauf und Ablage | `PairAligner` und Nachlauf-Paare, `FlowIQStore` mit Live, Apple-Live mit Textstufe je Beitrag, `FlowIQCloud` Teil Nachlauf (alle Betriebsarten inklusive Diktat, M.1), Nachlauf-Abweichungen als Vorschläge, Sprachwahl, neue Kopfzeilen | K-19, K-33 |
| P5b Cloud-Live | ElevenLabs Realtime, `LiveRouter` mit Schatten und Übergabe, Wechsel und Rückfall, Cloud-Marke, Verbrauch und Monatsgrenze, Schlüsselfeld, Kurzbefehl Live-Quelle | K-33 entschieden; erster echter Lauf nur mit Auftrag |
| P6 Stift und ZEPHYR | `FlowIQDevices`, Übernahme | Test-Abbild-Regel |
| P7 Oberfläche | Einstellungen, Menü komplett, Theme, Symbol, endgültige Vorschlagsliste | K-15 |


**Abnahmetests, die Fassung 3 ergänzt** (ein eigener Test-Agent hat `abnahme-tests/p4/` und `p5/` nach Fassung 2 geschrieben; diese Dateien brauchen Zusätze, neue Dateien in Klammern):

| Paket | Datei | Zusatz |
|---|---|---|
| P2c | `p2/P2FamilyTests.swift` | erfundene zweite Familie mit eigenem Anker wirkt ohne Codeänderung; kein Anker im Code |
| P2c | `p2/P2LearningTests.swift` | Ziel zuerst bestätigen, dann Hörvariante; neue Fehlform zum bestätigten Ziel über den Lautabgleich; Verwechslung zweier richtiger Wörter erzeugt keine Regel |
| P2c | (`p2/P2CorrectionLedgerTests.swift`) | Bündeln je Ziel, Gegenbeleg, Schwelle 2 Aufnahmen an 2 Tagen für Nachlauf-Paare, Dauerfälle blockieren brechende Änderungen, Signale S1 bis S8 |
| P4 | `p4/InsertionTests.swift` | Ersetzen im Zielfeld: lesbares Feld, ⌘Z-Weg, Zwischenablage-Weg; Feldinhalt nie gespeichert |
| P4 | `p4/RawVersionTests.swift` | Rohfassung kommt aus dem Korrekturfenster, nicht mehr als eigener Menüweg; Ablehnung wirkt gleich |
| P4 | `p4/JournalTests.swift` | Ereignisse `correction`, `reject_intervention`, Ergebnis des Ersetzens |
| P4 | `p4/DuringCallTests.swift` | bei Cloud-Live im Call bleibt die Diktat-Erkennung lokal, 0 Diktat-Puffer im Cloud-Strom |
| P4 | (`p4/CorrectionWindowTests.swift`) | Fenster in höchstens 300 ms, Auswahl aus Alternativen, Lexikon und Eingabe, "war richtig", Fokus zurück an die vorherige App |
| P5a | `p5/ContractTests.swift` | neue Kopfzeilen, Phasen und Pipeline unverändert, Wechselzeilen kursiv und vom Zeilenmuster der Abnehmer nicht erfasst |
| P5a | `p5/LiveFileTests.swift` | Textstufe je fertigem Beitrag vor dem Anhängen; Anhänge-Eigenschaft auch bei Wechseln |
| P5a | `p5/AftercareTests.swift` | Diktat-Nachlauf nach dem Einfügen, Vorgabe an, Schalter aus heißt 0 Uploads; Textstufe auf dem Nachlauf-Ergebnis; Nachlauf-Abweichungen nur als Vorschlag |
| P5a | `p5/FailureQueueTests.swift` | Warteschlange auch für Diktat-Aufträge |
| P5a | `p5/DevProfileTests.swift` | Cloud im Entwicklungsprofil nur mit Attrappe oder ausdrücklichem Auftrag |
| P5b | `p5/NoSilentLossTests.swift` | Wechsel und Rückfall: 0 fehlende, 0 doppelte Satzmarken |
| P5b | (`p5/CloudLiveTests.swift`) | Anfrage-Bau (Schlüssel nur als Kopfzeile, Parameter), PCM16 16 kHz in 200-ms-Paketen, Ereignisse und Fehlerarten, Commit an Pausen spätestens nach 15 s, Wiederverbindung mit `previous_text` und Nachsenden, Begriffe höchstens 50 zu 20 Zeichen |
| P5b | (`p5/UsageAndBadgeTests.swift`) | Zähler je Quelle und Art, Monatsgrenze mit lückenlosem Rückfall, Marke folgt dem Senden auf 1 s |

**Vor Tor 2** (Phase 2, kein Bau nötig): R-058, R-060, R-075 als lokale Gütemessung gegen vorhandene ElevenLabs-Fassungen (K-20), K-02, K-03, K-08.

---

## Anhang J: Offene Punkte (Klärungen)

### Messung

| Nr | Frage | Messung | wann |
|---|---|---|---|
| K-01 | Erkenner fürs Diktat: `SpeechTranscriber` oder `DictationTranscriber`, mit Kontextbegriffen oder eigenem Sprachmodell | Spike 1 mit Audio, dann Goldsatz-Teil "einstellen" neu erkannt mit jeder Variante, Netzprobe je Variante | vor P2 |
| K-02 | Verlust hinter dem Mikrofon (Erkenner kürzer als Datei) | Korpus-Wiedergabe der 81 Fälle und der 98 angeschnittenen, ohne und mit 300 ms Vorlauf-Stille; nur noch für diese Frage | vor Tor 2 |
| K-03 | Ruhewerte der Vorgänger-App | Messreihe nach Ende des laufenden Calls | vor Tor 2 |
| K-04 | Kalt gegen halbwarm, Startweg, Standby | Anfangsverlust und Kosten wie Anhang C; `AVCaptureSession` gegen `AVAudioEngine`; Standby-Analyzer mit Audio | P4 |
| K-05 | Spracherkennungs-Freigabe nötig? | im eigenen Bündel beim ersten Start Status lesen | P1 |
| K-06 | Laufzeitprüfung der Actor-Isolation (Talkie meldet einen macOS-26-Absturz darin [D]) | bleibt an; tritt der Absturz auf, entscheidet der Bericht je Ziel | laufend |
| K-07 | Bereitstellung auf Abruf in den fünf Ziel-Apps | 100 Einfügungen je App; sonst Rückfall auf 1,0 s Frist | P4 |
| K-08 | `final-lokal`: zweiter lokaler Durchgang oder Live-Text | Wortfehlerrate an 10 Calls, 10 Vorlesungen, 3 englischen Aufnahmen | vor Tor 2 |
| K-18 | Stille Desktop-Spuren: Ursache und Etiketten | Dekodier-Prüfungen P1 und P3 aus dem Störfall-Katalog, Handetiketten der Verdachtsfälle | vor P3 |
| K-19 | Wie viele Analyzer trägt macOS 26 gleichzeitig, wer verliert | Lauf mit 1 bis 5 Analyzern über `FileSource` | P5 |
| K-20 | Güte lokal (R-058, R-060, R-075) | lokal gegen vorhandene ElevenLabs-Fassungen, kein Cloud-Aufruf | vor Tor 2 |
| K-22 | Pegelregelung im Erkennungsfilter | Korpus-Wiedergabe mit und ohne | P3 |

### Besitzer

| Nr | Frage | Vorschlag |
|---|---|---|
| K-09 | Bundle-Kennungen | `de.flowiq.app` und `de.flowiq.app.dev` |
| K-10 | Dev-Taste | ⌥ rechts halten; Frage dazu: tippst du Sonderzeichen mit ⌥ rechts? |
| K-11 | Endphase und Kopfzeilen | `final-lokal`, `pipeline: panotti-live+lokal`, `dauer: laufend` während live, Kennzeichen `nachlauf:` |
| K-12 | `Time.txt` auf den DVT1600 schreiben trotz R-070 | einzige Schreibstelle, Schalter, Vorgabe wie heute an |
| K-13 | Diktat-Audio aufbewahren | unbegrenzt, Löschen nur als sichtbare Einstellung |
| K-14 | Autostart | ja, nur Produktivprofil, abschaltbar |
| K-15 | Dunkler Hintergrund | `#0b0b10` wie die TapIQ-Test-App |
| K-16 | Diktat während Call in der Live-Datei | behalten mit `(Diktat)`; Hinweis: ein privates Diktat steht dann im Call-Transkript |
| K-17 | Stufe halbwarm (orange Anzeige N s länger) | nur wenn K-04 den Kaltstart über 40 ms p95 misst; N nach Messung |
| K-23 | Vorname im Repo | in Doku als Rolle erlaubt, in `Sources/` und `Tests/` nie |
| K-24 | Autor-Adresse vor dem ersten Push | GitHub-Noreply |
| K-25 | Streichliste (Anhang K) | Reihenfolge bestätigen |
| K-26 | Live-Erkennung beim Diktat per Cloud | in v1 nein: eine warme Verbindung ist nicht möglich (der Dienst schließt nach 15 s ohne Nachricht und rechnet jede gesendete Sekunde ab, auch Stille), ein Verbindungsaufbau je Tastendruck kostet Zeit vor dem ersten Ergebnis [E]; die Schnittstelle lässt es später ohne Umbau zu. Englisches Diktat bleibt v1.1 (R-027) |
| K-27 | Modell für Cloud-Live | `scribe_v3_live` (gleicher Preis wie `scribe_v2_realtime`, laut Doku genauer) [D] |
| K-28 | Begriffe an Cloud-Live | an, höchstens 50 bestätigte Einträge; kostet laut Preisseite 0,08 USD je Stunde zusätzlich [D] |
| K-29 | Zwei neue Kurzbefehle | Live-Quelle umschalten ⌘⌥E, Letztes Diktat korrigieren ⌘⌥K (Entwicklungsprofil mit zusätzlichem ⌃); Belegung prüft die Registrierung. 16.11. (Besitzer): ⌘⌥E als eigene Taste entfällt, E steht für Englisch zusammen mit U oder R; die Live-Quelle wechselt nur im Menü |
| K-30 | Monatsgrenze für Cloud-Minuten | Vorgabe aus; Vorschlag zum Einschalten nach dem ersten Monat mit Zählerdaten |
| K-31 | Sitzungsdauer von ElevenLabs Realtime | in der Doku nicht genannt; FlowIQ erneuert vorsorglich alle 30 Minuten an einer Pause; Wert erst im ersten Lauf mit Auftrag messen |
| K-32 | Datenhaltung bei ElevenLabs | Hinweis im Aufklapper: Audio wird beim Dienst nach dessen Regeln gespeichert, ohne Speicherung nur im Enterprise-Tarif [D] |
| K-33 | Zeilenbudget Fassung 3 | Gesamtgrenze 10.000, Budgetsumme 9.570, Grenze `FlowIQText` 1.400 (E.5) |
| K-34 | Diktat-Nachlauf nur bei unbekanntem Wort | Vorgabe "alle Diktate" (Entscheid der Projektsteuerung, wie die Vorgänger-App); Option "nur Diktate mit unbekanntem Wort" spart rund 59 % der Uploads [K, Lexikon-Konzept 11.1] |
| K-35 | Korrekturfenster schreibt ins Zielfeld | ja, wenn das Feld lesbar ist und der eingefügte Text unverändert dasteht; sonst ⌘Z-Weg oder Zwischenablage (N.2). Das Lexikon-Konzept 11.1 sah nur Kopieren vor |

---

## Anhang K: Streichliste (feste Reihenfolge)

Greift, wenn ein Modul seine Grenze oder die Summe die Gesamtgrenze erreicht, und zwar von oben nach unten, je Punkt eine Zeile an den Besitzer. Gestrichen wird Umfang, nie die Grenze. Fassung 3 hat die Liste neu bewertet (Spalte Stand).

| Nr | Was | Schätzung Zeilen [E] | Stand Fassung 3 |
|---|---|---|---|
| 1 | Zweiter Erkenner-Typ hinter `RecognizerProfile`, falls K-01 ihn nicht braucht | 120 | offen bis K-01 |
| 2 | Standby-Analyzer, falls K-04 keinen Gewinn misst | 40 | **gestrichen** (im Bedarf E.5 schon abgezogen) |
| 3 | R3 Sprechform-Abgleich | 250 | **bleibt**: der Korrektur-Kreislauf braucht ihn für neue Fehlformen bestätigter Ziele (Messung der Prüfung: ohne ihn 42 %) |
| 4 | R-061 Sammel-Nachzug (Soll) | 80 | **gestrichen** (Vorschlag, Ja des Besitzers offen); der Nachlauf-Schalter je Betriebsart und der Zähler decken den Bedarf teilweise |
| 5 | R-063 Verbrauchsanzeige (Soll) | 60 | **nicht streichbar**: in Fassung 3 Muss (R-101), weil Cloud-Live laufend Kosten erzeugt |
| 6 | R-045 Pegelregler und Pegeltest (Soll), Mikrofonwahl bleibt | 80 | **gestrichen** (Vorschlag, Ja des Besitzers offen) |
| 7 | R-034 Rohfassung einfügen als eigener Weg (Soll) | 50 | **aufgegangen** im Korrekturfenster (Schaltfläche "Rohfassung"), R-034 bleibt erfüllbar |
| 8 | K-12 Uhrzeit auf das Gerät schreiben | 30 | bleibt: ohne sie ist R-071 beim DVT1600 nicht sicher zu erfüllen |
| 9 | R-032 Lernsignale aus Korrekturen (Soll) | 30 | **nicht mehr streichbar**: der Korrektur-Kreislauf ist genau dieses Lernsignal, ohne Tastenprotokoll und ohne Lesen fremder Felder |
| 10 | Cloud-Live (R-096 bis R-107) als Ganzes nach v1.1 | 470 | nur falls der Besitzer die Gesamtgrenze 9.000 hält (E.5) |

---

## Anhang L: Wechsel-Checkliste

Die Checkliste für den Umstieg des Besitzers von der Vorgänger-App auf FlowIQ (seine Assistenten-Anleitungen, Skills, Leseskripte und Ablage-Dokumente, 14 Stellen) betrifft nur dessen eigene Einrichtung und ist für die Weitergabe herausgenommen (16.11.2026); sie liegt privat beim Besitzer. Für alle gilt daraus nur:

- Der Wechsel und alle davon abhängigen Stellen gehören in denselben Commit (R-009).
- Journal, Ignorierliste, Einstellungen und Sprechername der Vorgänger-App werden per Trockenlauf und Klick übernommen (A.11).
- Wer Transkripte weiterverarbeitet, muss die Phase `final-lokal` als fertiges Transkript anerkennen und die Kopfzeilen `nachlauf:`, `dauer: laufend`, `live_quelle`, `live_wechsel`, `nachlauf_quelle`, `cloud_minuten` kennen; bei `live_quelle: elevenlabs-*` gilt der Live-Text schon als Cloud-Fassung; kursive Wechselzeilen `_[MM:SS] Live-Erkennung: ..._` werden beim Auswerten übersprungen.
- Live-Verweis und Audio-Archiv (P7, Schlussprüfung): FlowIQ schreibt den Verweis `/tmp/flowiq-live.md`; `/tmp/panotti-live.md` nur nach der Übernahme aus der Vorgänger-App (`panottiLink` in `settings.json`). Das Audio-Archiv ist in den Einstellungen wählbar (Vorgabe `<Ablage>/audio/`).

---

## Anhang M: Live-Erkennung, Cloud und Umschaltung (Fassung 3)

Fakten zu ElevenLabs stammen aus der offiziellen Doku vom 13.11. [D] (Quellen und Einzelheiten privat in `local/phase2/recherche-elevenlabs-realtime.md`); nichts davon ist mit einem Schlüssel ausprobiert.

### M.1 Wahl je Betriebsart

Die Deutung der Projektsteuerung (je Betriebsart Live-Erkenner, Nachlauf, Sprache wählbar; Schlüssel nur im Schlüsselbund) trägt, mit zwei Einschränkungen beim Diktat.

| Betriebsart | Live-Erkennung | Nachlauf | Sprache |
|---|---|---|---|
| Diktat | Apple lokal, in v1 fest (K-26) | aus oder ElevenLabs, **Vorgabe an** (Entscheid der Projektsteuerung, wie die Vorgänger-App); Upload erst nach dem Einfügen, Ergebnis nur für Historie und Korrektur-Vorschläge | Deutsch (R-026); Englisch bleibt v1.1 (R-027, K-26) |
| Call | Apple lokal oder ElevenLabs Realtime | aus oder ElevenLabs | Deutsch oder Englisch, je Aufnahme |
| Raum | wie Call | wie Call | wie Call |
| Geräte-Import | keine (Dateien), Erkennung lokal | aus oder ElevenLabs (eigener Schalter, R-064) | je Geräteprofil |

- **Warum Diktat-Live lokal bleibt:** der Fn-Pfad lebt von der Pille unter 50 ms und dem vollständigen ersten Wort. Eine Cloud-Verbindung lässt sich nicht warm halten: der Dienst schließt nach 15 s ohne Nachricht, und jede gesendete Sekunde wird abgerechnet, Stille eingeschlossen [D]. Ein Verbindungsaufbau je Tastendruck legt Handshake und Netzlaufzeit vor jedes Ergebnis [E]. Die Schnittstelle (M.2) lässt Cloud-Diktat später als reine Richtlinienänderung zu.
- **R-067 neu** (Entscheid der Projektsteuerung, `ABNAHME.md` Änderungsprotokoll): Diktat-Audio verlässt den Mac nur, wenn der Diktat-Nachlauf eingeschaltet ist; ohne Schalter wird nie etwas hochgeladen. Der Korrektur-Kreislauf nutzt den Nachlauf nur als Vorschlagsquelle (N.3).
- **Einstellungen:** im Bereich Aufnahme eine kleine Tabelle (Zeilen Diktat, Call, Raum, Geräte; Spalten Live, Nachlauf, Sprache) aus Segmentschaltern; ausgegraute Felder, wo die Wahl nicht besteht; ElevenLabs ausgegraut, solange kein Schlüssel hinterlegt ist. Ein Aufklapper nennt Kosten, Datenhaltung beim Dienst (K-32) und dass bestätigte Begriffe mitgehen.
- **Werte:** `struct ModeConfig { live: LiveEngine; post: PostEngine; language: RecordingLanguage }` je Betriebsart in `settings.json`. Vorgaben: Live Apple lokal, Nachlauf Diktat an, Call und Raum wie die Schalter der Vorgänger-App bei der Übernahme, Geräte wie die Vorgänger-App, Sprache Deutsch.
- **Kurzbefehle:** die vier Start-Kurzbefehle (R-056) starten mit der Vorgabe ihrer Betriebsart. "Live-Quelle umschalten" (K-29) hat seit 16.11. keine eigene Taste mehr (⌘⌥E bedeutet zusammen mit U oder R Englisch); die Wahl steht im Menü je laufender Aufnahme ("Live über ElevenLabs") und wechselt deren Live-Quelle (M.3). Das reine Modell `LiveSourceShortcut` bleibt für die eingefrorenen P5-Tests stehen, die App ruft es nicht mehr.

### M.2 Schnittstellen

```swift
// FlowIQCore: neutral, ohne Netz, ohne Speech-Import
public enum LiveEngine: String, Codable, Sendable { case appleLocal, elevenLabsRealtime }
public enum PostEngine: String, Codable, Sendable { case off, elevenLabs }
public struct TimedWord: Sendable, Codable { let text: String; let start: Double; let end: Double; let confidence: Double? }
public struct LiveSegment: Sendable, Codable { let words: [TimedWord]; let speaker: String? }   // Sekunden ab Aufnahmestart
public enum LiveEvent: Sendable { case partial(String), committed(LiveSegment), failure(LiveFailure), sent(seconds: Double) }
public protocol LiveRecognizer: Sendable {
    var engine: LiveEngine { get }
    func start(_ setup: LiveSetup) async throws          // Sprache, Begriffe, Zeitanker, Quelle (Mikrofon, Desktop)
    func feed(_ chunk: AudioChunk)                        // blockiert nie
    var events: AsyncStream<LiveEvent> { get }
    func finish() async                                   // letzter Commit, dann zu
}
public protocol PostProcessor: Sendable {
    var name: String { get }                              // "elevenlabs-scribe-v3"
    func process(_ job: PostJob) async throws -> PostTranscript
}
```

Umsetzungen: `AppleLiveRecognizer` (`FlowIQSpeech`), `ElevenLabsLiveRecognizer` und `ElevenLabsBatch` (`FlowIQCloud`). Keine Umsetzung kennt die andere; die App wählt über `LiveEngine` und `PostEngine`. Eine dritte Umsetzung braucht eine Datei und einen Enum-Fall.

### M.3 Schatten und Übergabe

- Ist für eine Aufnahme ElevenLabs gewählt, läuft Apple lokal trotzdem mit, als **Schatten**. Der `LiveRouter` (`FlowIQSpeech`, rein, testbar) bekommt die Ereignisse beider Erkenner im Zeitraster der Aufnahme und entscheidet, welche Wörter in die Live-Datei gehen. Schatten-Beiträge landen nur im Sitzungsjournal `laufend/live-<id>.jsonl`.
- **Übergabe an einer Zeitmarke B** = Ende des letzten fertigen Beitrags der bisherigen Quelle. Von der neuen Quelle gehen nur Wörter mit Wortmitte ab B in die Datei (Änderung 15.11.2026, Projektsteuerung nach der P5-Prüfung (e): vorher "Start ab B"; so verlieren oder doppeln um bis zu ein halbes Wort versetzte Zeitstempel beider Quellen nichts, Beleg `RouterJitterTests`) (Wortzeiten: Apple `audioTimeRange`, ElevenLabs `include_timestamps=true`). Keine Lücke, keine Doppelung. In der Datei steht eine kursive Zeile `_[MM:SS] Live-Erkennung: ElevenLabs_` bzw. `_[MM:SS] Live-Erkennung: Apple lokal (Netzfehler)_`; das Zeilenmuster der Abnehmer (`^\*\*\[\d`) trifft sie nicht.
- **Wechsel mitten in der Aufnahme ist erlaubt** (Menü, Kurzbefehl), weil Apple ohnehin läuft und nur die schreibende Quelle getauscht wird. **Die Sprache nur vor dem Start:** beide Erkenner sind je Sitzung auf eine Sprache festgelegt, eine Datei hat einen `sprache:`-Wert, und ein Kleben der Sprache hat die Vorgänger-App schon einmal Vorlesungen zerstört (R-057).
- Kosten des Schattens: Apples Sprachdienst lag bei der Vorgänger-App im Call bei 2,5 % CPU im Median [G, Phase-1-Messung A1]. Dafür gibt es lückenlosen Rückfall und eine kostenlose Vergleichsfassung.

### M.4 ElevenLabs Realtime in `FlowIQCloud`

| Punkt | Festlegung |
|---|---|
| Verbindung | `wss://api.elevenlabs.io/v1/speech-to-text/realtime`, Kopfzeile `xi-api-key` aus dem Schlüsselbund; kein Einmal-Token, nie Schlüssel in der URL |
| Parameter | `model_id=scribe_v3_live` (K-27), `audio_format=pcm_16000`, `language_code` der Aufnahme (`de` oder `en`, fest), `commit_strategy=manual`, `include_timestamps=true`, `keyterms` aus bestätigten Lexikon-Einträgen (höchstens 50, je höchstens 20 Zeichen, K-28); Desktopspur mit `diarize=true` |
| Sitzungen | eine je Spur: Call 2, Raum 1, Raum plus Call mit gemeinsamem Mikrofon 2 (Erkenner je Quelle, A.6); Tarifgrenzen laut Doku 6 bis 45 gleichzeitige Sitzungen |
| Audio | 16 kHz mono PCM16, Pakete zu 200 ms, base64, ein Wandler im Modul |
| Commit | an eigenen Pausen (mindestens 400 ms unter der Sprachschwelle, Pegel aus dem Dirigenten), spätestens nach 15 s, nie öfter als alle 3 s. Die Doku empfiehlt 20 bis 30 s und committet von selbst nach rund 36 s; 15 s hält R-053 |
| Teilergebnisse | werden zur flüchtigen Schlusszeile; fertige Beiträge gehen durch die Textstufe (N.4) und dann in die Datei |
| Sprecher | Mikrofonspur: Sprechername; Desktopspur: `Gegenseite` bzw. `Gegenseite (speaker_n)` wie die Endfassung der Vorgänger-App. `speakers_merged` nur ins Journal, weil die Datei nur wächst; die Endfassung bereinigt |
| Echo | Echo-Filter (B51) auf den Wortzeiten beider Spuren wie bei Apple |

### M.5 Rückfall ohne Lücke

1. **Kurzer Abbruch** (Verbindung zu, `session_time_limit_exceeded`, `rate_limited`, `resource_exhausted`, `transcriber_error`, `queue_overflow`): neue Sitzung in höchstens 1 s; erstes Paket mit `previous_text` (letzte höchstens 50 Zeichen) und dem vorgehaltenen Audio seit dem letzten Commit (Ring, höchstens 40 s), dann weiter live. Vorsorglich neue Sitzung alle 30 Minuten an einer Pause (K-31).
2. **Längerer Ausfall** (Wiederverbindung scheitert binnen 5 s, `auth_error`, `quota_exceeded`, `unaccepted_terms`, Netz weg, Monatsgrenze erreicht): Übergabe an den Apple-Schatten an der Zeitmarke B (M.3), Marke an der Pille, Zeile in der Datei, Ereignis. Neuer Cloud-Versuch jede Minute, solange Netz und Schlüssel gültig sind, Rückkehr an einer Pause; höchstens 3 automatische Wechsel je Aufnahme, danach bleibt Apple und das Menü bietet den Wechsel an.
3. Die Audiodateien sind davon unberührt: der Schreiber hängt am Dirigenten, nicht am Erkenner.

### M.6 Sichtbarkeit

- Solange eine Realtime-Sitzung Audio sendet oder ein Nachlauf hochlädt, tragen Aufnahme-Pille und Menüleisten-Symbol eine kleine Wolken-Marke (Linie, ungefüllt). Die Marke folgt dem Senden, nicht der Einstellung: erstes Paket bis Marke an und letztes Paket bis Marke aus je höchstens 1 s. Beim Diktat-Nachlauf erscheint sie nur am Menüleisten-Symbol, weil die Pille dann schon aus ist.
- Menü je laufender Aufnahme: Live-Quelle, Zustand (sendet, Rückfall, wartet auf Netz), Cloud-Minuten dieser Aufnahme.

### M.7 Schlüssel

Eingabe im Einstellungsbereich Aufnahme, Ablage nur im Schlüsselbund (eigener Dienstname je Profil), Lesen nur in `FlowIQCloud`, Übergabe nur als Kopfzeile. Nie in `settings.json`, im Protokoll, im Journal oder in einer URL. Übernahme aus der bisherigen `.env` nur auf Klick (R-066). Test: ein Testschlüssel kommt nach der Eingabe in keiner Datei des Datenordners vor.

### M.8 Verbrauch gehört in v1

Cloud-Live rechnet jede gesendete Sekunde ab, ein Call zwei Spuren; laut Preisseite 0,22 USD je Stunde und Spur, mit Begriffen 0,30 USD, Nachlauf 0,20 USD [D]. Ohne Zähler wäre Cloud-Live ein blindes Abo, und ein leeres Kontingent war der Auslöser des ganzen Vorhabens. Deshalb wird R-063 (Soll) in Fassung 3 durch R-101 (Muss) überholt:

- Zähler je Quelle (Diktat, Call-Mikrofon, Call-Desktop, Raum, Gerät) und Art (live, Nachlauf) in Sekunden gesendeten Audios, je Monat, Datei `cloud/verbrauch.json`; Menüzeile "Cloud diesen Monat" ausklappbar.
- Optionale Monatsgrenze in Minuten (Vorgabe aus, K-30): bei 100 % schaltet Live lückenlos auf Apple (M.5), Nachlauf hält an, beides sichtbar.
- Keine Beträge, nur Minuten: die Abrechnung ist kontoabhängig; der Aufklapper nennt die öffentlichen Preise mit Datum.

### M.9 Netzcode: `FlowIQCloud`

`FlowIQPost` wird zu `FlowIQCloud` und bleibt das einzige Modul mit Netz: Realtime-Sitzungen, Nachlauf-Warteschlange, `NWPathMonitor`, Schlüsselbund, Verbrauchszähler, Cloud-Richtlinie (`CloudPolicy.allows(_:for:)`: Diktat-Live nie, Diktat-Nachlauf nur mit Schalter). Begründung: eine prüfbare Stelle für alles, was den Mac verlässt, ein Schlüsselhalter, ein Zähler; `FlowIQSpeech` bleibt netzfrei. Ein eigenes zweites Netzmodul neben dem Nachlauf würde Schlüssel, Fehlerabbildung und Zähler doppeln. Umbenennung von Ordner, `budget.tsv`-Zeile und Prüfregel in `check.sh` mit P5a.

### M.10 Vertrag: Kopfzeilen und Zeilen

| Schlüssel | Wert | wann geschrieben |
|---|---|---|
| `live_quelle` (neu) | `apple-lokal`, `elevenlabs-scribe-v3-live` (Modellname), `gemischt` nach einem Wechsel | beim Start mit der Startquelle; beim Stopp endgültig |
| `live_wechsel` (neu) | Liste `MM:SS <quelle> <grund>` | nur beim Stopp, weil die Kopfzeilen während `live-stream` fest bleiben; während der Aufnahme stehen Wechsel als kursive Zeilen im Text |
| `nachlauf_quelle` (neu) | zum Beispiel `elevenlabs-scribe-v3` | bei der Aufwertung |
| `cloud_minuten` (neu) | gesendete Minuten dieser Aufnahme, live plus Nachlauf | beim Stopp, ergänzt bei der Aufwertung |
| `panotti_live`, `panotti_phase`, `status`, `pipeline` | Werte und Bedeutung unverändert; die Phase beschreibt den Lebenslauf der Datei, nicht den Erkenner | wie bisher |

Abnehmer: das Live-Leseskript liest Status, Phase und das Zeilenmuster und bleibt unberührt; die Skills ignorieren unbekannte Schlüssel heute und lernen die neuen über die Wechsel-Checkliste (Anhang L, Zeile 12).

---

## Anhang N: Korrektur-Kreislauf (Fassung 3)

Fachliche Vorlage ist das Lexikon-Konzept Fassung 2, Abschnitt 11, mit der Messung `local/phase2/wiederkehrende-fehler.md` (privat). Hier steht, wo die Teile sitzen und wo die Architektur davon abweicht.

### N.1 Was die Messung sagt

302 Ersetzungspaare wiederholen sich (1.590 Vorkommen), aber nur 207 Vorkommen liegen in lernbaren Klassen (Name, Fachbegriff, Denglisch, Abkürzung); Umgangsformen und Verwechslungen richtiger Wörter dürfen nie gelernt werden. Ein Paar-Gedächtnis mit Klick behebt in einer zeitlichen Probe 42 % bei 0 Schaden; Lernen aus einem einzigen Fall bringt 55 % mit 7 Schäden. Fehlformen eines Namens wechseln (133 Fehlformen für 54 Einträge). Folge: zuerst das **Ziel** bestätigen, dann wirken Hörvariante, Lautabgleich (R3) und Begriffe an der Quelle zusammen [K, Prüfung].

### N.2 Fenster "Letztes Diktat korrigieren"

1. Aufruf über Kurzbefehl (K-29) oder Menü. Ein kleines Fenster zeigt die letzten Diktate als Wortfolge; Diktattext erscheint nur hier und nur auf Wunsch (R-021 bleibt gewahrt). Das Fenster wird Key, weil getippt werden darf, und gibt den Fokus danach an die vorherige App zurück.
2. Wort anklicken oder über mehrere ziehen: Auswahl aus den Alternativen des Erkenners an der Stelle (aus den Segment-Alternativen der Spur, bis 3), den klanglich nächsten bestätigten Einträgen (bis 3), der Rohform, freier Eingabe. Ein Klick übernimmt. War die Stelle ein Eingriff von FlowIQ, steht zusätzlich "war richtig" zur Wahl (Ablehnung genau dieses Eingriffs). Die Schaltfläche "Rohfassung" ersetzt den eigenen Menüweg aus Fassung 2 (R-034).
3. **Ersetzen im Zielfeld, wenn möglich** (K-35, Abweichung vom Lexikon-Konzept 11.1 Punkt 5, weil die Projektsteuerung es so beauftragt): `FlowIQInsert.replaceInLastInsertion(range:with:)`. Ist das Feld über Bedienungshilfen lesbar und steht der eingefügte Text dort unverändert, wird genau der Bereich markiert und ersetzt. Sonst, wenn seit dem Einfügen keine Taste kam und die Ziel-App vorn ist, ⌘Z und Neu-Einfügen des korrigierten Ganzen. Sonst landet der korrigierte Text in der Zwischenablage mit Hinweis. Feldinhalte werden nur verglichen, nie gespeichert. Ergebnis ins Journal.
4. Wirkung je Quelle wie im Konzept: Quelle kein richtiges Wort heißt Ziel bestätigt (der Klick ist die Bestätigung, Regel I1) und Hörvariante in Bewährung; Quelle ein richtiges Wort heißt einmalige Frage "immer", "nur neben <Nachbarwort>" oder "nur dieses Mal"; Verwechslung zweier normaler Wörter wird gezählt und erzeugt keine Regel.

### N.3 Kontobuch, Bewährung, Nachlauf als Vorschlagsquelle

- `PairAligner` (rein, `FlowIQText`): Wortausrichtung, gemeinsam mit `flowiq-tool replay`, deshalb nicht mehr im Werkzeug.
- `CorrectionLedger` (`FlowIQStore`, Teil `LexiconStore`): je Paar Sichtungen, Gegenbelege, Zustand; Bündeln je Ziel. Bewährung über das Journal mit `Probation.evaluate` (`FlowIQText`, rein), im Leerlauf mit niedriger Priorität.
- Nachlauf (alle Betriebsarten mit eingeschaltetem Nachlauf, also auch Diktate): nach jeder Aufwertung lokale Fassung gegen Nachlauf-Fassung ausrichten, beide Seiten vorher auf den Kanon gebracht. Paare werden **nie von selbst Regel**; ab 2 Aufnahmen an 2 Tagen ohne Gegenbeleg erscheinen sie als Vorschlag, die Nachlauf-Schreibung gekennzeichnet ("gesehen bei ElevenLabs"). Paare aus zwei normalen Wörtern ohne Eintrag werden verworfen.
- Nach dem Klick: neue Fehlformen zu einem schon bestätigten Ziel werden ohne weiteren Klick aktiv, wenn ihre Quelle kein richtiges Wort ist und die Bewährung bestanden ist; alles andere fragt.

### N.4 Dauerhafte Wirkung

- Die Textstufe läuft deterministisch mit demselben Lexikon-Schnappschuss auf jedem Text: Diktat, jeder fertige Live-Beitrag beider Quellen vor dem Anhängen, lokale Endfassung, Nachlauf-Ergebnis vor dem Ersetzen, Geräte-Transkript. Spur je Beitrag im Sitzungsjournal; Budget je Beitrag wie R-036.
- Bestätigte Einträge gehen als Begriffe an die Erkenner: Apple nach K-01, ElevenLabs Realtime (`keyterms`, höchstens 50) und Nachlauf (höchstens 100).
- **Dauerfälle:** jede bestätigte Korrektur wird als Prüffall gespeichert und läuft bei jeder Bewährung, jeder Schwellenänderung und jeder Änderung der Schutzliste mit. Eine Änderung, die einen Dauerfall bricht, wird nicht aktiv, sondern gemeldet.
- Gespeicherte Vault-Transkripte werden nie nachträglich umgeschrieben.

### N.5 Reparatur

Eine Hörvariante zeigt auf die Kennung eines Eintrags, nie auf eine Schreibweise; ändert der Besitzer die Schreibweise, stimmen alle Varianten im selben Moment. Die Signale S1 bis S8 des Konzepts (Rohfassung, "war richtig", Gegenkorrektur, Widerspruch zum Nachlauf ab 2 Aufnahmen, Bewährungslauf trifft Geschütztes oder bricht einen Dauerfall, Zielkonflikt, 90 Tage ohne Treffer, Eintrag mit 2 Ablehnungen) setzen die Regel aus oder legen sie still und setzen sie auf die Liste "Zum Prüfen" im Bereich Wörter, mit Grund, Treffern, Schaden und den letzten zwei Stellen; je Zeile ein Klick (wieder aktiv, endgültig aus, Ziel ändern). Kopfzeile der Liste: Einträge, aktive, ausgesetzte und ruhende Regeln, letzter Bewährungslauf (R-031). Nichts wird gelöscht.

### N.6 Kennzahl Wiederholungsfehler

Definition wie Lexikon-Konzept 11.5: Fehlerpaare aus dem Wortvergleich Erkennertext gegen Goldsatz-Referenz, wiederkehrend in mindestens 2 Diktaten, lernbare Klassen nach eingefrorener Klassenregel; gelernt wird nur auf dem Teil "einstellen" (Klicks durch die Referenz ersetzt), gemessen einmal auf dem zurückgehaltenen Teil.

| Kennzahl | Schwelle (Vorschlag) | Begründung |
|---|---|---|
| W: Anteil behobener Vorkommen wiederkehrender Paare | mindestens 50 % | die Probe mit reinem Paar-Gedächtnis kam auf 42 % bei 0 Schaden; Lautabgleich und Begriffe an der Quelle sollen mehr bringen, ihr Beitrag ist aber noch nicht gemessen. 50 % verlangt einen messbaren Gewinn über das Paar-Gedächtnis hinaus, ohne eine ungemessene Zahl zu versprechen |
| W-Ziel: Stellen mit bestätigtem Eintrag in der Referenz, die nach der Textstufe stimmen | mindestens 70 %, zusammen mit Begriffen an der Quelle 95 % (R-029) | gleiche Herleitung; die 95 % sind das bestehende Namensziel |
| neuer Schaden | 0 | hartes Tor wie R-028 |
| Eingriffe auf nicht lernbaren Klassen | 0 | Umgangsform und Verwechslung richtiger Wörter dürfen nie gelernt werden |

Die Schwellen sind Vorschläge; gesenkt werden sie nie ohne Ja des Besitzers. Nach der Einführung schreibt `flowiq-tool protokoll` W monatlich aus dem eigenen Journal fort.

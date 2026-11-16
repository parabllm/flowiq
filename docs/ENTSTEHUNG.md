# Entstehung von FlowIQ

Bauverlauf der Version 1 nach Paketen (P1 bis P5), Stand je Abschnitt wie im Titel datiert. Diese Seite ist ein
Rückblick: wer FlowIQ bauen oder benutzen will, braucht sie nicht (dafür `../README.md`). Die Abschnitte stehen in
der Reihenfolge, in der sie entstanden sind, und beschreiben den Stand ihres Datums, nicht den heutigen.

Zum Lesen:

- **`local/` ist privat und fehlt in jedem Klon.** Dort liegen Belege, Messreihen und der Korpus mit echten
  Diktaten. Jeder Pfad mit `local/` auf dieser Seite nennt nur die Herkunft einer Zahl und lässt sich ohne den
  Ordner nicht nachschlagen. Kennzahlen aus dem Korpus sind deshalb von außen nicht nachprüfbar.
- **"Der Besitzer"** ist die Person, für die FlowIQ zuerst gebaut wurde und die Freigaben erteilt hat.
- **"Die Vorgänger-App"** ist die App, die FlowIQ ablöst. Im Code heißt sie Panotti (Bezeichner wie
  `panotti_phase`, Menüpunkt "Panotti-Daten übernehmen"); FlowIQ liest ihre Daten und hält ihr Dateiformat ein.
- **"Prüfung" und "Gegenprüfung"** sind Durchsichten durch getrennte KI-Agenten, die den Code nicht geschrieben
  haben. Kürzel wie R-083, K-24, A.7 verweisen auf `ABNAHME.md` und `ARCHITEKTUR.md`.
- Die Paketnamen: P1 Gerüst, P2 Textstufe und Lexikon, P3 Audio und Aufnahme, P4 Diktat, P5 Ablage, Nachlauf und
  Cloud, P6 Geräte-Import, P7 Oberfläche.

## Stand P1 (13.11.2026, nach Prüfung nachgearbeitet)

Erledigt, belegt durch Lauf (Belege nur lokal unter `local/phase3/belege-p1/`):

- `scripts/check.sh` grün: 0 Warnungen, 44 Tests grün, Datenschutz sauber, keine Verbote, Zeilenbudget und Ausnahmen eingehalten.
- Gegenproben mit absichtlichen Verstößen: alle Muster und Ausnahmen (`gegenprobe-check-static.txt`), 0 und zu wenige Tests (`gegenprobe-tests-gibtesnicht.txt`, `gegenprobe-tests-SettingsTests.txt`), Modul- und GESAMT-Grenze, fehlende Zeile GESAMT (`gegenprobe-zeilenbudget.txt`), Historie und Autor vor dem Push (`gegenprobe-historie.txt`), `budget.tsv` im eigenen Commit (`gegenprobe-pre-commit.txt`), unlesbarer Pin, falsches Team, abweichende Requirement (`gegenprobe-bundle.txt`).
- Drei Dev-Bündel hintereinander mit gleicher Designated Requirement über die Team-Kennung (`drei-buendel.txt`).
- Binär der Vorgänger-App vor und nach der Arbeit gleich (`panotti-pruefsumme.txt`).

Offen:

- Nur mit gestarteter App messbar (mit dem Besitzer): Dev-Profil neben der Vorgänger-App, drei Installationen ohne neue Abfrage (R-083), 10 Minuten Leerlauf RAM und CPU (R-087), Einrichten-Fenster in höchstens 150 ms (`ui.setup.open` endet nach `displayIfNeeded`, nicht nach dem ersten sichtbaren Bild), Abfragen der Berechtigungen abseits des Hauptthreads.
- R-089: Wochenzahlen per Befehl (`flowiq-tool protokoll`) und Schema-Test "Protokoll textfrei" fehlen; heute stehen noch Fehlertexte im Protokoll.
- `BusyState` steht seit P3 bereit, die App ruft ihn ab P4 auf; bis dahin schreibt niemand `laufend/.belegt`, der Wächter in `bundle.sh` greift erst dann.
- Kurzbefehle des Dev-Profils (P4), `OSSignposter`, übrige Pfade und Einstellungsfelder aus A.1 mit ihren Paketen.
- Protokoll rolliert über 4 × 10 MB plus Fehler 2 × 5 MB (höchstens 50 MB nach R-089); Anhang A.2 nennt noch 5 × 10 MB.
- Signatur-Identität und Team wurden automatisch gewählt; der Besitzer bestätigt sie mit `CONFIRMED=yes` in `local/signing.env`.
- Autor-Adresse der bisherigen Commits ist privat; der Pre-Push-Haken blockiert deshalb, Entscheidung vor dem ersten Push beim Besitzer (K-24).

## Stand P2a (13.11.2026, Textstufe ohne neu erkannten Rohtext)

Gebaut: `FlowIQText` nach A.7, `SystemWordOracle` in der App (noch nicht angeschlossen, das Diktat kommt mit P4), `flowiq-tool replay`, `schutzliste`, `vorschlaege` (Import und Export der Vorschlagsliste; die Liste mit den vier Knöpfen in der App fehlt noch), `erkennen` als Gerüst bis K-01. `scripts/korpus-lauf.sh` fährt den Drei-Wege-Lauf: `replay`, dann `zaehlregel-v1.py` (Prüfsumme geprüft) je Weg; alles mit Diktattext bleibt unter `local/`.

Belegt durch Lauf (Test oder Korpus):

- P2-Abnahmetests (`abnahme-tests/p2`, Testziel `FlowIQP2Tests`) grün, dazu `FlowIQTextTests` und `FlowIQToolTests`. Geändert ist genau eine `// ASSUMPTION:`-Zeile: die Tests schalten R3 ein (`TextStageConfig(spokenForm: true)`), weil R3 hinter einem Schalter mit Vorgabe aus liegt. Mit der Vorgabe (R3 aus) laufen 68 der 73 grün; rot sind genau die 5, die R3 prüfen (Sprechform stark, R3-Spur, drei Regelarten, vollständige Spur mit "3BQ", sechs R3 unter der Bremse) [Test, einmal gelaufen 13.11.]. Durchreichen, Schutz, keine Glättung und Idempotenz belegt zusätzlich `DefaultConfigTests` mit R3 aus.
- Drei-Wege-Lauf **vorläufig** (Korpus-Lauf 13.11., Teil "einstellen", 239 Diktate; Rohtext ist der gespeicherte `rawText` der Vorgänger-App, also schon von deren erster Stufe bearbeitet; Zählregel `zaehlregel-v1`, Prüfsumme geprüft). Je Weg Durchreichen / Vorgänger-Endtext / FlowIQ / FlowIQ mit R3: schädliche Eingriffe 0 / 81 in 49 Diktaten / 0 / 0; hilfreiche 0 / 45 in 30 / 21 in 13 / 27 in 17; IQ-Namen richtig geschrieben von 45 Stellen der Referenz 7 / 13 / 28 / 33. R3 berührt zusätzlich 5 Stellen mit anderen Namen, die die Zählregel als strittig führt. Private Fassung: `local/phase3/p2/drei-wege-vorlaeufig.md`.
- Laufzeit der Textstufe im Debug-Bau mit R3 und 73 bestätigten Einträgen: 239 Diktate p50 1,1 ms, p95 5,8 ms, max 16,3 ms; ganzer Verlauf (2.385 Diktate) p95 3,7 ms, max 38 ms, Lauf samt Systemwörterbuch 11 s. P2-Leistungstest (500 künstliche Diktate, Debug) bestanden.

Abweichungen und Entscheidungen:

- R3 (Sprechform) ist gebaut, aber per Vorgabe aus (`TextStageConfig.spokenForm`), bis der Drei-Wege-Lauf auf neu erkanntem Audio den Mehrwert zeigt (Streichliste Nr. 3).
- Schutz P3 "englischer Stamm plus deutsche Endung": Endungen `-en -e -t -st -te -ten -et` plus `-est` und `-tet` (sonst bleiben "refundest", "committet" ungeschützt), doppelter Endkonsonant wird auch einfach gefragt ("committ" zu "commit").
- Zögermarken werden nicht entfernt, nur Steuerreste wie `\letter`: wie der neue Erkenner zögert, ist noch nicht gezählt.
- Z1 entsteht über Bindestrich-Teile: eine Spanne endet am Bindestrich, der Rest bleibt stehen.
- `flowiq-tool` schreibt wie das Entwicklungsprofil nur über `SafeFS` unter `<wurzel>/FlowIQ-Dev/`; Vorgabe für `--wurzel` ist der echte Datenordner, Korpus-Läufe geben einen Ordner unter `local/` an.

Offen:

- Schwellen bleiben vorläufig (L-4); der Lauf auf neu erkanntem Rohtext (P2b, unten) zeigt keine Schwellenänderung, die verfehlte IQ-Stellen ohne neues Risiko rettet, sie sind deshalb unverändert.
- Mengenbremse: der Anteil über 15 % blockiert R3 in jedem Diktat unter 7 Teilen, also auch ein Diktat, das nur aus einem Namen besteht ("drei be ku"). Vorschlag an den Besitzer: Anteil gegen `max(Teile, 20)` rechnen; alle P2-Abnahmetests blieben grün (gegengerechnet, nicht gelaufen). Nicht umgesetzt.
- Nacharbeit nach Prüfung (13.11.): Großfolgen bis 5 Zeichen sind auch in gemischten Spannen nie R3-Quelle (Beinahe-Treffer "Abkürzung"); ein in Großbuchstaben geschriebenes bekanntes Wort ("NEIN") bleibt geschützt, weil erst das Wörterbuch gefragt wird; mehrere Wörter, die alle geschützt sind, ändert R1 nicht mehr, nur eine aktive, angeklickte Hörvariante; Wort auf Wort nur mit `replacesProtectedWord` und Herkunft Klick. Je ein Test, der gegen den Stand 4be49fc rot ist. Die Familienregel fängt die IQ-Formen aus geschützten Teilen weiter ("Studio IQ").
- Vorschlagsliste in der App (A.12), Anschluss des Orakels an das Diktat (P4), Spalte "nur wegen P3 entfallen" im `replay` (Risiko R-2 der Gegenprüfung), Test "gleiche Antworten auf Haupt- und Hintergrund-Queue" in der laufenden App.

## Stand P2b (13.11.2026, neu erkannter Rohtext)

- K-01 (Mess-Agent, Spike): SpeechTranscriber de-DE ohne Kontextbegriffe und ohne eigenes Sprachmodell. `flowiq-tool erkennen` hat alle 2.371 nutzbaren Diktat-Audios (über 2.048 Byte, Original nur gelesen) neu erkannt: 0 Fehler, 8,7 h Audio, 420 s Rechenzeit, 7 min Wanduhr, keine Pause [Korpus-Lauf 13.11., 14:50 bis 14:57]. Ergebnis privat unter `local/korpus/neu-erkannt/`.
- Drei-Wege-Lauf auf dem neu erkannten Rohtext, Teil "einstellen" (239 Diktate, `zaehlregel-v1`, Prüfsumme geprüft) [Korpus-Lauf 13.11.]. Je Weg Durchreichen / Vorgänger-Endtext (gegen den eigenen Rohtext der Vorgänger-App, deren Logik ist nicht ohne Aufwand portierbar) / FlowIQ / FlowIQ mit R3: schädliche Eingriffe 0 / 81 in 49 Diktaten / 0 / 0; hilfreiche 0 / 45 in 30 / 21 in 13 / 29 in 17. IQ-Namen richtig nach der eingefrorenen `namensregel-v1` (privat neben der Zählregel, Prüfsumme): von 45 Stellen 0 / 13 / 21 / 28, davon TreibIQ (13 Stellen) 0 / 1 / 0 / 4. "0 schädlich" gilt für FlowIQ ohne R3 ganz; mit R3 nur für Text und IQ-Namen: 13 R3-Stellen anderer Namen führt die Zählregel als strittig (C4), sie sind weder als Schaden noch als Nutzen belegt und gehen vor dem Einschalten von R3 als Vorschläge an den Besitzer (Liste privat). Nach der Nacharbeit unverändert, nur 8 Mehrwort-R1 anderer Namen ("Open Code" und ähnliche) warten jetzt auf einen Klick [Vorher-Nachher-Lauf 13.11.]. Textstufe im Debug-Bau p95 2,9 ms, max 7,1 ms.
- Das Namenstor (95 %) ist mit diesem Erkennertext nicht erreichbar: von 17 verfehlten IQ-Stellen liefert der Erkenner 14-mal kein Stück, das eine Regel ohne neues Risiko fassen kann (echtes anderes Wort, Stamm fehlt, Stelle fehlt, Abkürzung, an Nachbarwort geklebt); jede Fehlform kommt im Teil "einstellen" nur in einem Diktat vor, eine Hörvariante kann die Bewährung (2 Treffer in 2 Diktaten) also nicht bestehen. Apples Segment-Alternativen enthalten an diesen Stellen keine zusätzliche erkennbare Form. Einzelfälle privat unter `local/phase3/p2/iq-verfehlt/`.
- Wortverlust in langen Dateien behoben: Ursache war die Zufuhr der ganzen Datei als ein einziger Puffer; der Datei-Lauf gibt jetzt 1-s-Puffer (Frist und Rotation waren nicht beteiligt, die Läufe blieben weit unter der Frist). Beleg [Korpus-Lauf 13.11.]: Wortzahl alt / neu / ElevenLabs bei 194 s 413 / 536 / 573, bei 232 s 431 / 629 / 679, bei 1.193 s 285 / 658 / 923, bei 171 s 1 / 20 / 21; Gesamtlauf neu (2.371 Audios, 0 Fehler, 249 s Rechenzeit) mit Wortfehlerrate ohne Namen 17,9 % statt 18,6 % und 1.084 statt 1.870 verworfenen Wörtern; 2.363 Texte unverändert. Test `SlicesTests`. Die Kennzahlen des Teils "einstellen" bleiben gleich.
- Mengenbremse rechnet den R3-Anteil gegen max(Teile, 20) (Entscheid der Projektsteuerung, Vermerk in `docs/LEXIKON-KONZEPT.md`): ein Diktat, das nur aus einem Namen besteht, wird korrigiert (Test). Vorher-Nachher auf "einstellen": unverändert, Schaden 0, weil seit der Abkürzungsregel dort keine Bremsung mehr vorkam. Kein Abnahmetest hängt an der alten Formel.
- **K-01 im Korpus festgemacht** [Korpus-Lauf 13.11., Regel vorher festgeschrieben und per Prüfsumme belegt]: paarweise auf 300 zufälligen Diktaten (Teil "einstellen" plus Nicht-Goldsatz, Startwert 2026111304, Tresor zu), gleiche Zufuhr für beide (Reservierung, 160 ms Stille, Abschluss bis Ende der Eingabe). Wortfehlerrate ohne Namen SpeechTranscriber 18,9 %, DictationTranscriber 30,0 % (DT je Clip 37-mal besser, 174-mal schlechter, Median +1 Fehler); verworfene Satzteile ab 3 Wörtern 243 gegen 975 Wörter (12 besser, 53 schlechter); andere Namen 61 gegen 51 von 110; Rechenzeit 11,5 gegen 41,6 ms je Audiosekunde. Entscheid nach Regel: SpeechTranscriber bleibt. Das Zählskript des Spikes ist geprüft (die gleichen 65 Fehler der vier DT-Varianten sind erklärt, kein Zählfehler).
- **Namen über alle Lexikon-Einträge** (Besitzer 13.11.: IQ war nur ein Beispiel): eingefrorene `namensregel-v2` zählt jede bestätigte Schreibweise aus `lexikon-start.tsv` an jeder Referenzstelle des Teils "einstellen", strittige Stellen getrennt; `namensregel-v1` (nur IQ) bleibt als Unterzeile. Je Weg Durchreichen / Vorgänger-Endtext / FlowIQ / FlowIQ mit R3: v2 73 / 120 / 99 / 110 von 164 Stellen (44,5 / 73,2 / 60,4 / 67,1 %), v1 IQ 0 / 13 / 21 / 28 von 45; strittig getrennt 12 / 26 / 15 / 23 von 93. Der Endtext der Vorgänger-App liegt über FlowIQ; er stammt aus deren eigenem Rohtext, und die Referenz (ElevenLabs) bekam das Wörterbuch der Vorgänger-App als Stichwörter, die Zahl ist also zugunsten der Vorgänger-App verzerrt, aber nicht wegzuerklären.
- Verfehlte Namensstellen (54 von 164 mit R3, 23 Namen) nach Klassen: Form ohne ausreichende Lautnähe oder unbekannt 21, anderes echtes Wort 17, Stelle fehlt im Erkennertext 5, R3-Beinahe-Treffer (Schwelle 3, Abkürzung 3), Mehrwort aus geschützten Wörtern wartet auf Klick 3, gleiche Buchstaben bei geschütztem Einzelwort 2 (heuristisch zugeordnet, Einzelfälle privat unter `local/phase3/p2/namen-verfehlt/`). Allgemeine Wege ohne neuen Schaden: angeklickte Hörvarianten mit Kontext für wiederkehrende echte Wörter (Wort auf Wort nur per Klick), Klick auf die wartenden Mehrwortformen in der Vorschlagsliste. Eine niedrigere R3-Schwelle hilft nicht: Vorher-Nachher-Lauf auf "einstellen" mit 0,80 unverändert, mit 0,75 vier R3 mehr, alle auf strittigen Stellen, v2-Treffer gleich 110, Schaden 0; Schwelle bleibt 0,85.
- Familienregeln sind allgemein: der geschriebene Anker kommt aus der gemeinsamen Endung der Mitglieder im Lexikon, im Code steht keine Familie (Test mit erfundener Familie "Hub"). Die englische Leseregel liest "-que" jetzt als "k", nur "-cue" als "kju".

## Stand P5 (15.11.2026, Rest: Ablage, Nachlauf, Cloud)

- Gebaut: Vault-Vertrag und Live-Datei (`Transcripts.swift`), Nachlauf-Ablage mit Warteschlange (`Aftercare.swift`) in `FlowIQStore`; Naht-Typen (AudioChunk, Live-Naht, PostProcessor, Verbrauch) in `FlowIQCore`; `LiveRouter`, `LiveSession` (Apple-Schatten, Rückfall), `CallLiveFeed` in `FlowIQSpeech`; Wort-Orakel der App am Store; R-117 `keepDictationInClipboard` (Vorgabe an). R-061 gestrichen (K-33).
- Belegt [Test]: check.sh im sauberen Abzug grün, 626 Tests; p5, p5-f3, p4-f3 eingebunden; TEST-FIX Nr. 1 bis 4 nach `local/phase3/pruefung-p5-tests-fable.md`, 3 R-061-Tests abgeschaltet.
- Offen: Call- und Raum-Koordinator und Oberfläche (P7), Wolken-Marke für Live-Pakete, kein echter Cloud-Lauf.

## Stand P2c (13.11.2026, Korrektur-Kreislauf)

Gebaut (nie gestartet; App, Fenster und Bedienungshilfen nur über Nähte getestet):

- Korrekturfenster "Letztes Diktat korrigieren" (⌘⌥K, im Entwicklungsprofil ⌃⌘⌥K, und Menü): Wortfolge des neuesten Diktats, Klick oder Umschalt-Klick wählt, Alternativen des Erkenners (bis 3), klanglich nächste bestätigte Einträge (bis 3), Rohform, freie Eingabe, "war richtig" an Eingriffen, "Rohfassung". Ersetzen über `replaceInLastInsertion` mit `SystemField` (Bedienungshilfen), Fokus zurück an die vorherige App. Lernen über das bestätigte Ziel: Quelle kein richtiges Wort heißt Hörvariante in Bewährung (aktiv, wenn das Ziel schon eine bewährte hat), Quelle ein richtiges Wort heißt einmalige Frage "immer", "nur neben", "nur dieses Mal", zwei normale Wörter werden nur gezählt. Jede Korrektur wird Dauerfall; eine Änderung, die einen Dauerfall bricht, wird nicht aktiv, sondern gemeldet. Nach jedem Lernen läuft die Bewährung über das Journal.
- Vorschlagsliste "Wörter und Vorschläge" (Menü): vorgeschlagene Namen mit änderbarer Schreibweise, Hörvarianten aus dem Kontobuch mit Beleg; je ein Klick "so schreiben" bzw. "Übernehmen", "richtiges Wort" (schützt die Form), "Ablehnen"; Kopfzeile mit Einträgen, aktiven, in Bewährung, ausgesetzten, stillen Regeln und "zum Prüfen". Nur Theme-Rollen.
- Diktat: die Textstufe läuft auf dem `LexiconStore` (bei leerem Speicher einmal aus `lexikon/lexikon-start.tsv` im Datenordner befüllt); das Startlexikon der Erstbefüllung (`local/phase3/p2c/eb-ganz/.../lexikon/`) kann von Hand in den Datenordner kopiert werden.
- Erstbefüllung (`scripts/erstbefuellung.sh`): Kandidaten aus vier Quellen (Nachlauf-Text, Vorgänger-Endtext, Vorgänger-Regeln, Beinahe-Treffer ab 0,70), Ziele nur aus dem Lexikon, Bewährung über den ganzen Korpus ohne zurückgehaltenen Teil (Nutzen, Gegenbeleg, Schaden über `zaehlregel-v1` unverändert); sichere Hörvarianten aktiv, Klick-Liste und strittige Ziele als Vorschläge, Einzelfälle wartend im Kontobuch.

Belegt [Test, Korpus-Lauf 13.11.]:

- `CorrectionLoopTests` (10) und `FlowIQStoreTests` (8) grün; `abnahme-tests/p4-f3` Korrektur, Lernen, Journal, Rohfassung (42 Tests) in einem Prüfziel außerhalb des Repos grün, geändert nur zwei `// ASSUMPTION:`-Zeilen der Stütze (Import `FlowIQCloud` entfällt bis P5, `JournalEntry.recognized` mit Regelnamen). `DictationStaysLocalTests` gehören zu P5.
- Erstbefüllung über 2.105 Diktate: 352 Kandidaten, 11 automatisch, 26 Klick-Liste, 10 Ziel strittig, 88 wartend, 217 verworfen, Schaden 0.
- Teil "einstellen" (239 Diktate; die Erstbefüllung hat ihn mitgesehen, also in der Stichprobe): Namen über alle Stellen (`namensregel-v2`) FlowIQ 99 / 106 / 119 von 164 (Startliste / plus automatische Hörvarianten / plus 20 Klicks der Klick-Liste), mit R3 110 / 112 / 125, Vorgänger-Endtext 120; Schaden nach `zaehlregel-v1` überall 0.
- Kennzahl Wiederholungsfehler, gelernt auf der ersten, gemessen auf der zweiten Hälfte des Nicht-Goldsatz-Korpus (je 933 Diktate, 118 Vorkommen wiederkehrender Paare lernbarer Klassen, Messregel vorher eingefroren): W 0 % (Startliste), 0 % (automatisch), 11,0 % (plus 8 Klicks der Klick-Liste), 28,0 % (plus 11 Kreislauf-Klicks, Klick durch die Referenz ersetzt), mit R3 30,5 %; W-Ziel 16,7 %, mit R3 22,4 %; Schaden 0 ohne R3, mit R3 2 (beide aus einer Schreibweise, die die Simulation aus der Referenz übernahm, in der App ausgeschlossen); nicht lernbare Klassen angefasst nur "Form" (richtige Formvarianten von Namen), Umgangsform und Verwechslung 0. Das vorgeschlagene Tor W ≥ 50 % ist damit nicht erreicht: in 933 Lerndiktaten bestehen nur 11 lernbare Paare die Bremse "2 Diktate, kein Gegenbeleg".
- Einzelheiten, Listen und Konsolen privat unter `local/phase3/p2c/` (`ergebnis.md`).

Abweichungen und Offenes:

- Zeilen: `FlowIQText` 1.392 (Budget 1.270, Grenze 1.400), `FlowIQStore` 893 (850, 930), App 1.999 (1.850, 2.000), `flowiq-tool` 460 (340, 460). Die Erstbefüllung liegt in `FlowIQStore` (`LexiconSeeding`), weil das Werkzeug an der Grenze steht; P5 hat in App, Store und Werkzeug kaum noch Platz. Entscheid zum Budget beim Besitzer.
- Ältere Diktate im Fenster: Schnittstelle vorhanden (`recent`), keine Auswahl in der Oberfläche; die Liste der letzten Diktate lebt nur im Speicher (nach Neustart leer). Erkenner-Alternativen je Wort nur, wenn sie je Wort vorliegen, sonst gegenüber der Stelle in einer Segment-Alternative.
- Liste "Zum Prüfen" mit Klicks "wieder aktiv", "endgültig aus", "Ziel ändern" (N.5) fehlt in der Oberfläche; die Einträge werden gesammelt und in der Kopfzeile gezählt. Signale S4 (Nachlauf, P5a) und S7 (90 Tage) fehlen.
- Geschützte Formen stehen noch nicht im Journal; die Bewährung im Leerlauf rechnet ohne sie (Klick-Varianten betrifft das nicht).

## Stand P2c-N (Nacharbeit nach Prüfung, 14.11.2026)

- L1: ein Klick mit gleichem Schlüssel überschreibt nie eine bestätigte Schreibweise, Umbenennen nur über "Ziel ändern" (Test, rot gegen e75ccc6). L2: Bewährung im Leerlauf mit niedriger Priorität (nach ruhigen 30 s mit neuen Journalzeilen, sonst alle 6 h) und nach jedem Lernklick. L4: Bewährung je Ziel (Belege aller Nichtwort-Formen eines Eintrags zusammen; bewährtes Ziel heißt neue Form nach einer Sichtung aktiv), Erkenner-Alternativen als Beleg. L5: geschützte Formen, Beinahe-Treffer, Eingriffe und Alternativen im Journal. L6: Zielkonflikt (S6) setzt beide aus; Gegenbeleg im Nachlauf an jeder ausgerichteten Stelle, an der der Nachlauf nicht den Eintrag schreibt, auch für vorgeschlagene Paare. L7: blockierte Änderung wird gemeldet. S4, S5 aktiv, S7 (90 Tage, "ruhend"), S8 (zwei Ablehnungen).
- Liste "Wörter": Erstimport "Panotti-Daten übernehmen" (Panotti ist der Name der Vorgänger-App) (Trockenlauf, ein Klick, nur in ein unverändertes Lexikon), Zum Prüfen mit "wieder aktiv", "endgültig aus", "Ziel ändern", Namen mit "gehört zu", Vorschläge mit "nur neben", strittige Ziele erst nach Entscheid, Kopfzeile mit letztem Bewährungslauf; Korpus-Beleg (Nutzen in 2 Diktaten, Gegenbeleg 0, Schaden 0) macht eine angenommene Zeile sofort aktiv. Neue Namen aus dem Journal (CandidateDetector) als Vorschläge.
- Korrekturfenster: ältere Diktate wählbar (nur das neueste wird im Feld ersetzt, ältere über die Zwischenablage), Verlauf übersteht Neustart. Frage bei echtem Wort mit Zahl früherer Diktate; stand das Wort schon unkorrigiert da, gibt es kein "immer", nur "nur neben" (vorausgewählt) oder "nur dieses Mal" (gemessen: "immer" für solche Wörter brachte 72 Schäden).
- R1 setzt nie mehrere Stücke zu einer Abkürzung zusammen (A.7, Ursache des Falls Nichtanfassen 1 von 685; Test).
- Budget: Erstbefüllung, Startliste, Zählung und Vorschlags-Import laufen als Python `scripts/korpus/korpus.py` (startlexikon, zahlen, erstbefuellung), nur mit Stufenergebnissen aus `flowiq-tool replay`; `LexiconSeeding`, `LexiconSeed`, `erstbefuellung` und `vorschlaege` im Swift-Code entfallen.
- Tests: `abnahme-tests/p4-f3` als Testziel `FlowIQP4F3Tests` (53 von 53, ohne `DictationStaysLocalTests`, das kommt mit P5); zwei Importzeilen mit COMPILE-FIX, keine ASSUMPTION-Zeile geändert. check.sh im sauberen Abzug: 372 Tests.
- Kennzahlen [Korpus-Lauf, die eingefrorene `wiederholungsregel-v1`, Prüfsumme geprüft; gelernt nur auf der Lernhälfte 933, gemessen auf der Messhälfte 933; Klicks simuliert mit fester Regel, Schreibweisen nur aus dem Lexikon]: Startlexikon W 0 % (R3 2,5 %), W-Ziel 1,9 % (7,6 %), Nichtanfassen 0, Schaden 0. Nach Liste und Kreislauf (6 Listenklicks, 31 Fensterklicks): W 18,6 % (R3 21,2 %), W-Ziel 24,2 % (29,9 %), Nichtanfassen 0 von 685, neuer Schaden 0 ("immer" für ein echtes Wort nur bei Lautnähe ab 0,70 zum Ziel, sonst nur "nur neben"). Tore W 50 % und W-Ziel 70 % verfehlt, Entscheid beim Besitzer.

## Stand P4 (13.11.2026, Diktat ohne Korrekturfenster)

Gebaut (nie gestartet, kein Mikrofon, keine echte Taste, kein Einfügen in fremde Apps):

- `FlowIQInput`: Gestenautomat nach A.3 (Halten, Tipp mit 0,36-s-Fenster, Doppeltipp und Taste plus Leertaste sperren, Escape bricht ab, Akkord-Abbruch nur im Entwicklungsprofil, ⌃⌘V bzw. ⌃⌥⌘V fügt erneut ein, Prellschutz 10 ms), `KeyMapper` (Fn im Produktivprofil, ⌥ rechts im Entwicklungsprofil), `InputService` (Pille im Abgriff-Thread, Sitzungszähler, damit ein spätes Ergebnis nie eine neuere Pille löscht), `EventTapSource` (eigener Thread, Wiedereinschalten im Rückruf und alle 30 s, eigene ⌘V und ⌘Z per Kennung übersprungen, `key_late` ab 500 ms), `HotKeys` (Carbon, jedes Ergebnis geprüft, `shortcut_taken`; registriert ⌘⌥ mit U, R, E und K, Drücken und Loslassen), `LanguageChord` (rein: ⌘⌥U und ⌘⌥R allein Deutsch, mit E zusammen Englisch in beliebiger Reihenfolge, ein einzelnes U oder R wartet 150 ms auf ein E, eine laufende Aufnahme stoppt sofort, E allein bewirkt nichts).
- `FlowIQSpeech`: `DictationRecognizer` mit `DictationEnding` (jede Probe ab Tastendruck, dann 160 ms Stille, Abschluss mit Frist 1,35 s, sonst Abbruch und `deadline`) und `AppleDictation` (SpeechTranscriber de-DE nach K-01, Analyzer beim Tastendruck vorbereitet, Audio wartet im Strom; Datei-Lauf über die Spool-Datei mit `FileTranscriber`).
- `FlowIQInsert`: `Inserter` nach A.8 (Fokusprobe zuerst mit 50 ms Frist, nur ein lesbares Nicht-Textfeld verhindert das Einfügen; ist die alte Zwischenablage nicht vollständig lesbar, wird nichts geschrieben; Rückgabe 100 ms nach der Abholung oder nach 2 s ohne Abholung, nur bei eigenem `changeCount`; Einfügungen nacheinander). Dazu `replaceInLastInsertion` für das Korrekturfenster (K-35, N.2 Punkt 3): genau der Bereich im lesbaren Feld, sonst ⌘Z und Neu-Einfügen, sonst Zwischenablage mit Hinweis; die Systemseite `FieldEditing` über Bedienungshilfen fehlt noch und kommt mit dem Fenster.
- `FlowIQStore`: `DictationJournal` (`diktate/journal-YYYY-MM.jsonl`, nur anhängend, Schreiben vor dem Einfügen ohne `fsync`, `fsync` gebündelt danach; Audio unter `diktate/<jahr>/<monat>/<id>.aac`).
- App: `FlowCoordinator` (Mikrofon zuerst, dann Journal `begin`; Pumpe abseits des Actors in Erkenner und Datei; Schwanz fest 110 ms über die eingespeiste Uhr; Größenprüfung; Rückfall auf den Datei-Lauf bei gescheitertem oder überlaufenem Live-Lauf; Spur im Journal: Erkennertext vor jeder Stufe, Eingriffe, Endtext, Sicherheiten, Alternativen, Zeiten, Gerät, Pegel, Lage; `fn.timeline` je Diktat), Pille als nicht aktivierendes Panel mit einer Ebene, Rohfassung per Kurzbefehl.

Belegt [Test]:

- P4-Abnahmetests (`abnahme-tests/p4`, Testziel `FlowIQP4Tests`, per Pfad): 65 von 65 grün, zweimal hintereinander gelaufen. Keine `// ASSUMPTION:`-Zeile geändert, kein `COMPILE-FIX`.
- `abnahme-tests/p4-f3/ReplaceInFieldTests.swift` unverändert in einem Prüfziel außerhalb des Repos (nur die Nähte für das Einfügen aus `P4F3Support.swift`): 11 von 11 grün.
- `FlowIQSpeechTests`: `DictationEndingTests` (Stille an der Rate der Proben, Frist, Fehlerschritte ohne Text); `AppleDictationTests` hinter dem Schalter `FLOWIQ_SPEECH_IT=1`, einmal gelaufen: per `say` erzeugte deutsche Sprache als 10-ms-Stücke über den echten Erkenner erkannt.

Auslegungen und Abweichungen:

- Prellschutz: nur eine Flanke, die etwas bewirkt hat, öffnet das 10-ms-Fenster; eine stumme Freigabe nach Abbruch tut es nicht. Nach verweigertem Mikrofon beginnt der Gestenautomat neu, sonst wäre der nächste Druck ein Doppeltipp.
- Rohfassung: Kurzbefehl ⌘⌥Z, im Entwicklungsprofil ⌃⌥⌘Z. Die Architektur legt keine Taste fest, der Besitzer entscheidet. Kurzbefehle für Call, Raum und Korrigieren sind je Tastenschema hinterlegt (⌘⌥U, ⌘⌥R, Englisch mit E dazu, ⌘⌥K; Ersatztasten mit ⌃ dazu). Die Live-Quelle hat seit 16.11. keine eigene Taste mehr, nur die Menüzeile "Live über ElevenLabs".
- `t0` und der Anfangsverlust (`start_loss_ms`) rechnen Zeitstempel des Fenstersystems und der Aufnahme auf die durchlaufende Uhr um [E]; ob das stimmt, zeigt erst T2.
- Die Pille trägt seit 16.11. keine Marken mehr (Vorlage `local/design/pille-neu.html`): "nicht eingefügt" steht als Zeile im Menü, der Text bleibt per ⌃⌘V abrufbar; ein gescheitertes Diktat hat noch keinen Menü-Hinweis.

Offen:

- `abnahme-tests/p4-f3` ist nicht eingebunden: das Testziel braucht `FlowIQCloud` mit `CloudPolicy` (P5a), Betriebsart-Typen und `LiveRecognizer` in `FlowIQCore` (P5a), `CallLiveFeed` (P5b), `LexiconStore` und `CorrectionLedger` (P2c) und das Korrekturfenster; ohne sie baut das Ziel nicht, und `check.sh` würde rot.
- Nur im Testfenster T2 mit dem Besitzer belegbar: R-013, R-015 (Pille im Bild, echte Taste, Hauptthread-Taster), R-016 (Anfangsverlust mit echtem Mikrofon, K-04), R-017 mit echten Apps, R-018, R-019 und R-020 mit echter Zwischenablage und Bedienungshilfen, R-021, R-022 (echter `SIGKILL`), R-025, R-042, R-067 (Netzprobe), R-083, R-088, Bereitstellung auf Abruf in fünf Apps (K-07), Fn-Taste in Phase 5.
- Gerätebeobachter: nur Anschließen und Trennen; Wechsel des Standard-Eingangs, Deckel und Schlaf fehlen noch.
- Zeilen: `FlowIQInput` 416 (Grenze 430), `FlowIQInsert` 419 (420), Diktat-Teil von `FlowIQSpeech` 196 (Modul 553 von 660), Diktat-Teil der App 527 (App 1.386 von 2.000), `DictationJournal` 101.

## Stand P3 (13.11.2026, Audio und Aufnahme)

Erledigt, belegt durch Test (`swift test`, nur künstliche Quellen, kein Mikrofon, kein Desktop-Ton, keine Berechtigung):

- P3-Abnahmetests (`abnahme-tests/p3/`, Testziel `FlowIQP3Tests`, per Pfad eingebunden): 48 von 48 grün, darunter 3 Stunden Raumaufnahme beschleunigt (Speicher flach, Datei vollständig, höchstens 45 MB je Stunde). Keine `ASSUMPTION`-Zeile musste geändert werden; zwei Kompilierfehler im Testcode selbst sind minimal korrigiert und mit `COMPILE-FIX` markiert, keine Erwartung berührt.
- Eigene Tests `FlowIQAudioTests` (Geräteregel, Halbwarm, Desktop-Neustart mit Erfolg, Rückkehr eines verlorenen Geräts, Datei-Quelle, Bitrate des Kodierers) und `FlowIQRecordingTests` (abgerissene Datei, keine Überschreibung beim Umpacken, Belegt-Datei im Format von `bundle.sh`, fast volle Platte).
- Nacharbeit nach der Prüfung (A1 bis A6, A8) mit je einem Test in `FlowIQRecordingTests` und `FlowIQAudioTests`: Schreibfehler spät in der Aufnahme, Ratenfehler am ersten Puffer, defekter Rahmen mitten in der Datei (mit und ohne bekannten Schreiber), Abbruch beim Umpacken (Teildatei, fertige `.m4a` neben `.aac`), nicht auslieferbarer Ordner, unlesbarer freier Platz, letzter Lease endet während eines Gerätewechsels.
- Schreibweg ohne `eraseFile`: Kodierer schreibt ADTS-Rahmen selbst über einen `SafeFS`-Griff; das `.m4a` legt `SafeFS.createNew` an, Core Audio ohne Löschflag.

Offen:

- Nur mit echter Hardware oder laufender App (Testfenster T1, Phase 4): AirPods-Call und Gerätematrix (R-041, R-042), Deckel und Schlaf (R-049), echter `SIGKILL` nach 1, 30, 120 min und fast volle Platte als Test-Abbild (R-039), Handetiketten-Archiv für den Spurwächter (R-040, K-18), Geräteeigenschaften vor und nach 10 Aufnahmen (R-044), Berechtigungen nach Updates (R-083), Verträglichkeit mit der Vorgänger-App (R-006). `MicrophoneSource`, `DesktopSource` und `SystemDevices` sind gebaut, aber nie gelaufen.
- Schlaf wird weder gefüllt noch markiert: die Host-Uhr steht im Schlaf still, die Markierung braucht die Schlaf-Mitteilung der App (P4).
- Gerätebeobachter (Core Audio, Deckel) an `AudioConductor.updateDevices` binden: P4. `ThrottleGate`: P5, P6.
- Abliefern in den Vault mit Vertragsnamen (`<stamp> mikrofon.m4a`, Raum als `<stamp> raum.m4a`): P5; in `laufend/` heißen die Spuren `mikrofon` und `desktop`.
- Zeilenbudget (seit 511c65b Recording 630/700, Audio 1020/1170): `FlowIQRecording` und `FlowIQCore` über dem Budget, unter der Grenze.
- Aus der Prüfung offen: Frist mit Meldung beim Warten auf die Pumpe im Stopp (A7), Uhrzeit für `consume` im Diktat (A9, P4), Kill-Test mit Kindprozess (A10), `deliver` (P5), Zählung verworfener Ereignisse im Ereignisstrom (A11).

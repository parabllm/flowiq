> Fassung 1 (13.11.2026). Machbarkeitsprüfung in der Gegenprüfung mit sechs Änderungen (L-1 bis L-6): siehe docs/ARCHITEKTUR.md, Abschnitt A.7 und Kopf. Schwellen sind vorläufig, bis sie am Goldsatz-Teil "einstellen" mit neu erkanntem Rohtext eingestellt sind.
>
> Änderung 13.11.2026 (Entscheid der Projektsteuerung, umgesetzt in P2b): Die Mengenbremse (1.6) rechnet den R3-Anteil gegen max(Teile, 20) statt gegen die Teilezahl, damit ein Diktat, das nur aus einem Namen besteht, korrigiert werden darf; die Grenze von 6 R3-Kandidaten bleibt. Vorher-Nachher-Lauf auf dem Teil "einstellen" in `ENTSTEHUNG.md` unter "Stand P2b".

# Lexikon-Konzept: Textstufe von FlowIQ

Stand: 2026-11-13. Autor: Agent "Lexikon" (Phase 2). Gehört zum Modul `FlowIQText` aus `ARCHITEKTUR.md` (Anhang A.7).

Diese Datei enthält keine privaten Daten. Beispiele nutzen nur TapIQ, TreibIQ, StudioIQ, FlowIQ und erfundene Namen ("Marvento", "Kalder"). Die private Startmenge liegt in `local/phase2/lexikon-start.tsv`. `local/` ist ein privater Arbeitsordner des Besitzers und in keinem Klon enthalten; Verweise darauf nennen nur die Herkunft. "Die Vorgänger-App" ist die App, die FlowIQ ablöst (im Code Panotti); TapIQ, TreibIQ und StudioIQ sind Produktnamen des Besitzers, die als Beispiele für schwer erkennbare Eigennamen dienen.

**Auftrag in einem Satz:** Eigennamen stehen automatisch richtig da, und nichts richtig Gesagtes wird verfälscht.

**Belegstufen** (AGENTS.md Regel 5): **[K]** Korpus-Durchlauf mit gespeichertem Skript, **[Z]** gezählt über die Datenkopie mit gespeichertem Skript, **[T]** Test (kleines Programm, einmal gelaufen), **[C]** Code gelesen (Datei:Zeile), **[R]** aus einem Phase-1-Register übernommen, **[A]** Annahme oder Vorschlag ohne Messung. Keine Aussage hier ist "gemessen in der laufenden App".

**Skripte zu allen eigenen Zahlen:** `local/phase2/lexikon-skripte/` (Liste in Abschnitt 10). Datenquelle ist allein die eingefrorene Kopie vom 13.11. (2.500 Diktate plus 243 ältere Texteinträge, zusammen 2.743).

---

## 0. Das Wichtigste

| Nr | Aussage | Beleg |
|---|---|---|
| 1 | Der Normalfall ist Durchreichen. In 59 % der Diktate (1.417 von 2.385 mit Text) steht kein einziges Wort, das dem Systemwörterbuch unbekannt ist. Dort hat die Textstufe nichts zu tun | [Z] `schutz_messung.py` |
| 2 | Drei Regelarten genügen: R1 Formvariante (gleiche Buchstaben, andere Schreibung), R2 Familie (Stamm plus IQ), R3 Sprechform (Aussprache-Abgleich nur auf ungeschützten Wörtern). Dazu bestätigte Hörvarianten | Abschnitt 3 |
| 3 | Prototyp über den Korpus mit 86 Einträgen, Schwelle 0,85: 135 Eingriffe in 109 von 2.743 Diktaten (4,0 %). Von Hand gesichtet: 0 falsch, 1 unklar | [K] `auswertung.py`, Urteil vom Agenten, nicht vom Besitzer |
| 4 | IQ-Familie richtig geschrieben: Rohtext 14, Vorgänger-Endtext 23, Prototyp 49 von 63 erkennbaren Stellen (78 %). Der Rest sind Erkennerfehler ohne Stamm ("TAQ", "T IQ") | [K] `iq_bilanz.py` |
| 5 | Das Ziel 95 % schafft die Textstufe allein nicht. Der Rest muss an der Quelle gelöst werden (Kontextbegriffe oder eigenes Sprachmodell, Klärung K-01) oder über bestätigte Hörvarianten | Folgerung aus 4 |
| 6 | Alle Schwellen sind vorläufig. Sie wurden am Vorgänger-Rohtext eingestellt, der schon von der ersten Textstufe der Vorgänger-App bearbeitet ist, und an denselben Diktaten geprüft. Gültig werden sie erst im Lauf über neu erkanntes Audio mit zurückgehaltener Hälfte | Gegenlesung T-01, Falle F-02 [R] |
| 7 | Zwei Befunde zum Systemwörterbuch ändern den Bau: `NSSpellChecker` winkt jede Großbuchstabenfolge durch ("XQZT" gilt als richtig), und eingedeutschte Verben wie "developen" kennt er nicht | [T] `spell-grossbuchstaben.swift`, `spell.swift` |

---

## 1. Datenmodell Kanon-Lexikon

### 1.1 Typen (Erweiterung der Skizze in ARCHITEKTUR.md A.7)

```swift
public struct CanonEntry: Sendable, Codable {
    public let id: String                    // stable, never reused
    public var canonical: String             // the one confirmed spelling, e.g. "TapIQ"
    public var kind: EntryKind               // .name, .acronym, .term
    public var family: String?               // family id, e.g. "iq"
    public var spokenForms: [SpokenForm]     // how it sounds, German and English reading
    public var hearingVariants: [HearingVariant]
    public var status: EntryStatus           // .proposed, .confirmed, .retired
    public var origin: EntryOrigin           // .seed, .userClick, .familyPattern, .recurringNonWord, .panottiImport
    public var compound: CompoundPolicy      // .hyphen (default), .none
    public var counters: Counters
    public var createdAt: Date
    public var confirmedAt: Date?
}

public struct SpokenForm: Sendable, Codable {
    public let language: SpokenLanguage      // .de, .en
    public let text: String                  // plain sound spelling, e.g. "tap i ku"
    public let origin: SpokenOrigin          // .derived (from spelling), .confirmed (typed by user)
}

public struct HearingVariant: Sendable, Codable {
    public let id: String
    public let heard: [String]               // normalized token sequence, e.g. ["tapeq"]
    public var context: [String]             // required neighbour tokens, empty = none
    public var status: VariantStatus         // .probation, .active, .suspended, .retired
    public let origin: VariantOrigin         // .corpus, .panottiRule, .userClick, .nearMiss
    public let replacesProtectedWord: Bool   // true = word-for-word, needs explicit click
    public var counters: Counters
}

public struct Counters: Sendable, Codable {
    public var benefit: Int                  // applied and not rejected
    public var harm: Int                     // rejected, or counted as damage in a corpus run
    public var lastAppliedAt: Date?
    public var lastCorpusRun: CorpusVerdict? // run id, hits, harm, date
}

public struct FamilyRule: Sendable, Codable {
    public let id: String                    // "iq"
    public let anchorWritten: String         // "IQ"
    public let anchorSpoken: [SpokenForm]    // "i ku", "ai kju"
    public let join: JoinStyle               // .concatenated ("TapIQ")
}
```

`LexiconSnapshot` (das, was die Textstufe sieht) enthält nur Einträge mit Status `confirmed` und nur Hörvarianten mit Status `active`. Alles andere lebt im `LexiconStore` und ist für `TextStage.process` unsichtbar.

### 1.2 Unverletzliche Regeln

| Nr | Regel | Grund |
|---|---|---|
| I1 | `canonical` entsteht und ändert sich nur durch einen Klick vom Besitzer | Die meistgenutzte Namensregel der Vorgänger-App zeigte zuletzt auf die falsche Schreibweise, weil das Ziel dreimal umgelernt wurde (01 Abschnitt 1b) [R] |
| I2 | Lernen fügt nur `HearingVariant` hinzu, nie Einträge, nie Schreibweisen | Plan 4.1 Punkt 1 |
| I3 | Ziel eines Eingriffs ist immer ein Eintrag mit Status `confirmed` | Plan 4, Grundsatz |
| I4 | ElevenLabs-Text erzeugt keinen Eintrag, ändert keine Schreibweise und liefert keinen Schreibvorschlag | ElevenLabs schreibt selbst 15-mal eine falsche IQ-Form (01 Abschnitt 0) [R] |
| I5 | Nichts wird gelöscht. Einträge und Varianten werden stillgelegt (`retired`), damit alte Spuren nachvollziehbar bleiben | Die Vorgänger-App: 328 Regeln nur durch Kuratierung von außen verschwunden [R] |
| I6 | Das Lexikon ist eine Datendatei außerhalb des Repos. Im Code steht kein Name | 05a G09: Namen und Kontakte als Seed im Code [R] |

### 1.3 Familienregel "Stamm plus IQ"

Eine Familie ist ein Anker (geschrieben "IQ", gesprochen "i ku" oder "ai kju") plus die Stämme ihrer bestätigten Mitglieder (Tap, Treib, Studio, Flow).

1. **Anker finden.** Der Anker steht als eigenes Token ("IQ", "iq"), als zwei Buchstaben-Tokens ("I Q") oder klebt am Wortende ("TabIQ", "TreibiQ").
2. **Stamm prüfen.** Das Token davor wird gefaltet (Abschnitt 1.5) und muss **gleich** der Faltung eines Mitgliedsstamms sein. "Tab" und "Tap" falten beide zu `tap`. Kein unscharfer Abstand an dieser Stelle.
3. **Ersetzen.** Bei Gleichheit wird die bestätigte Schreibweise gesetzt: "Tab IQ" wird "TapIQ", "Studio I Q" wird "StudioIQ".
4. **Unbekannter Stamm.** Passt kein Stamm, bleibt der Text unverändert, und die Stelle wird Kandidat (Abschnitt 4.1, K2). Ein neues Familienmitglied braucht nur einen Eintrag mit `family: "iq"`.

Die Regel darf geschützte Wörter berühren ("Tab", "Studio", "Flow" sind richtige Wörter), weil sie ausdrücklich ist: genauer Anker, genauer Stamm, bestätigtes Ziel. Das ist "Wort auf Wort nur ausdrücklich" aus Plan 4.2 Punkt 2.

Beleg [K]: Die Regel trifft im Korpus 14-mal (zwei Formen, beide "Tab" plus Anker), alle richtig. Unbekannte Stämme: 9 Treffer in 5 Diktaten, darunter "Talk IQ" (laut Register 08 R-001 ein Erkennungsfehler) und "TE IQ". Diese bleiben unberührt.

### 1.4 Erzeugte Formen und Zusammensetzungen

**Formvarianten (R1)** werden aus der Schreibweise erzeugt, nicht gespeichert. Der Schlüssel eines Eintrags ist seine Schreibweise klein, ohne Leerzeichen, Bindestrich, Punkt und Schrägstrich (`tapiq`). Jede Folge von 1 bis 4 Tokens mit demselben Schlüssel und anderer Schreibung wird auf den Kanon gesetzt: "Tap IQ", "Tap-IQ", "TapiQ", "tapiq" werden "TapIQ".

Das ersetzt die 306 Formregeln der Vorgänger-App (01 Abschnitt 1b) [R]. Beleg [K]: 74 Treffer, 31 verschiedene Paare, alle richtig. In 28 der 74 Treffer sind alle Quellteile für sich richtige Wörter ("Flow IQ", "Studio IQ"). Deshalb zwei Wächter:

| Wächter | Regel |
|---|---|
| Einzelwort | Ist die Quelle ein einzelnes geschütztes Wort und unterscheidet sie sich nur durch Groß und Klein, bleibt sie stehen, wenn sie klein geschrieben ist. Ein Eintrag "Marvento" macht aus dem Wort "marvento" nichts, falls das Systemwörterbuch es kennt |
| Mehrwort aus richtigen Wörtern | Eine erzeugte Formvariante, deren Teile alle geschützt sind, führt Buch wie eine Hörvariante (Zähler, Bewährung, Stilllegen nach Ablehnung, Abschnitt 4.3) |

**Zusammensetzungen** ("Name plus Nomen ergibt Name-Nomen") werden erzeugt, nicht gespeichert. Das ersetzt die 359 Vorgänger-Regeln, deren Ziel einen Bindestrich hat, den die Quelle nicht hat [Z] `panotti_regeln_tor.py`. Zwei Stufen:

| Stufe | Regel | Stand |
|---|---|---|
| Z1 | Der Erkenner hat schon gebunden ("Tab IQ-Design", "Tap-IQ-Design"): Namensteil wird Kanon, der Rest bleibt, Ergebnis "TapIQ-Design" | v1, an |
| Z2 | Der Erkenner schreibt getrennt ("TapIQ Design"): Bindestrich nur, wenn das Nomen in der Kopfliste steht (Nomen, die in der eigenen Historie mindestens zweimal gebunden hinter einem Eintrag standen) | v1, **aus**, bis der Korpus-Lauf Nutzen und null Schaden zeigt |

Grund für die Vorsicht bei Z2: "mit TapIQ Geld verdienen" darf nicht "TapIQ-Geld" werden. Die 114 rein formalen Eingriffe der Vorgänger-App waren weder Schaden noch Nutzen (01 Abschnitt 1c) [R], der Gewinn ist also klein.

Beugung: Ein Eintrag plus Genitiv-s ("TapIQs") gilt als geschützt und bleibt stehen.

### 1.5 Sprechform-Abgleich (R3)

**Idee:** Quelle und Eintrag werden beide so aufgeschrieben, wie sie klingen, und dann verglichen. Ziffern und Einzelbuchstaben werden dabei ausgesprochen, einmal deutsch und einmal englisch gelesen.

**Schritt 1, Lesarten der Quelle** (1 bis 3 Tokens):

| Tokenart | Lesart deutsch | Lesart englisch |
|---|---|---|
| Ziffern "3", Zahlwort "drei" | "drei" | "sri" |
| Einzelbuchstabe oder Großbuchstabenlauf bis 4 Zeichen ("BQ") | Buchstabennamen "be ku" | "bi kju" |
| Gemischt ("3BQ") | in Läufe zerlegt: "drei" + "be ku" | "sri" + "bi kju" |
| Wort ("Tribecue") | wie geschrieben | mit wenigen englischen Leseregeln ("cue" am Ende wird "kju", "ee" wird "i", stummes End-e) |

**Schritt 2, Faltung** (deutsche Lautklassen, eine feste Tabelle, keine Lernwerte): `sch`, `tsch` zu einem Zeichen, `ch`, `ck` zu `k`-Klassen, `ph` zu `f`, `v` und `w` zu `f`, `z` zu `ts`, `c` vor e und i zu `s`, sonst `k`, `q` zu `k`, `x` zu `ks`, `ei ai ey ay` zu einem Zeichen, `eu oi` zu einem Zeichen, `ie` zu `i`, Umlaute zum Grundvokal der Klasse, stimmhaft und stimmlos zusammen (`b` zu `p`, `d` zu `t`, `g` zu `k`), `h` fällt weg, Doppelte fallen zusammen.

**Schritt 3, Abstand:** gewichteter Editierabstand. Vokal tauschen, einfügen oder streichen kostet 0,5, Konsonant 1,0. Güte = 1 minus Abstand geteilt durch das größere Gewicht der beiden Faltungen.

**Schritt 4, Sprechformen des Eintrags:** aus der Schreibweise abgeleitet (gleiche Lesarten wie oben, an Großbuchstaben-Grenzen zerlegt) plus bestätigte Formen aus dem Eintrag. Für TreibIQ: deutsch "treib i ku", englisch "treib ai kju".

**Beispiele aus dem Korpus-Lauf** [K]:

| Quelle | Lesart | Bester Eintrag | Güte | Zweiter | Ergebnis bei 0,85 |
|---|---|---|---|---|---|
| "3BQ" | "drei be ku" | TreibIQ | 0,917 | TapIQ 0,667 | Eingriff |
| "drei BQ" | "drei be ku" | TreibIQ | 0,917 | TapIQ 0,667 | Eingriff |
| "3B Q" | "drei be ku" | TreibIQ | 1,0 | | Eingriff |
| "Treibig" | wie geschrieben | TreibIQ | 0,909 | | Eingriff |
| "Tribecue" | englisch gelesen | TreibIQ | 0,833 | TapIQ 0,667 | kein Eingriff (unter Schwelle) |
| "Tabacue" | englisch gelesen | TapIQ | 0,900 | TreibIQ 0,667 | Eingriff, **unklar**: ElevenLabs schreibt an der Stelle das andere Familienmitglied |
| "Tapeq", "Tabic" | wie geschrieben | TapIQ | 0,778 und 0,889 | | kein Eingriff (zu kurz) |
| "Teppic" (3-mal) | wie geschrieben | TapIQ | 0,778 | zweiter Eintrag 0,75 | kein Eingriff. Richtig so: ElevenLabs schreibt an den 3 Stellen drei verschiedene Formen, eine nahe TapIQ, eine nahe TreibIQ |
| "TAQ" | Buchstaben und Wort | TapIQ | 0,60 | | kein Eingriff, Erkennerfehler |

### 1.6 Schwellen (alle vorläufig, in `TextStageConfig`, mit Versionsnummer)

| Größe | Wert | Herleitung |
|---|---|---|
| `spokenMinScore` | 0,85 | Schwellenlauf unten [K] |
| `spokenMinWeight` | 5,0 (bei Güte 1,0 genügt 3,0) | Kürzere Quellen trafen falsch (zwei Fälle mit Gewicht 3,5 und 4,0 gesichtet) [K] |
| `spokenMinMargin` | 0,10 Abstand zum zweitbesten Eintrag | [A], im Lauf nie der einzige Grund für ein Nein |
| `siblingBlock` | zweitbester Eintrag aus derselben Familie mit Güte ab 0,70: kein Eingriff | Verwechslung zweier Familienmitglieder ist schlimmer als Stehenlassen ("Teppic" und "Tabacue" oben) [K]. Im Lauf griff der Wächter noch nie allein, Wert 0,70 ist [A] |
| `maxSpanTokens` | R1 bis 4, R3 bis 3 | [A] |
| Abkürzungsschutz | reine Großbuchstabenfolgen bis 5 Zeichen ohne Ziffer sind nie R3-Quelle | 14 Treffer ab 0,85 wären sonst Eingriffe geworden, darunter eine fremde Abkürzung, die zu einem Namen umgebogen worden wäre [K] |
| Abkürzungs-Einträge | Einträge der Art `.acronym` sind nur über Buchstabier-Lesart erreichbar, nie über die Wort-Lesart | ein falscher Treffer gesichtet [K] |
| `candidateMinDictations` | 3 Diktate an mindestens 2 Tagen | R-030 ("Vorschlag nach höchstens drei Vorkommen") [R] |
| Bewährung | Nutzen mindestens 2 Treffer in 2 Diktaten, Schaden 0 | Plan 4.2 Punkt 4, Zahl 2 ist [A] |
| Mengenbremse | mehr als 6 Eingriffe oder mehr als 15 % der Tokens in einem Diktat: alle R3-Eingriffe dieses Diktats entfallen | [A], Notbremse gegen einen entgleisten Lauf |

**Schwellenlauf R3** (Prototyp, 2.743 Diktate, 86 Einträge, R1 und R2 unverändert 74 und 14 Treffer) [K]:

| Schwelle | R3-Treffer | verschiedene Paare | davon falsch | davon unklar | Diktate mit Eingriff (alle Regeln) |
|---|---|---|---|---|---|
| 0,75 | 69 | 52 | 6 | 4 | 125 |
| 0,80 | 58 | 42 | 1 | 1 | 116 |
| **0,85** | **47** | **31** | **0** | **1** | **109** |
| 0,90 | 34 | 24 | 0 | 1 | 98 |
| 0,95 | 25 | 17 | 0 | 0 | 92 |

Zwischen 0,80 und 0,85 liegen 11 Treffer, davon 10 richtig. Trotzdem Start bei 0,85: lieber einen Namen stehen lassen als einen Satz verfälschen. Senken nur mit Vorher-Nachher-Lauf.

**Grenzen dieser Messung:** Python-Prototyp, kein Produktcode. Urteil "falsch, unklar, richtig" vom Agenten nach Sichtung von Roh-, End- und ElevenLabs-Text, nicht vom Besitzer. Schwellen und Urteil stammen aus denselben Diktaten. Der Rohtext ist Ausgabe von der ersten Textstufe der Vorgänger-App.

---

## 2. Schutzliste

Ein geschütztes Wort wird **nie unscharf ersetzt** (nie R3-Quelle). Es kann nur über eine ausdrückliche Regel berührt werden: R1 mit Wächtern, R2, oder eine vom Besitzer bestätigte Wort-auf-Wort-Hörvariante.

### 2.1 Drei Schichten

| Schicht | Inhalt | Wächst wie |
|---|---|---|
| P1 Systemwörterbuch | jede Wortform, die macOS für Deutsch oder Englisch kennt | von selbst: neue Wortformen werden beim ersten Auftreten nachgefragt und eingefroren |
| P2 Vertraute Wortformen | (a) Wortformen aus dem handbestätigten Goldsatz, (b) vom Besitzer als "richtiges Wort" angeklickte Kandidaten, (c) wiederkehrende unbekannte Formen, solange ihr Kandidat unentschieden ist (vorläufiger Schutz), (d) Einträge selbst samt Genitiv-s | (c) von selbst, (a) und (b) durch Bestätigung |
| P3 Regelhaft Gebildetes | Zusammensetzung aus zwei geschützten deutschen Teilen (je mindestens 4 Buchstaben, Fugen-s erlaubt). Eintrag plus Nomen. Englischer Stamm plus deutsche Endung (`-en -e -t -st -te -ten -et`, auch mit `ge-`), Stamm mindestens 4 Buchstaben | Regel, kein Speicher |

Im Zweifel geschützt: Kann eine Wortform nicht geprüft werden (Prüfer nicht erreichbar, Sprache unklar), gilt sie als geschützt.

### 2.2 Welche Schnittstelle (geprüft)

| Kandidat | Ergebnis | Beleg |
|---|---|---|
| `UITextChecker` | auf macOS nicht vorhanden (`canImport(UIKit)` ist falsch) | [T] `spell.swift` |
| `NSSpellChecker` | läuft in einem Kommandozeilenprogramm ohne `NSApplication` und ohne Ereignisschleife, auch auf einem Hintergrund-Thread. 8.922 Wortformen, deutsch und englisch: Ergebnis auf Haupt- und Hintergrund-Thread gleich. Kosten 0,10 bis 0,11 ms je Wort und Sprache, erster Aufruf 2,1 ms. Sprachkennungen "de" und "en" | [T] `spell.swift`, ein Lauf |
| `NLEmbedding` (NaturalLanguage, ohne AppKit) | zu dünn: kennt 3.318 der 8.922 Formen, das Systemwörterbuch 6.721 | [T] `spell.swift` |
| Dictionary Services (`DCSCopyTextDefinition`) | nicht geprüft | offen |

**Zwei Fallen** [T]:

1. `NSSpellChecker` hält **jede Großbuchstabenfolge** für richtig ("XQZT", "BQ", "TAQ", sogar "3BQ"). Abfrage deshalb nie in Großbuchstaben, sondern klein und mit großem Anfangsbuchstaben. Großbuchstabenfolgen regelt der Abkürzungsschutz (1.6).
2. Eingedeutschte Verben fehlen: "developen", "deployen", "connecten", "committen", "refunden", "designt" sind für beide Sprachen unbekannt. Ohne Schicht P3 wären genau die Wörter ungeschützt, die die Vorgänger-App zerschossen hat (01 Abschnitt 1c) [R].

### 2.3 Bau, passend zur Architektur

`FlowIQText` bleibt rein: Es bekommt ein `ProtectionSet` und fragt nur Mengen ab. `NSSpellChecker` kommt im Modul nicht vor.

- **Eingefrorene Menge:** `FrozenWordSet` je Sprache, gebaut von `flowiq-tool schutzliste` (wie in ARCHITEKTUR.md A.7).
- **Nötige Ergänzung zur Architektur:** Eine eingefrorene Menge kennt nur Wörter, die schon einmal vorkamen. Ein neues richtiges Wort wäre sonst ungeschützt. Zwei Wege, Entscheidung beim Architekten:
  - **Weg A (empfohlen):** Ein kleiner Adapter in der App (`SystemWordOracle`, eine Datei, nicht im Hauptthread) fragt vor `process` die noch nie gesehenen Wortformen nach und reicht die Antworten mit. Aufwand je Diktat: im Mittel 2,3 neue Formen, 95 % der Diktate höchstens 8 [Z] `schutz_messung.py`, also rund 0,5 ms, selten 2 ms. Die Antworten stehen in der Spur und wandern in die eingefrorene Menge, der Lauf bleibt wiederholbar. `check.sh` müsste `NSSpellChecker` in genau dieser Datei erlauben.
  - **Weg B (ohne Änderung an `check.sh`):** Unbekannte Formen gelten als geschützt, bis das Werkzeug sie im Leerlauf geprüft hat. R3 greift dann nur bei Formen, die als "geprüft unbekannt" vermerkt sind. Nachteil: Ein neuer Verhörer wird beim ersten Mal nie korrigiert.
- **Sprache:** Geschützt ist, was in **einer** der beiden Sprachen bekannt ist. Deutsch und Englisch werden nicht gegeneinander ausgespielt (die Vorgänger-App behandelte Englisch als "Standard" und verlor Begriffe, 04 E-15) [R].

Größenordnung [Z]: Von 8.922 Wortformen im Korpus kennt das Systemwörterbuch 6.721 deutsch und 2.634 englisch, 1.456 keines von beiden. Großbuchstabenfolgen zählt der Prüfer dabei als bekannt (Falle 1), die wahre Zahl der unbekannten Formen liegt also höher. Je Diktat sind im Mittel 0,83 Formen unbekannt, in 95 % höchstens 3.

---

## 3. Eingriffsregel

### 3.1 Ablauf in `TextStage.process`

1. **Normalisieren** (kein inhaltlicher Eingriff): Zögermarken und Steuerreste des Erkenners (`\letter`) entfernen. Nichts sonst.
2. **Schützen:** jedes Token gegen P1 bis P3 prüfen, Ergebnis je Token in die Spur.
3. **Abgleich**, von links nach rechts, längste Spanne zuerst (4, 3, 2, 1 Tokens), keine Überlappung:
   - bestätigte Hörvariante (genaue Tokenfolge, Kontext erfüllt),
   - R1 Formvariante,
   - R2 Familie,
   - R3 Sprechform.
4. **Zusammensetzung** Z1 (Z2 nur mit Schalter).
5. **Mengenbremse** prüfen, Spur schreiben, Text zurückgeben.

Eigenschaften, die Tests festhalten: leeres Lexikon ändert nichts. `process(process(x)) == process(x)`. Gleiche Eingabe, gleiches Lexikon, gleiche Schutzliste, gleiche Konfiguration ergeben denselben Text.

### 3.2 Die drei Bedingungen

Ein Eingriff braucht alle drei zugleich:

| Bedingung | R1 Formvariante | R2 Familie | R3 Sprechform | Hörvariante |
|---|---|---|---|---|
| **Quelle verdächtig** | Buchstabenfolge eines Eintrags in fremder Schreibung | genauer Anker plus Stamm | mindestens ein Token ungeschützt, jedes andere Token der Spanne ist Ziffer, Zahlwort oder Einzelbuchstabe | genau die gespeicherte Tokenfolge |
| **Ziel bestätigt** | Eintrag `confirmed` | Eintrag `confirmed` mit Familie | Eintrag `confirmed` | Eintrag `confirmed`, Variante `active` |
| **Übereinstimmung stark** | Schlüssel gleich | Faltung des Stamms gleich | Güte ab 0,85 mit allen Wächtern aus 1.6 | Tokenfolge gleich |

Was **nie** passiert: ein richtiges Wort wird durch ein ähnlich klingendes ersetzt. Grammatik, Wortform, Umgangssprache, Füllwörter, Wiederholungen und Satzzeichen bleiben, wie der Erkenner sie liefert.

### 3.3 Wort auf Wort

Manchmal schreibt der Erkenner statt eines Namens ein richtiges Wort (erfundenes Beispiel: das Werkzeug "Kalder" kommt als "Kalter" an). Das kann keine Regel sicher erkennen. Zugelassen ist nur:

- eine Hörvariante mit `replacesProtectedWord: true`, angelegt durch einen ausdrücklichen Klick mit Warnhinweis,
- bevorzugt mit Kontext (`context: ["Konsole"]`: nur wenn das Nachbarwort passt),
- nie aus einem automatischen Weg, nie aus der Bewährung allein.

Bedarf [Z]: 46 der 1.118 Vorgänger-Regeln haben ein Ziel aus der Startmenge und eine Quelle nur aus richtigen Wörtern. Das sind die Fälle, die der Besitzer einzeln entscheiden muss.

### 3.4 Rolle von Apples Sicherheit und Alternativen

| Frage | Antwort |
|---|---|
| Ist hohe Sicherheit ein Tor ("was Apple sicher erkannt hat, bleibt")? | **Nein.** Laut einem ungeprüften Befund vergibt der deutsche Erkenner bei Denglisch hohe Werte auf falsche Wörter (04 C-005, offen) [R]. Ein Tor darauf wäre ein Schutz auf unbelegter Annahme (Gegenlesung 5.2) |
| Ist niedrige Sicherheit ein Auslöser? | **Nein.** Niedrige Sicherheit allein löst nie einen Eingriff aus |
| Wofür dann? | Als **Zusatzsignal mit Gewicht 0 beim Start**: Sicherheit und bis zu 3 Alternativen je Wort werden immer in die Spur geschrieben. Vorgesehene spätere Nutzung, jeweils erst nach Korpus-Beleg: (1) Steht die bestätigte Schreibweise oder eine Formvariante unter den Alternativen, darf R3 schon ab 0,80 greifen. (2) Sehr hohe Sicherheit bei einer Quelle nahe der Schwelle kann einen R3-Eingriff verhindern |
| Warum Gewicht 0? | Im Bestand gibt es keine einzige gespeicherte Sicherheit oder Alternative (0 von 2.500, 01 Abschnitt 1a) [R]. Jede Gewichtung wäre heute geraten |

### 3.5 Vorbeugen an der Quelle

Nimmt der Erkenner Kontextbegriffe oder ein eigenes Sprachmodell an (Spike 1, Klärung K-01, läuft), bekommt er die bestätigten Schreibweisen. Die Textstufe bleibt dann als Netz darunter und ist für schon richtige Namen wirkungslos (Idempotenz). Stand: `setContext` nimmt die vier IQ-Namen ohne Fehler an [T, Spike 1, Probelauf ohne Audio]. Die Wirkung auf die Erkennung ist nicht gemessen.

---

## 4. Lernen mit Bremse

### 4.1 Kandidaten-Erkennung (`CandidateDetector`)

| Nr | Quelle | Regel | Größenordnung heute |
|---|---|---|---|
| K1 | wiederkehrendes Nichtwort | ungeschützte Form, kein Eintrag, keine Variante, in mindestens 3 Diktaten an mindestens 2 Tagen | 29 Formen in knapp vier Wochen, also etwa eine am Tag [Z] `schutz_messung.py` |
| K2 | Familienmuster | Anker mit unbekanntem Stamm ("Talk IQ") | 6 Formen, 9 Treffer [K] |
| K3 | Beinahe-Treffer | R3 mit Güte 0,70 bis 0,85 oder von einem Wächter gestoppt (zu kurz, Geschwister, Abkürzung), mindestens zweimal | bei 0,85: 18 Treffer von Wächtern gestoppt, dazu 11 zwischen 0,80 und 0,85 [K] |
| K4 | Vorgänger-Regeln, einmalig | nur Regeln, deren Ziel ein bestätigter Eintrag ist | 226 von 1.118 (Abschnitt 4.5) [Z] |
| K5 | Nachkorrektur und Doppeldiktat (R-032) | nur als Schnittstelle `SuggestionSource`. Nicht gebaut in v1: Es gibt keine Zahl, wie viele richtige Namen diese Signale bei der Vorgänger-App gebracht haben, und der Weg dorthin war Tastenprotokoll plus Lesen fremder Felder (05a B44) [R] | |

Ein Kandidat aus K1 ist **vorläufig geschützt**, solange er unentschieden ist.

### 4.2 Vorschlag an den Besitzer, ein Klick

Vorschläge stehen als Liste im Bereich "Wörter", nie als Dialog, nie während eines Diktats, höchstens ein Hinweis am Tag (R-030). Je Vorschlag: die gesehenen Formen mit Anzahl, ein Schreibvorschlag (häufigste Erkennerform, bei K2 "Stamm plus IQ"), ein Textfeld zum Ändern. Der Schreibvorschlag stammt nie aus ElevenLabs (I4).

| Klick | Wirkung |
|---|---|
| "Name, so schreiben" | `CanonEntry` wird `confirmed`. Sprechformen werden abgeleitet, Formvarianten gelten sofort |
| "Gehört zu <Eintrag>" | Hörvariante in `probation` |
| "Richtiges Wort" | Form wandert in Schicht P2 der Schutzliste |
| "Nicht mehr fragen" | Ignorierliste, Form bleibt vorläufig geschützt |

Prüfwert aus R-030: fünf nie gesehene Probenamen, Vorschlag nach höchstens drei Vorkommen, ein Klick, danach 10 von 10 richtig.

### 4.3 Bewährung über den Korpus

Eine Hörvariante (und jede Formvariante aus lauter richtigen Wörtern) wird erst `active`, wenn `flowiq-tool replay` über die ganze gespeicherte Historie Folgendes zeigt:

| Prüfung | Bedingung |
|---|---|
| Nutzen | mindestens 2 Treffer in 2 Diktaten |
| Schaden | 0 |
| Schutz | kein Treffer auf einer Quelle nur aus richtigen Wörtern, außer der Besitzer hat genau das angeklickt |
| Familie | kein Treffer, bei dem ein Geschwister-Eintrag mit Güte ab 0,70 konkurriert |

Als Schaden zählt ein Treffer, wenn (a) das Diktat im Goldsatz liegt und die Referenz dort den Eintrag nicht hat, (b) zu dem Diktat eine Ablehnung gespeichert ist, oder (c) eine zweite, unabhängige Fassung an der Stelle wörtlich die Quellform schreibt. Bei (c) werden beide Seiten vorher auf den Kanon gebracht, damit eine andere Schreibung desselben Namens nicht als Widerspruch zählt (Gegenlesung A-06). Das Urteil läuft nach der eingefrorenen Zählregel aus Phase 1.

Ehrliche Grenze: Für Hörvarianten gibt es außerhalb des Goldsatzes keine Wahrheit. Die Bewährung fängt Kollisionen mit normaler Sprache, nicht jede falsche Zuordnung. Deshalb bleibt die Bremse in 4.4 nötig.

### 4.4 Stilllegen

| Ereignis | Folge |
|---|---|
| Ablehnung, Diktat hatte genau einen Eingriff | Hörvariante: sofort `retired`. Formvariante aus richtigen Wörtern: für diesen Eintrag abgeschaltet. R3-Paar: Quelle wird als "nicht dieser Eintrag" vermerkt und nie wieder dorthin gezogen |
| Ablehnung, Diktat hatte mehrere Eingriffe | alle beteiligten Regeln `suspended`, wirken nicht mehr, erscheinen in der Liste mit der Frage "welcher war falsch", je ein Klick |
| Stillgelegtes | wird nie von selbst wieder aktiv, nur durch Klick |
| Eintrag selbst | bleibt bestätigt, der Schadenszähler steigt. Ab 2 Ablehnungen erscheint der Eintrag zur Durchsicht |

Gegenbild Vorgänger-App: 1.118 Regeln, 0 Ablehnungen, 0 deaktiviert, 1.053 genau einmal benutzt, 448 neue Regeln in 15 Tagen ohne Prüfung (01 Abschnitt 1b) [R].

### 4.5 Regeln der Vorgänger-App als Vorschläge

Das Wörterbuch wird nicht übernommen. Die Regeln laufen einmal durch ein mechanisches Tor [Z] `panotti_regeln_tor.py`:

| Schicksal | Regeln |
|---|---|
| Ziel ist kein Eintrag der Startmenge: entfällt (der Name kann später über K1 kommen) | 892 |
| Ziel ist Eintrag, Regel durch R1 schon abgedeckt | 22 |
| Ziel ist Eintrag, Quelle erreicht im Sprechform-Abgleich Güte ab 0,85 (ohne Wächter gerechnet) | 83 |
| Ziel ist Eintrag, Quelle klingt anders: Hörvariante in `probation` | 75 |
| Ziel ist Eintrag, Quelle nur aus richtigen Wörtern: nur mit Klick (3.3) | 46 |
| Summe | 1.118 |

In 47 der 226 Fälle schreibt die Vorgänger-App das Ziel anders als der Kanon. Das Ziel wird immer durch den Kanon ersetzt, nie umgekehrt.

---

## 5. Spur je Diktat

Gespeichert im Diktat-Journal, je Diktat ein Datensatz:

| Feld | Inhalt |
|---|---|
| `recognizerText` | Text des Erkenners, unverändert, **vor jeder Stufe** |
| `tokens[]` | je Wort: Text, Zeit von bis, Sicherheit, bis zu 3 Alternativen |
| `recognizerProfile`, `contextTermsVersion` | welcher Erkenner, welche Begriffe er vorab bekam |
| `lexiconVersion`, `protectionVersion`, `configVersion` | Stand der drei Eingaben der Textstufe |
| `oracleAnswers` | neu nachgefragte Wortformen mit Antwort (nur Weg A aus 2.3) |
| `stageTexts[]` | Text nach jeder Stufe, falls sich etwas geändert hat |
| `interventions[]` | je Eingriff: Regelart, Regel- und Eintragskennung, Tokenbereich, vorher, nachher, Güte, Abstand zum Zweitbesten, Schutzstatus der Quelltokens, kleinste Sicherheit, ob das Ziel unter den Alternativen stand, Grund in einem Wort |
| `nearMisses[]` | nicht ausgeführte Treffer ab Güte 0,70 mit dem Grund (Schwelle, kurz, Geschwister, Abkürzung, geschützt). Speist K3 und jeden Schwellenlauf |
| `finalText` | was eingefügt wurde |
| `feedback` | Ablehnung mit Zeit und Art (Rohfassung eingefügt, einzelner Eingriff abgelehnt) |
| `micros` | Laufzeit der Textstufe |

Warum "vor jeder Stufe": Die Vorgänger-App speichert als Rohtext die Ausgabe seiner ersten Textstufe und keine Eingriffsliste. Deshalb ist der Schaden der ersten Stufe heute unsichtbar und alle Schadenszahlen sind Untergrenzen (Gegenlesung T-01) [R].

**Kurzbefehl "Rohfassung einfügen"** (R-034, als Menüpunkt, Taste erst bei Bedarf): ersetzt die letzte Einfügung durch `recognizerText`. Zählt als Ablehnung **aller** Eingriffe dieses Diktats und löst 4.4 aus. Bedingungen fürs Ersetzen stehen in ARCHITEKTUR.md A.8.

---

## 6. Was ElevenLabs als Begriffe bekommt

| Regel | Wert |
|---|---|
| Inhalt | nur `canonical` von Einträgen mit Status `confirmed` |
| Nicht dabei | Hörvarianten, erzeugte Zusammensetzungen, Vorschläge, Vertraute Wortformen, Bildschirm-Vokabular |
| Menge | höchstens 100 (R-033). Reihenfolge: Familienmitglieder zuerst, dann nach Verwendung in den letzten 30 Tagen |
| Spur | die gesendete Liste steht mit Versionsnummer am Nachlauf-Auftrag |
| Rückweg | keiner. ElevenLabs-Text ändert nichts am Lexikon (I4). Er dient als zweite Fassung beim Messen, nach Kanon-Normalisierung beider Seiten |

Gegenbild: Die Vorgänger-App schickt bis zu 95 Begriffe aus dem ungeprüften Wörterbuch mit (04 C-030) [R], darunter die falsche Schreibweise von TreibIQ. ElevenLabs schreibt sie 15-mal. Dass das eine das andere bewirkt, ist plausibel, aber nicht geprüft.

---

## 7. Streichliste

### 7.1 Entfällt

| Nr | Vorgänger-Mechanismus | Beleg für das Streichen |
|---|---|---|
| S1 | **Erste Textstufe in der Engine** (`BilingualSpanFusionArbiter.fuse`: Ersetzungen, Vokabular-Schreibweisen, Alternativen-Regeln 1, 1A, 1B) | Läuft bei jedem deutschen Diktat mit leerer englischer Seite [C] `DictationEngine.swift:1196-1205, 384-630`. Macht den gespeicherten Rohtext unbrauchbar als Durchreich-Text (Gegenlesung T-01). Eigene Zählung: 4-mal "IQ IQ" in 2 Diktaten im Rohtext, der Name wurde eingesetzt und der Anker blieb stehen [Z] `iq_bilanz.py` |
| S2 | **Grammatik- und Umgangssprache-Glättung** | häufigste Schadensfälle: "meine" zu "mein" (14), "musst" zu "muss" (8), "möchte" zu "möcht" (7), "das" zu "dass" (5) (01 Abschnitt 1c) [R] |
| S3 | **Phonetik-Snap auf beliebiges Vokabular** (`PhoneticVocabMatcher`, `synthesizeAliases`) | "developen" zu "deployen", "designt" zu "Design-Idee", "Phonetik-Snap ist die Hauptquelle von Verschlimmbesserung" (04 C-032) [R]. Ersatz: R3 mit Schutzliste und nur auf bestätigte Einträge |
| S4 | **Harte Sonderregeln** im `QuasarArtifactCleaner` (feste Wortreparaturen) | zerlegen richtiges Deutsch, Beispiel "entrichten" [C] `TextInjector.swift:415-434`, 05a B38 [R]. Wer eine davon braucht, bekommt sie als bestätigte Hörvariante |
| S5 | **Stotter-Entfernung** (`stutterRx`) | Nutzen nicht belegt. 342 Wortdopplungen im Rohtext von 262 Diktaten, davon stehen 194 (57 %) auch im ElevenLabs-Text, wurden also so gesagt. 49 sind Betonung oder Ausruf ("nein nein" 25-mal). "die die" und "das das" sind im Deutschen richtige Satzanschlüsse. Die Vorgänger-App selbst lässt 197 Dopplungen stehen [Z] `stotter.py`. Eine Regel kann Stottern nicht von Absicht trennen, also Durchreichen. Neu bewerten, wenn der Goldsatz steht |
| S6 | **Binnenpunkt-Reparatur als Löschregel** (`midDotRx`, wirft den rechten Teil weg) | löscht Text (05a B38, G06) [R]. Die Wirkung war klein, aber vorhanden (04 C-021) [R]. Ob der Fehler ohne die Segmentverkettung der Vorgänger-App überhaupt noch entsteht, zeigt erst der Lauf über neu erkanntes Audio. Falls ja: nur ein Leerzeichen einfügen, nie löschen |
| S7 | **Pausenpunkt-Entfernung** | greift in jeden Satz (05a B39) [R] |
| S8 | **Lernen aus ElevenLabs** (Retro-Abgleich, `learnedPairs`) | 753 der 1.118 Regeln stammen daher. Nach 4 Tagen war das Wörterbuch vergiftet (04 C-023) [R] |
| S9 | **Lernen aus dem Textfeld** (`AutoDictionaryLearner`: Feldinhalt fremder Apps lesen, Tastenprotokoll, Fenstertitel) | Datenschutz und R-095 (05a B44) [R] |
| S10 | **Hygiene-Torwächter** (985 Zeilen Filterregeln gegen Fehllernen) | Folge des ungeprüften Lernens. Ohne ungeprüftes Lernen gegenstandslos (05a B43, Falle F-11) [R] |
| S11 | **Punktesystem** (`score`, `uses`, "Reinforcement Learning") | 0 Ablehnungen in 1.118 Regeln, Bestrafung nie ausgelöst (04 C-027) [R]. Ersatz: Zähler Nutzen und Schaden mit echter Ablehnung |
| S12 | **Seeds im Code** (48 Begriffe, 32 Regeln, 50 Sperrpaare) | private Namen im Code (05a G09) [R] |
| S13 | **Sperrpaare** (`neverSnapPairs`, 208) | Ersatz durch Schutzliste und stillgelegte Varianten. Die 208 Paare stammen nicht aus Ablehnungen (01 Abschnitt 1b) [R] |
| S14 | **Stimmprofil-Gate** (kein Teil der Textstufe, hier nur genannt) | in vier Wochen 153-mal "würde ablehnen", alles Kurztipper oder Fernfeld, keine Fremdstimme (04 C-040) [R] |
| S15 | **Sprachbefehle in der Textstufe** | nicht v1 (05a B41) [R] |
| S16 | **Zweisprachen-Logik** ("ist englisches Standardwort") als Entscheider | geschützt ist, was eine der Sprachen kennt (2.3) |

### 7.2 Bleibt

| Nr | Was | Beleg für den Nutzen |
|---|---|---|
| B1 | Steuerreste des Erkenners entfernen (`\letter`) | Rest steht 2-mal im Korpus-Rohtext [K] `prototyp-treffer.tsv`. Deterministisch, kein inhaltlicher Eingriff |
| B2 | Zögermarken des Erkenners entfernen | Port laut ARCHITEKTUR.md A.7. Vorkommen im neuen Erkennertext noch nicht gezählt [A] |
| B3 | Vorberechneter Index statt Regex je Diktat | Der Abschluss der Vorgänger-App sank nach dem Index-Umbau von rund 612 ms auf rund 180 ms (Gegenlesung Abschnitt 6, Ersatzmaß) [R] |
| B4 | Leerzeichenlogik zwischen zwei Diktaten | gehört zum Einfügen (`FlowIQInsert`), nicht zur Textstufe |
| B5 | Idee "Namen helfen" | 92 bis 120 hilfreiche Eingriffe bei der Vorgänger-App, fast alle Namen (01, 08 W-09) [R] |

Strukturbefehle ("neue Zeile") sind Sache des Architekten (A.7, Schalter). Aus Sicht dieses Konzepts gilt für sie dieselbe Buchführung: Regelart, Spur, Ablehnung.

---

## 8. Zeilenbudget und Leistung

### 8.1 Zeilen (Grenze 1.200, Plan 1.000 wie in ARCHITEKTUR.md)

| Datei | Inhalt | Zeilen |
|---|---|---|
| `Tokenizer.swift` | Tokens mit Bereich, Randzeichen, Bindestrich-Teile | 80 |
| `SpokenForm.swift` | Buchstabennamen und Zahlwörter deutsch und englisch, Lesarten, Faltung, gewichteter Abstand | 200 |
| `Lexicon.swift` | Typen aus 1.1, Schnappschuss, Index (Schlüssel, Faltungen, Familien) | 170 |
| `Protection.swift` | `FrozenWordSet`, Schicht P3, Abkürzungsschutz | 130 |
| `Matcher.swift` | Hörvariante, R1, R2, R3 mit Wächtern | 210 |
| `Compound.swift` | Z1, Z2 | 50 |
| `TextStage.swift` | Ablauf, Mengenbremse, Spur | 110 |
| `Candidates.swift` | K1 bis K3 | 50 |
| Summe | | **1.000** |

Zum Vergleich: Die Textstufe der Vorgänger-App hat 3.469 Zeilen, dazu rund 520 für die erste Stufe in der Engine (05a) [R]. Der Python-Prototyp mit R1 bis R3 und allen Wächtern hat rund 200 Zeilen.

Reihenfolge beim Bau (Register 08 U-01: nur bauen, was messbar Namen rettet): erst R1, R2, Hörvarianten und Schutz. R3 nur, wenn der Drei-Wege-Lauf auf neu erkanntem Audio den Mehrwert zeigt. Im Prototyp bringt R3 47 der 135 Eingriffe und 6 der 35 zusätzlichen IQ-Treffer.

### 8.2 Leistung (Ziel p95 unter 15 ms, Wunsch unter 5 ms)

| Maßnahme | Begründung |
|---|---|
| Index einmal je Lexikon-Version bauen, nie je Diktat | B3 |
| Schutzabfrage ist eine Mengenabfrage im Speicher | der Systemprüfer kostet 0,10 ms je Wort und Sprache [T], ein 30-Wörter-Diktat läge ungecacht bei rund 6 ms |
| R1 und Hörvarianten über Hash-Tabellen: 4 Abfragen je Tokenposition | |
| R3 nur für Spannen mit ungeschütztem Token: im Mittel 0,83 je Diktat, 95 % höchstens 3 [Z] | Einträge vorab nach Anfangsklasse und Gewicht eingeteilt, Abstand nur gegen passende Fächer |
| keine `NSRegularExpression`, keine Ein-Ausgabe, kein Hauptthread | |

Erwartung [A]: deutlich unter 1 ms je Diktat. **Nicht gemessen.** Gemessen wird in `flowiq-tool replay` (p50 und p95 über den ganzen Korpus, dazu ein 300-Wörter-Diktat).

---

## 9. Offene Punkte und Risiken

| Nr | Punkt | Wer klärt |
|---|---|---|
| O1 | Schwellen gelten nur vorläufig (Abschnitt 0, Punkt 6). Nötig: neuer Erkennerlauf über die 2.371 nutzbaren Audios, Hälfte zurückhalten | Phase-2-Lauf |
| O2 | 95 % Namenstreffer hängen an K-01 (Kontextbegriffe oder Sprachmodell). Die Textstufe allein kam im Prototyp auf 78 % der IQ-Stellen. Mit Hörvarianten für die 8 Stellen, die keine richtigen Wörter sind, wären es rechnerisch 57 von 63 (90 %), aber diese Varianten wären an denselben Diktaten gelernt | Spike 1, danach Goldsatz |
| O3 | Weg A oder B für neue Wortformen (2.3) | Architekt |
| O4 | Handurteil des Agenten durch Goldsatz des Besitzers ersetzen. Der unklare Fall (ein Verhörer zwischen zwei Familienmitgliedern) zeigt: auch ElevenLabs ist bei Namen kein Richter | Goldsatz |
| O5 | Z2 (Bindestrich bei getrennt Geschriebenem) bleibt aus, bis gemessen | Phase-2-Lauf |
| O6 | Sicherheit und Alternativen: Gewicht 0, bis Daten da sind (3.4) | nach den ersten Wochen mit Spur |
| O7 | Mehrzahl und Beugung: "die alten <Name>s" wird heute auf die Grundform gesetzt. Im Korpus 4 Treffer dieser Art [K]. Vorschlag: End-s der Quelle übernehmen, wenn die Quelle auf s endet und der Eintrag nicht | Phase-2-Lauf |
| O8 | Schreibweisen, die klein beginnen: am Satzanfang nicht umschreiben | Test |

---

## 10. Skripte und Wiederholung

Alle unter `local/phase2/lexikon-skripte/` (privat, lesen nur die Datenkopie). Aufruf jeweils `python3 -I <skript>`.

| Skript | Liefert |
|---|---|
| `tokens.py`, `spell.swift` | Wortformen des Korpus, Systemwörterbuch-Test (Threads, Zeiten, `spell.tsv`) |
| `spell-grossbuchstaben.swift` | Großbuchstaben-Falle |
| `lexikon_def.py`, `start_tsv.py` | Startmenge und `lexikon-start.tsv` |
| `prototyp.py` | R1 bis R3 über den Rohtext, schreibt `prototyp-treffer.tsv` |
| `auswertung.py` | Schwellenlauf mit Handurteil |
| `iq_bilanz.py` | IQ-Familie: Rohtext, Vorgänger-App, Prototyp |
| `schutz_messung.py` | neue und unbekannte Wortformen je Diktat, wiederkehrende Nichtwörter |
| `stotter.py` | Wortdopplungen in Roh, End, ElevenLabs |
| `panotti_regeln_tor.py` | Vorgänger-Regeln am mechanischen Tor |
| `kontext.py` | Umfeld einer Quellform zum Sichten (gibt Diktattext aus, nur lokal) |

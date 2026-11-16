# Prüfliste und Entscheidungen (Wörter mit Claude prüfen)

Im Hauptfenster, Bereich Wörter, Block "Mit Claude prüfen". FlowIQ schickt dabei nichts selbst ins Netz: der Besitzer gibt
die Datei weiter und legt die Antwort wieder hin.

## pruefliste.json (FlowIQ schreibt)

Liegt im Datenordner der App (`~/Library/Application Support/FlowIQ/` bzw. `FlowIQ-Dev/`), daneben `pruefliste.md`
zum Lesen. Eine Liste von Einträgen:

| Feld | Bedeutung |
|---|---|
| `id` | Kennung für die Antwort: Eintrags-Kennung eines Namensvorschlags oder `pruefen-<n>` für die Liste "Zum Prüfen" |
| `art` | `name` (offener Namensvorschlag) oder `pruefen` |
| `gehoert` | wie der Erkenner es gehört hat |
| `vorschlag` | die vorgeschlagene Schreibweise |
| `beispiele` | bis zu drei kurze Stellen (rund 80 Zeichen) aus dem Diktat-Journal |

## entscheidungen.json (Antwort, FlowIQ liest)

Eine Liste `[{"id": "...", "aktion": "...", "schreibweise": "..."}]`.

| aktion | Wirkung |
|---|---|
| `bestaetigen` | Name mit `schreibweise` bestätigen; bei `pruefen-<n>` wieder aktiv |
| `ablehnen` | Vorschlag stilllegen; bei `pruefen-<n>` endgültig aus |
| `richtiges-wort` | `schreibweise` ist ein normales Wort und wird nie ersetzt |
| `stilllegen` | wie `ablehnen` |

FlowIQ zeigt vor dem Übernehmen eine Zusammenfassung (Trockenlauf); erst der Klick "Übernehmen" ändert das Lexikon.
Unbekannte Aktionen werden übersprungen.

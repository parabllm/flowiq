# AGENTS.md (FlowIQ)

Regeln für alle, die mit einem KI-Assistenten (Claude Code, Codex, Cursor und ähnliche) an diesem Repo arbeiten.
Liegt `local/AGENTS-privat.md` vor, gilt sie zusätzlich und hat Vorrang.

1. **Erst lesen, dann ändern.** `README.md` für den Überblick, `docs/ARCHITEKTUR.md` für den Aufbau. Der Ordner
   `local/` ist privat, per `.gitignore` ausgeschlossen und fehlt in einem frischen Klon; Verweise darauf in den
   Dokumenten lassen sich dann nicht nachschlagen.
2. **`scripts/check.sh` grün vor jedem Commit.** Es prüft Datenschutz, Zeilenbudget, Ausnahmen, verbotene Muster,
   baut mit Warnungen als Fehler und lässt alle Tests laufen. `scripts/check.sh --static` ist die schnelle Fassung
   ohne Bau. Einmalig nach dem Klonen: `git config core.hooksPath .githooks`.
3. **Zeilenbudget halten.** `budget.tsv` begrenzt die Zeilen je Modul und insgesamt. Reicht der Platz nicht, wird
   Code gekürzt oder Umfang gestrichen. Die Grenze wird nur in einem eigenen Commit mit Begründung geändert.
4. **Keine Warnungen, keine Abkürzungen.** Swift 6, Warnungen sind Fehler. `try?`, `@unchecked Sendable`,
   `nonisolated(unsafe)` und `@preconcurrency` brauchen eine Begründung in derselben Zeile und zählen gegen
   `pruefgrenzen.tsv`. Netz nur in `FlowIQCloud`, Schreibzugriffe nur über `SafeFS`, keine Fremdbibliotheken.
5. **Tests nicht aufweichen.** Erwartungswerte, Schwellen und die Mindestzahl der Tests werden nie gesenkt, damit
   etwas grün wird. Die Tests unter `abnahme-tests/` sind vor dem Code geschrieben; dort ändert sich höchstens eine
   mit `ASSUMPTION` oder `COMPILE-FIX` markierte Zeile. Eine Abweichung wird gemeldet, nicht versteckt.
6. **Aussehen nicht ungefragt ändern.** Pille, Menü, Fenster, Farben, Schrift und Abstände bleiben, wie sie sind,
   solange kein ausdrücklicher Auftrag vorliegt. Farb-, Größen- und Zeitwerte stehen nur unter
   `Sources/FlowIQ/Theme/`.
7. **Nichts Privates committen.** Keine Diktattexte, keine Namen von Personen oder Kunden, kein Audio, keine
   Schlüssel, keine Pfade mit Benutzernamen. Tests nutzen künstliche Beispiele. Eigene Namen und Begriffe, die nie
   ins Repo dürfen, gehören zeilenweise in `local/datenschutz-muster.txt`; `scripts/datenschutz-check.sh` und die
   Git-Haken prüfen dagegen.
8. **Die App nicht ungefragt starten, beenden oder installieren.** `scripts/bundle.sh` baut nur,
   `scripts/install.sh` kopiert nur. Keine Aufrufe an bezahlte Cloud-Dienste ohne Auftrag.
9. **Keine Zahl ohne Messung.** Jede Aussage nennt ihren Beleg: in der laufenden App gemessen, Test, oder nur im
   Code gelesen.
10. **Sprache:** Code, Bezeichner und Kommentare englisch. Doku und Oberfläche deutsch mit echten Umlauten, keine
    Gedankenstriche.

#!/usr/bin/env python3
"""FlowIQ-Bericht aus dem Ereignisprotokoll (16.11.: Performance-Reviews, Funktionen prüfen).

Liest ereignisse.ndjson (und gedrehte Teile) eines Profils, fasst einen Zeitraum als kurze Tabellen zusammen:
Fn-Zeiten (Median, p90, p99), Anfangsverlust (Taste bis erster Puffer), RAM und CPU im Leerlauf und bei Aufnahme,
Fehler nach Art, Sitzungen, Diktate, Nachlauf. Das Protokoll ist textfrei; der Bericht gibt nur Zahlen aus.
Aufruf: scripts/bericht.py [--protokoll <ordner>] [--von 2026-11-16] [--bis 2026-11-17]
Ohne --protokoll: ~/Library/Application Support/FlowIQ-Dev/protokoll.
"""
import argparse, collections, glob, json, os, statistics


def quantile(values, q):
    if not values:
        return None
    s = sorted(values)
    return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]


def row(name, values, unit="ms"):
    if not values:
        return "| %s | 0 | - | - | - |" % name
    return "| %s | %d | %.1f %s | %.1f %s | %.1f %s |" % (name, len(values), statistics.median(values), unit,
                                                     quantile(values, 0.9), unit, quantile(values, 0.99), unit)


def events(folder, start, end):
    files = sorted(glob.glob(os.path.join(folder, "ereignisse*.ndjson")), reverse=True)
    for path in files:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue  # a torn line costs only itself
                ts = event.get("ts", "")
                if (not start or ts >= start) and (not end or ts < end):
                    yield event


def main():
    parser = argparse.ArgumentParser(description="FlowIQ-Bericht aus dem Ereignisprotokoll")
    parser.add_argument("--protokoll", default=os.path.expanduser("~/Library/Application Support/FlowIQ-Dev/protokoll"))
    parser.add_argument("--von", default="")
    parser.add_argument("--bis", default="")
    args = parser.parse_args()
    fn = collections.defaultdict(list)
    res = {False: [], True: []}
    cpu = {False: [], True: []}
    errors, kinds = collections.Counter(), collections.Counter()
    sessions, words, interventions, inserts, post = [], [], [], collections.Counter(), []
    for e in events(args.protokoll, args.von, args.bis):
        kind = e.get("kind", "")
        kinds[kind] += 1
        if e.get("level") == "error":
            errors["%s %s" % (kind, e.get("error_domain", ""))] += 1
        if kind == "fn.timeline":
            for label, a, b in [("Taste bis Pille (t0-t2)", "t0_ms", "t2_ms"),
                                ("Anfangsverlust: Taste bis erster Puffer (t0-t4)", "t0_ms", "t4_ms"),
                                ("Loslassen bis eingefügt (t7-t12)", "t7_ms", "t12_ms"),
                                ("Loslassen bis abgeholt (t7-t13)", "t7_ms", "t13_ms")]:
                if a in e and b in e:
                    fn[label].append(e[b] - e[a])
        elif kind == "resources":
            busy = bool(e.get("recording"))
            res[busy].append(e.get("footprint_mb", 0))
            if "cpu_pct" in e:
                cpu[busy].append(e["cpu_pct"])
        elif kind == "live_session_ended":
            sessions.append(e)
        elif kind == "dictation_counts":
            words.append(e.get("words", 0))
            interventions.append(e.get("interventions", 0))
        elif kind == "insert_result":
            inserts[e.get("result", "")] += 1
        elif kind == "nachlauf_done":
            post.append(e)
    print("## Zeitraum %s bis %s, %d Ereignisse\n" % (args.von or "Anfang", args.bis or "jetzt", sum(kinds.values())))
    print("| Fn-Zeit | n | Median | p90 | p99 |\n|---|---|---|---|---|")
    for label in sorted(fn):
        print(row(label, fn[label]))
    print("\n| Ressourcen | n | Median | p90 | p99 |\n|---|---|---|---|---|")
    print(row("RAM Leerlauf", res[False], "MB"))
    print(row("RAM Aufnahme", res[True], "MB"))
    print(row("CPU Leerlauf", cpu[False], "%"))
    print(row("CPU Aufnahme", cpu[True], "%"))
    print("\n| Diktate | Wert |\n|---|---|")
    print("| Diktate mit Zählung | %d |" % len(words))
    print("| Wörter Median | %s |" % (statistics.median(words) if words else "-"))
    print("| Eingriffe gesamt | %d |" % sum(interventions))
    for result, n in sorted(inserts.items()):
        print("| Einfügen %s | %d |" % (result, n))
    print("\n| Sitzungen | Anzahl | Minuten | archiviert | Nachlauf an |\n|---|---|---|---|---|")
    by_kind = collections.defaultdict(list)
    for s in sessions:
        by_kind[s.get("mode", "?")].append(s)
    for kind, items in sorted(by_kind.items()):
        print("| %s | %d | %.1f | %d | %d |" % (kind, len(items), sum(i.get("seconds", 0) for i in items) / 60,
                                              sum(1 for i in items if i.get("archived")),
                                              sum(1 for i in items if i.get("nachlauf") == "an")))
    print("\n| Nachlauf | Läufe | Audio-Minuten | Rechenzeit Median |\n|---|---|---|---|")
    services = collections.defaultdict(list)
    for p in post:
        services[p.get("service", "?")].append(p)
    for service, items in sorted(services.items()):
        print("| %s | %d | %.1f | %.0f ms |" % (service, len(items), sum(i.get("seconds", 0) for i in items) / 60,
                                              statistics.median([i.get("ms", 0) for i in items])))
    print("\n| Fehler (Art, Domain) | Anzahl |\n|---|---|")
    for name, n in errors.most_common():
        print("| %s | %d |" % (name.strip(), n))


if __name__ == "__main__":
    main()

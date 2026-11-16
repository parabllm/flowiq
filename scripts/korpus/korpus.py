#!/usr/bin/env python3
"""Corpus runs of FlowIQ that need no Apple API (ARCHITEKTUR E.5, budget version 4): they count against no module and
the app never needs them at run time. The text stage and the system dictionary are never rebuilt here; every stage
result comes from `flowiq-tool replay` (with its own oracle). Everything with dictation text stays below local/.

  startlexikon   --liste lexikon-start.tsv --aus local/.../lexikon.json
                 The private seed list as a lexicon file of the store (LexiconStore format, nothing learned).
  zahlen         --spur local/.../spur.jsonl
                 Numbers of a replay run: dictations, interventions per rule and way, braked dictations, near
                 misses by reason, stage time p50, p95, max with R3 (R-035, R-036). Console: numbers only.
  erstbefuellung --history H --erkannt E --regeln vocabulary.json --liste lexikon-start.tsv --aufteilung A
                 --aus local/... [--ids lern-ids.txt] [--tool .build/debug/flowiq-tool]
                 The seeding run (LEXIKON-KONZEPT 12): hearing variants for lexicon entries from the corpus without
                 the gold set, written as `lexikon.json` and `kontobuch.json` for the app's first import
                 ("Panotti-Daten übernehmen"). Targets only from the lexicon, never a spelling from ElevenLabs or
                 Panotti (I4). Sources A (after-run text), B (Panotti's end text), C (Panotti rules), D (near misses
                 of the sound match from 0.70). Every candidate is proven over the corpus: benefit (the after-run has
                 the entry there), counter evidence (the after-run writes the heard form), harm (frozen counting rule
                 zaehlregel-v1, checksum verified). A candidate with counter evidence that never stands next to the
                 word of its benefit becomes context-bound ("nur neben"). Automatic rows become active variants, the
                 click list and disputed targets proposals, single sightings wait.
"""
import collections, datetime, difflib, hashlib, json, os, subprocess, sys, unicodedata

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GOLD = os.path.join(REPO, 'local', 'korpus', 'goldsatz')
EPOCH_2001 = 978307200.0  # Swift's JSONEncoder writes dates as seconds since 2001-01-01
NEAR_MISS_FLOOR = 0.70


def stop(message):
    print('korpus: ' + message)
    sys.exit(2)


def args(argv):
    out, flags, i = {}, set(), 0
    while i < len(argv):
        key = argv[i].lstrip('-')
        if i + 1 < len(argv) and not argv[i + 1].startswith('--'):
            out[key], i = argv[i + 1], i + 2
        else:
            flags.add(key)
            i += 1
    return out, flags


def private(path):
    real = os.path.realpath(path)
    if not real.startswith(os.path.join(REPO, 'local') + os.sep):
        stop('Ausgabe muss unter local/ liegen: ' + path)
    return real


def pieces(text):
    """Runs of letters and digits like FlowIQText `Pieces.split`: (text, joinable to the previous piece)."""
    text, out, i, gap = unicodedata.normalize('NFC', text or ''), [], 0, 0
    while i < len(text):
        if not text[i].isalnum():
            i += 1
            continue
        j = i
        while j < len(text) and text[j].isalnum():
            j += 1
        between = text[gap:i]
        out.append((text[i:j], bool(out) and (between == '-' or (between != '' and set(between) == {' '}))))
        gap = i = j
    return out


def lower(text):
    return [p[0].lower() for p in pieces(text)]


def key(text):
    return ''.join(c for c in (text or '').lower() if c not in ' -./')


def swift_date(seconds):
    return seconds - EPOCH_2001


# MARK: seed list and lexicon file

def seed_entries(tsv):
    rows = [r.split('\t') for r in open(tsv, encoding='utf-8').read().split('\n')[1:]]
    rows = [r for r in rows if len(r) >= 5 and r[0]]
    entries = []
    for n, r in enumerate(rows):
        spoken = []
        if r[2] != 'auto':
            for part in r[2].split('|'):
                bits = [b.strip() for b in part.split(':', 1)]
                if len(bits) == 2 and bits[0] in ('de', 'en'):
                    spoken.append({'language': bits[0], 'text': bits[1], 'origin': 'confirmed'})
        acronym = not any(c.islower() for c in r[0]) and len(r[0]) <= 6
        entries.append({'id': f'seed-{n + 1}', 'canonical': r[0], 'kind': 'acronym' if acronym else 'name',
                        'family': r[1] or None, 'spokenForms': spoken, 'hearingVariants': [],
                        'status': 'confirmed' if r[4] == 'sicher' else 'proposed', 'origin': 'seed',
                        'compound': 'hyphen', 'counters': {'benefit': 0, 'harm': 0},
                        'createdAt': swift_date(0), 'confirmedAt': None})
    families = []
    for fid in sorted({e['family'] for e in entries if e['family']}):
        endings = {e['canonical'][-len(fid):] for e in entries if e['family'] == fid}
        if len(endings) == 1 and next(iter(endings)).lower() == fid:
            families.append({'id': fid, 'anchorWritten': next(iter(endings)), 'anchorSpoken': [],
                             'join': 'concatenated'})
    return entries, families


def lexicon_file(entries, families):
    return {'version': 1, 'entries': entries, 'families': families, 'familiar': [], 'changes': [], 'review': [],
            'cases': [], 'reports': []}


def write_json(path, value):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(value, f, ensure_ascii=False, sort_keys=True)


# MARK: the stage, only through flowiq-tool replay

def replay(tool, texts, entries, families, root):
    """Runs the stage (R3 off and on) over {id: text}; returns {id: (pieces, exact result, R3 result)}."""
    work = os.path.join(root, 'stufe')
    os.makedirs(work, exist_ok=True)
    every = [dict(e, status='confirmed') for e in entries]  # proposed targets resolve too (disputed rows)
    write_json(os.path.join(work, 'lexikon-alle.json'), lexicon_file(every, families))
    write_json(os.path.join(work, 'texte.json'), [{'id': k, 'rawText': v} for k, v in texts.items() if v])
    run = subprocess.run([tool, 'replay', '--history', os.path.join(work, 'texte.json'), '--lexikon',
                          os.path.join(work, 'lexikon-alle.json'), '--wurzel', work], capture_output=True, text=True)
    if run.returncode != 0:
        stop('replay gescheitert: ' + run.stderr.strip())
    out = {}
    for line in open(os.path.join(work, 'FlowIQ-Dev', 'replay', 'spur.jsonl'), encoding='utf-8'):
        t = json.loads(line)
        out[t['id']] = (texts[t['id']], t['flowiq'], t['flowiqR3'])
    return out


def spans(text, result, first):
    """Piece index -> entry id: interventions of the stage plus spellings the stage consumed unchanged.
    `first` maps the first lower-case piece of every canonical spelling to (pieces, entry id)."""
    ps, found = pieces(text), {}
    for i in result['interventions']:
        for k in range(i['pieces'][0], i['pieces'][1]):
            found[k] = i['entryID']
    for k, p in enumerate(ps):
        for c, e in first.get(p[0].lower(), []):
            n = len(c)
            if [x[0] for x in ps[k:k + n]] == c and all(ps[m][1] for m in range(k + 1, k + n)):
                for m in range(k, k + n):
                    found.setdefault(m, e)
    return found


def first_pieces(entries):
    out = collections.defaultdict(list)
    for e in entries:
        c = [p[0] for p in pieces(e['canonical'])]
        if c:
            out[c[0].lower()].append((c, e['id']))
    return out


def contains(words, heard):
    n = len(heard)
    return n > 0 and any(words[k:k + n] == heard for k in range(len(words) - n + 1))


def neighbours(words, heard):
    n, out = len(heard), set()
    for k in range(len(words) - n + 1):
        if words[k:k + n] == heard:
            out.update(w for w in (words[k - 1] if k > 0 else '', words[k + n] if k + n < len(words) else '') if w)
    return out


# MARK: the seeding run

def candidates(trace, raw_id, other_id, first):
    """Source A or B: replacements of up to 3 heard pieces by up to 4 pieces whose other side is one entry."""
    a_text, exact, _ = trace[raw_id]
    b_text, _, b_r3 = trace[other_id]
    a, b = lower(a_text), lower(b_text)
    b_entry = spans(b_text, b_r3, first)
    raw_exact = {(i['pieces'][0], i['pieces'][1]): i['entryID'] for i in exact['interventions']}
    out = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(a=a, b=b, autojunk=False).get_opcodes():
        if tag != 'replace' or i2 - i1 > 3 or j2 - j1 > 4:
            continue
        runs = []
        for j in range(j1, j2):
            e = b_entry.get(j)
            if e and runs and runs[-1][0] == e and runs[-1][2] == j:
                runs[-1][2] = j + 1
            elif e:
                runs.append([e, j, j + 1])
        whole = [r for r in runs if b_entry.get(r[1] - 1) != r[0] and b_entry.get(r[2]) != r[0]]
        if not whole:
            continue
        e, s, t = max(whole, key=lambda r: (r[2] - r[1], -r[1]))
        heard, rest = a[i1:i2], b[j1:s] + b[t:j2]
        lo = 0
        while heard and rest and heard[0] == rest[0]:
            heard, rest, lo = heard[1:], rest[1:], lo + 1
        while heard and rest and heard[-1] == rest[-1]:
            heard, rest = heard[:-1], rest[:-1]
        if heard and not rest and raw_exact.get((i1 + lo, i1 + lo + len(heard))) != e:
            out.append((tuple(heard), e))
    return out


def seeding(a, flags):
    tool = a.get('tool', os.path.join(REPO, '.build', 'debug', 'flowiq-tool'))
    root = private(a['aus'])
    os.makedirs(root, exist_ok=True)
    if subprocess.run(['shasum', '-a', '256', '-c', 'zaehlregel-v1.sha256'], cwd=GOLD,
                      capture_output=True).returncode != 0:
        stop('Prüfsumme der Zählregel weicht ab')
    entries, families = seed_entries(a['liste'])
    by_id = {e['id']: e for e in entries}
    by_name = {e['canonical']: e['id'] for e in entries}
    gold = {l.split('\t')[0] for l in open(a['aufteilung'], encoding='utf-8').read().split('\n')[1:] if l.strip()}
    keep = set(open(a['ids'], encoding='utf-8').read().split()) if 'ids' in a else None
    recognized = {}
    for line in open(a['erkannt'], 'rb').read().split(b'\n'):
        if line.strip():
            d = json.loads(line)
            if d.get('result') and d['result'].get('text') is not None:
                recognized[d['id']] = d['result']['text']
    rows = [r for r in json.load(open(a['history'], encoding='utf-8')) if r.get('id') in recognized
            and r['id'] not in gold and r.get('elevenLabsText') and (keep is None or r['id'] in keep)]
    rows.sort(key=lambda r: (r.get('startedAt') or 0, r['id']))
    rules = json.load(open(a['regeln'], encoding='utf-8')).get('replacements', [])
    texts = {}
    for r in rows:
        texts[r['id'] + '#roh'] = recognized[r['id']]
        texts[r['id'] + '#ref'] = r['elevenLabsText']
        texts[r['id'] + '#pan'] = r.get('processedText') or ''
    for n, rule in enumerate(rules):
        texts[f'regel-{n}#von'], texts[f'regel-{n}#nach'] = rule.get('from') or '', rule.get('to') or ''
    trace = replay(tool, texts, entries, families, root)
    first = first_pieces(entries)
    found = collections.defaultdict(set)
    for r in rows:
        rid = r['id']
        if rid + '#roh' not in trace:
            continue
        for c in candidates(trace, rid + '#roh', rid + '#ref', first) if rid + '#ref' in trace else []:
            found[c].add('A')
        for c in candidates(trace, rid + '#roh', rid + '#pan', first) if rid + '#pan' in trace else []:
            found[c].add('B')
        for m in trace[rid + '#roh'][2]['nearMisses']:
            if m['rule'] == 'R3' and m['score'] >= NEAR_MISS_FLOOR and m['target'] in by_name:
                found[(tuple(lower(m['before'])), by_name[m['target']])].add('D')
    for n, rule in enumerate(rules):
        von, nach = trace.get(f'regel-{n}#von'), trace.get(f'regel-{n}#nach')
        if not von or not nach or not 1 <= len(pieces(von[0])) <= 4:
            continue
        to = spans(nach[0], nach[1], first)
        targets = set(to.values())
        if len(targets) != 1 or len(to) != len(pieces(nach[0])):
            continue
        e = targets.pop()
        own = spans(von[0], von[1], first)
        if key(texts[f'regel-{n}#von']) != key(by_id[e]['canonical']) and set(own.values()) != {e}:
            found[(tuple(lower(texts[f'regel-{n}#von'])), e)].add('C')
    # Tally over every dictation (12.1 "Bewährung"), with the neighbour words for a context-bound form
    heard_words = {r['id']: lower(recognized[r['id']]) for r in rows}
    ref_words = {r['id']: lower(r['elevenLabsText']) for r in rows}
    ref_entries = {r['id']: set(spans(r['elevenLabsText'], trace[r['id'] + '#ref'][2], first).values())
                   if r['id'] + '#ref' in trace else set() for r in rows}
    protected = set()
    for r in rows:
        if r['id'] + '#roh' in trace:
            protected.update(trace[r['id'] + '#roh'][1].get('protectedForms', []))
    table = []
    for (heard, e), sources in sorted(found.items(), key=lambda x: (by_id[x[0][1]]['canonical'], x[0][0])):
        h = list(heard)
        row = {'heard': h, 'entry': e, 'canonical': by_id[e]['canonical'], 'sources': sorted(sources),
               'realWord': any(p in protected for p in h), 'context': []}
        tally(row, rows, heard_words, ref_words, ref_entries)
        if row['counter'] > 0 and row['benefit'] >= 2:  # "nur neben": the word of the benefit, never at a counter
            near = collections.Counter()
            bad = set()
            for rid, kind in row['kinds'].items():
                for w in neighbours(heard_words[rid], h):
                    (near.update([w]) if kind == 'benefit' else bad.add(w))
            fits = sorted((w for w, c in near.items() if c >= 2 and w not in bad), key=lambda w: (-near[w], w))
            if fits:
                row['context'] = [fits[0]]
                tally(row, rows, heard_words, ref_words, ref_entries)
        table.append(row)
    probes, reference = [], {r['id']: r['elevenLabsText'] for r in rows}
    for n, row in enumerate(table):
        if row['counter'] == 0 and row['benefit'] > 0:
            for rid in row['ids']:
                text = recognized[rid]
                end = replacing(text, row['heard'], row['canonical'], row['context'])
                if end != text:
                    probes.append({'id': f'{n}#{rid}', 'roh': text, 'ende': end, 'referenz': reference[rid]})
    write_json(os.path.join(root, 'proben.json'), probes)
    chunks = os.path.join(root, 'schaden.jsonl')
    subprocess.run([sys.executable, '-I', os.path.join(GOLD, 'zaehlregel-v1.py'), '--history',
                    os.path.join(root, 'proben.json'), '--raw-key', 'roh', '--end-key', 'ende', '--ref-key',
                    'referenz', '--out', chunks], check=True, capture_output=True)
    harm = collections.Counter(int(json.loads(l)['id'].split('#')[0]) for l in open(chunks, encoding='utf-8')
                               if json.loads(l)['verdict'].endswith('harmful'))
    judge(table, harm, {e['id'] for e in entries if e['status'] == 'confirmed'})
    install(root, table, entries, families, rows)
    print('erstbefuellung: diktate=%d kandidaten=%d proben=%d ' % (len(rows), len(table), len(probes))
          + ' '.join(f'{k}={v}' for k, v in sorted(collections.Counter(r['verdict'] for r in table).items())))
    print('kontext: %d Zeilen "nur neben"' % sum(1 for r in table if r['context'] and r['verdict'] != 'verworfen'))


def tally(row, rows, heard_words, ref_words, ref_entries):
    """Benefit, counter evidence and unclear hits; with a context only the hits next to the context word."""
    row.update(hits=0, benefit=0, counter=0, unclear=0, ids=[], kinds={}, last=0)
    for r in rows:
        words = heard_words[r['id']]
        if not contains(words, row['heard']) or (row['context'] and not set(row['context'])
                                                 & neighbours(words, row['heard'])):
            continue
        kind = 'benefit' if row['entry'] in ref_entries[r['id']] else 'counter' \
            if contains(ref_words[r['id']], row['heard']) else 'unclear'
        row['hits'] += 1
        row[kind] += 1
        row['ids'].append(r['id'])
        row['kinds'][r['id']] = kind
        if kind == 'benefit':
            row['last'] = max(row['last'], r.get('startedAt') or 0)


def replacing(text, heard, canonical, context):
    """`text` with every occurrence of the heard pieces (next to the context word, if any) set to `canonical`."""
    text = unicodedata.normalize('NFC', text)
    spots, i, ps = [], 0, []
    while i < len(text):
        if text[i].isalnum():
            j = i
            while j < len(text) and text[j].isalnum():
                j += 1
            ps.append((i, j, text[i:j].lower()))
            i = j
        else:
            i += 1
    words, n, out, cursor = [p[2] for p in ps], len(heard), '', 0
    k = 0
    while n and k + n <= len(ps):
        around = {words[k - 1] if k else '', words[k + n] if k + n < len(words) else ''}
        if words[k:k + n] == heard and (not context or set(context) & around):
            out += text[cursor:ps[k][0]] + canonical
            cursor, k = ps[k + n - 1][1], k + n
        else:
            k += 1
    return out + text[cursor:]


def judge(table, harm, confirmed):
    targets = collections.defaultdict(set)
    for r in table:
        if r['benefit'] > 0:
            targets[tuple(r['heard'])].add(r['entry'])
    for n, r in enumerate(table):
        r['harm'] = harm.get(n, 0)
        reasons = [x for x, on in (('wort', r['realWord']), ('einmal', r['benefit'] < 2),
                                   ('ziel-strittig', r['entry'] not in confirmed),
                                   ('mehrdeutig', len(targets[tuple(r['heard'])]) > 1),
                                   ('meist-unbestaetigt', r['benefit'] * 2 < r['hits']),
                                   ('zu-kurz', len(''.join(r['heard'])) < 3), ('kontext', bool(r['context']))) if on]
        r['verdict'], r['reason'] = (
            ('verworfen', 'gegenbeleg') if r['counter'] > 0 else ('verworfen', 'schaden') if r['harm'] > 0
            else ('verworfen', 'kommt-nicht-vor' if r['hits'] == 0 else 'kein-nutzen') if r['benefit'] == 0
            else ('automatisch', '') if not reasons
            else ('strittig', ','.join(reasons)) if 'ziel-strittig' in reasons
            else ('wartet', ','.join(reasons)) if 'einmal' in reasons
            else ('klick', ','.join(reasons)))


def install(root, table, entries, families, rows):
    """Start lexicon (automatic rows as active corpus variants) and ledger (click list and disputed targets
    proposed, single sightings waiting), both with their corpus evidence."""
    by_id = {e['id']: e for e in entries}
    for n, r in enumerate(table):
        if r['verdict'] == 'automatisch':
            by_id[r['entry']]['hearingVariants'].append({
                'id': f'k-{n}', 'heard': r['heard'], 'context': r['context'], 'status': 'active', 'origin': 'corpus',
                'replacesProtectedWord': False,
                'counters': {'benefit': r['benefit'], 'harm': 0, 'lastAppliedAt': r['last']}})  # startedAt: 2001
    pairs = []
    for n, r in enumerate(table):
        if r['verdict'] in ('klick', 'strittig', 'wartet'):
            note = f"Nutzen in {r['benefit']} Diktaten" + (f", nur neben {r['context'][0]}" if r['context'] else '')
            pairs.append({'id': 'p-' + hashlib.sha256(f"{r['entry']}|{' '.join(r['heard'])}".encode()).hexdigest()[:8],
                          'heard': r['heard'], 'entryID': r['entry'], 'sightings': [], 'counterEvidence': r['counter'],
                          'state': 'collecting' if r['verdict'] == 'wartet' else 'proposed', 'realWord': r['realWord'],
                          'note': note, 'benefit': r['benefit'], 'harm': r['harm'], 'context': r['context']})
    write_json(os.path.join(root, 'lexikon.json'), lexicon_file(entries, families))
    write_json(os.path.join(root, 'kontobuch.json'), {'pairs': pairs, 'confusions': 0})
    write_json(os.path.join(root, 'urteile.json'), [{k: v for k, v in r.items() if k not in ('kinds',)}
                                                    for r in table])


def numbers(a):
    rules, micros, near, n = {'flowiq': collections.Counter(), 'flowiqR3': collections.Counter()}, [], \
        collections.Counter(), 0
    for line in open(a['spur'], encoding='utf-8'):
        t, n = json.loads(line), n + 1
        for way in rules:
            r = t[way]
            rules[way].update(i['tRule'] for i in r['interventions'])
            rules[way]['diktate'] += 1 if r['interventions'] else 0
            rules[way]['gebremst'] += 1 if r['droppedByBrake'] else 0
        micros.append(t['flowiqR3']['micros'])
        near.update(m['rule'] + '-' + m['reason'] for m in t['flowiqR3']['nearMisses'])
    micros.sort()
    at = lambda p: micros[min(len(micros) - 1, max(0, -(-len(micros) * p // 1) - 1))] if micros else 0
    print(f'diktate: n={n}')
    for way, c in rules.items():
        print(f'eingriffe {way}: ' + ' '.join(f'{k}={v}' for k, v in sorted(c.items())))
    print('beinahe: ' + ' '.join(f'{k}={v}' for k, v in sorted(near.items())))
    print(f'mikrosekunden: p50={int(at(0.5))} p95={int(at(0.95))} max={micros[-1] if micros else 0}')


def main():
    if len(sys.argv) < 2:
        stop('Befehle: startlexikon, zahlen, erstbefuellung (Kopf der Datei)')
    a, flags = args(sys.argv[2:])
    if sys.argv[1] == 'startlexikon':
        entries, families = seed_entries(a['liste'])
        write_json(private(a['aus']), lexicon_file(entries, families))
        return print(f'startlexikon: eintraege={len(entries)} familien={len(families)}')
    if sys.argv[1] == 'erstbefuellung':
        return seeding(a, flags)
    if sys.argv[1] == 'zahlen':
        return numbers(a)
    stop('unbekannter Befehl ' + sys.argv[1])


if __name__ == '__main__':
    main()

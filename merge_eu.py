#!/usr/bin/env python3
"""
merge_eu.py — single source of truth for combining EU race producer outputs.

Architecture: each producer writes to its OWN exclusive path; this script is
the ONLY writer of the consumed paths. Eliminates the WebFetch-overwrite trap
where a later producer would silently wipe an earlier producer's output.

Producer files (any may exist or not):
  upcoming:
    /tmp/eu_upcoming_bash.json     — bash eu_prefetch.sh (Step 0 bootstrap)
    /tmp/eu_upcoming_webfetch.json — Step 7.0.5 WebFetch
    /tmp/eu_upcoming_cache.json    — Step 7.0.6 Gmail cache load
  recap:
    /tmp/eu_recap_bash.json     — bash eu_prefetch.sh (Step 0 bootstrap)
    /tmp/eu_recap_webfetch.json — Step 5-RP WebFetch

Consumed paths (this script is the ONLY writer):
  /tmp/eu_upcoming_json.json — read by Step 7.5 generator + verifiers
  /tmp/eu_recap_json.json    — read by Step 7.5 generator + verifiers + Step 4c-R-EU

Usage:
  python3 /tmp/merge_eu.py upcoming   # rebuild /tmp/eu_upcoming_json.json
  python3 /tmp/merge_eu.py recap      # rebuild /tmp/eu_recap_json.json
  python3 /tmp/merge_eu.py all        # rebuild both
"""
import sys, os, json

GO = {'G1':0,'G2':1,'G3':2,'LR':3}

def normname(n):
    s = (n or '').lower().strip()
    for suf in [' stakes',' s.',' h.',' handicap']:
        if s.endswith(suf): s = s[:-len(suf)]
    # Strip common sponsor prefixes
    for pfx in ['paddy power ','jenningsbet ','al basti equiworld dubai ','jebel ali racecourse and stables ','goffs ','fasig-tipton ','dubai duty free ','coral-']:
        if s.startswith(pfx): s = s[len(pfx):]
    return s.strip()

def _load(path):
    if not os.path.exists(path): return None
    try:
        with open(path) as f: return json.load(f)
    except Exception as e:
        print('MERGE_WARN: could not parse ' + path + ' — ' + str(e), file=sys.stderr)
        return None

def merge_upcoming():
    bash = _load('/tmp/eu_upcoming_bash.json') or []
    webfetch = _load('/tmp/eu_upcoming_webfetch.json') or []
    cache = _load('/tmp/eu_upcoming_cache.json') or []

    # Each input is a list of {day_label, races[]}. Union by (grade, normname) per prefix.
    # Use bash structure as the skeleton (it always runs and has correct day_label format).
    by_prefix = {'YESTERDAY':[], 'TODAY':[], 'TOMORROW':[]}
    day_label = {'YESTERDAY':'', 'TODAY':'', 'TOMORROW':''}
    seen = {'YESTERDAY':set(), 'TODAY':set(), 'TOMORROW':set()}

    def absorb(source, source_name):
        added = 0
        for day in source:
            pfx = (day.get('day_label','').split() or [''])[0]
            if pfx not in by_prefix: continue
            if not day_label[pfx]:
                day_label[pfx] = day.get('day_label','')
            for race in day.get('races', []):
                key = (race.get('grade',''), normname(race.get('race_name','')))
                if not key[1]: continue  # skip empty names
                if key in seen[pfx]: continue
                seen[pfx].add(key)
                by_prefix[pfx].append(race)
                added += 1
        if added > 0:
            print('  MERGE_UPCOMING: ' + source_name + ' added ' + str(added) + ' races')

    # Order matters for day_label fallback: bash first (canonical), then webfetch, then cache.
    absorb(bash, 'bash')
    absorb(webfetch, 'webfetch')
    absorb(cache, 'cache')

    # Sort: TOMORROW by date_short then grade; others by grade.
    for pfx in by_prefix:
        if pfx == 'TOMORROW':
            by_prefix[pfx].sort(key=lambda r: (r.get('date_short',''), GO.get(r.get('grade','LR'),9), r.get('track','')))
        else:
            by_prefix[pfx].sort(key=lambda r: (GO.get(r.get('grade','LR'),9), r.get('track','')))

    result = []
    for pfx in ('YESTERDAY','TODAY','TOMORROW'):
        # Default label if nothing produced
        lbl = day_label[pfx] or (pfx + ' — ?')
        result.append({'day_label': lbl, 'races': by_prefix[pfx]})

    with open('/tmp/eu_upcoming_json.json','w') as f: json.dump(result, f, indent=2)
    total = sum(len(d['races']) for d in result)
    print('MERGE_UPCOMING_DONE: ' + str(total) + ' total races written to /tmp/eu_upcoming_json.json')
    for d in result:
        print('  ' + d['day_label'] + ' (' + str(len(d['races'])) + ')')
    return total

def merge_recap():
    bash = _load('/tmp/eu_recap_bash.json') or []
    webfetch = _load('/tmp/eu_recap_webfetch.json') or []

    # Each input is a flat list of {grade, race_name, course, country, dist, surface, winner, jockey}
    result = []
    seen = set()
    def absorb(source, source_name):
        added = 0
        for race in source:
            key = (race.get('grade',''), normname(race.get('race_name','')))
            if not key[1]: continue
            if key in seen: continue
            seen.add(key)
            result.append(race)
            added += 1
        if added > 0:
            print('  MERGE_RECAP: ' + source_name + ' added ' + str(added) + ' races')

    absorb(bash, 'bash')
    absorb(webfetch, 'webfetch')

    result.sort(key=lambda r: (GO.get(r.get('grade','LR'),9), r.get('course','')))

    with open('/tmp/eu_recap_json.json','w') as f: json.dump(result, f, indent=2)
    print('MERGE_RECAP_DONE: ' + str(len(result)) + ' EU Group/Listed races written to /tmp/eu_recap_json.json')
    return len(result)

if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'all'
    if mode in ('upcoming','all'): merge_upcoming()
    if mode in ('recap','all'): merge_recap()

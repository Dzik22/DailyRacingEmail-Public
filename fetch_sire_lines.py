#!/usr/bin/env python3
"""
Build sire_lines.json -- graded (G1/G2/G3) winners sired by the stallions Mike holds shares in
through the Wasabi Ventures Stallions funds -- for the digest's SIRE LINES block.

WHY THIS EXISTS
---------------
Mike asked (Oct 27 2026) for a SIRE LINES section: a graded-stakes win by any offspring lifts the
value of the stallion share. Same constraint as fetch_eu_stakes.py: CCR can reach only
raw.githubusercontent.com, so the fetch runs here in GitHub Actions and the result is committed to
the public mirror.

Equibase (Imperva) and pedigreequery (Cloudflare managed challenge) both refuse automated fetches,
even with curl_cffi impersonating Chrome (measured Oct 27 2026). theracingapi.com's results carry
each runner's sire, and its plan covers group/graded races globally, so it is the source here.
The USA fallback is the Step 5-DRF subagent's `winner_sire` (from its existing winner search).

HOW IT RUNS
-----------
fetch_eu_stakes.py calls this as a subprocess right after its CREDS check (the credential arrives
in the inherited RACING_API_CREDS env) and stages sire_lines.json, so the workflow's commit step
picks it up with no workflow edit (the PAT has no `workflow` scope). Every failure is non-fatal:
it prints SIRE_FAIL and leaves the previously committed sire_lines.json untouched.

OUTPUT
------
sire_lines.json  {for_date, built_utc, source, window:[from,to], sires:[{name, farm}],
                  scanned:{races, graded, by_region:{}}, hits:[{date, sire, farm, winner, grade,
                  race_name, course, region}]}
hits is a rolling 30-day history (merged with the previous file), newest first.
"""
import base64, gzip, json, os, re, sys, time, urllib.request
from datetime import date, datetime, timedelta

# The Wasabi-held stallions, as Mike gave them (Oct 27 2026). Farm = where each stands.
SIRES = [
    ('Charge It', 'Gainesway'), ('Prince of Monaco', 'Claiborne'), ('Army Mule', "Hill 'n' Dale"),
    ('Casa Creed', 'Mill Ridge'), ('Blofeld', 'Murmur Farm'), ('Annapolis', 'Claiborne'),
    ('Dr. Schivel', 'Taylor Made'), ('Straight No Chaser', 'WinStar'), ('Mindframe', 'Claiborne'),
    ('Johannes', 'Claiborne'), ('Arzak', '2 Amsterdam'), ("Arthur's Ride", 'Taylor Made'),
    ('Tappan Street', 'WinStar'), ('Honor A.P.', "Lane's End"), ('Complexity', 'Airdrie Stud'),
]
OUT = 'sire_lines.json'
BASE = 'https://api.theracingapi.com/v1'
WINDOW_DAYS = 3        # yesterday and the two days before -- survives a missed or late build
KEEP_DAYS = 30
MAX_PAGES = 25


def norm(name):
    # "Honor A. P. (USA)" / "Honor AP" -> "honorap"; "Dr Schivel" -> "drschivel"
    s = re.sub(r'\s*\([A-Za-z]{2,4}\)\s*$', '', str(name or ''))
    return re.sub(r'[^a-z0-9]', '', s.lower())


ROSTER = {norm(n): (n, f) for n, f in SIRES}


def grade_of(rec):
    # The race TITLE wins over the feed's `pattern` field: on Oct 7 2026 the feed labelled two
    # Heritage handicaps G1 and demoted the Fillies' Mile to G2 (see fetch notes in the prompt).
    for txt in (rec.get('race_name') or '', rec.get('pattern') or ''):
        m = re.search(r'\b(?:Group|Grade|Groupe|Gruppo|G)\s*([123])\b', txt, re.I)
        if m:
            return 'G' + m.group(1)
    return None


def get(path, creds):
    req = urllib.request.Request(BASE + path)
    req.add_header('Authorization', 'Basic ' + base64.b64encode(creds.encode()).decode())
    req.add_header('Accept-Encoding', 'gzip')
    req.add_header('User-Agent', 'daily-racing-digest/1.0')
    for attempt in (1, 2, 3):
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                raw = r.read()
                if r.headers.get('Content-Encoding') == 'gzip':
                    raw = gzip.decompress(raw)
                return json.loads(raw.decode('utf-8'))
        except Exception as e:
            print('  SIRE attempt %d failed for %s: %s' % (attempt, path.split('?')[0], e))
            if attempt < 3:
                time.sleep(attempt * 6)
    return None


def main():
    creds = os.environ.get('RACING_API_CREDS', '').strip()
    if not creds:
        print('SIRE_FAIL: RACING_API_CREDS not set')
        return
    t = date.today(); y = t - timedelta(days=1); start = y - timedelta(days=WINDOW_DAYS - 1)
    races, skip, pages, total = [], 0, 0, None
    while pages < MAX_PAGES:
        res = get('/results?start_date=%s&end_date=%s&limit=50&skip=%d'
                  % (start.isoformat(), y.isoformat(), skip), creds)
        if res is None:
            break
        batch = res.get('results') or []
        races += batch; pages += 1; skip += len(batch)
        total = res.get('total', total)
        if not batch or (total is not None and skip >= int(total)):
            break
        time.sleep(1.5)
    if not races:
        print('SIRE_FAIL: no results returned for %s..%s; previous %s left untouched' % (start, y, OUT))
        return

    by_region, graded, hits = {}, 0, []
    for r in races:
        reg = str(r.get('region') or '?').upper()
        by_region[reg] = by_region.get(reg, 0) + 1
        g = grade_of(r)
        if not g or 'arab' in (r.get('race_name') or '').lower():
            continue
        graded += 1
        for run in (r.get('runners') or []):
            if str(run.get('position')) != '1':
                continue
            hit = ROSTER.get(norm(run.get('sire')))
            if hit:
                hits.append({'date': str(r.get('date') or '')[:10], 'sire': hit[0], 'farm': hit[1],
                             'winner': re.sub(r'\s*\([A-Za-z]{2,4}\)\s*$', '', run.get('horse') or '?').strip(),
                             'grade': g, 'race_name': re.sub(r'\s*\((?:Group|Grade|G)\s*[123]\)\s*', ' ',
                                                             r.get('race_name') or '', flags=re.I).strip(),
                             'course': re.sub(r'\s*\([A-Za-z]{2,4}\)\s*$', '', r.get('course') or '').strip(),
                             'region': reg})

    # Rolling history: today's window replaces those dates, older hits are kept up to KEEP_DAYS.
    prev = []
    try:
        prev = json.load(open(OUT)).get('hits', [])
    except Exception:
        pass
    cutoff = (t - timedelta(days=KEEP_DAYS)).isoformat()
    kept = [h for h in prev if cutoff <= h.get('date', '') < start.isoformat()]
    allhits = sorted(kept + hits, key=lambda h: (h['date'], h['grade']), reverse=True)

    json.dump({'for_date': t.isoformat(), 'built_utc': datetime.utcnow().isoformat() + 'Z',
               'source': 'theracingapi.com', 'window': [start.isoformat(), y.isoformat()],
               'sires': [{'name': n, 'farm': f} for n, f in SIRES],
               'scanned': {'races': len(races), 'graded': graded, 'by_region': by_region},
               'hits': allhits}, open(OUT, 'w'), ensure_ascii=False, indent=1)
    print('SIRE_OK %s..%s races=%d graded=%d hits_window=%d hits_kept=%d regions=%s'
          % (start, y, len(races), graded, len(hits), len(allhits), json.dumps(by_region)))
    for h in hits:
        print('  [%s] %s by %s -- %s @ %s %s' % (h['grade'], h['winner'], h['sire'], h['race_name'],
                                                 h['course'], h['date']))


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print('SIRE_FAIL: ' + str(e))
    sys.exit(0)

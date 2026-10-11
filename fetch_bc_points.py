#!/usr/bin/env python3
"""
Build bc_points.json -- the Breeders' Cup divisional points leaderboard -- for the digest's
BREEDERS' CUP WATCH block.

WHY THIS EXISTS
---------------
Same reason as fetch_eu_stakes.py: CCR can reach only raw.githubusercontent.com, so the
leaderboard has to be fetched here in GitHub Actions and committed to the public mirror.

members.breederscup.com sits behind Cloudflare, which 403s plain curl/urllib on the TLS
fingerprint ("Attention Required!"). curl_cffi impersonating Chrome gets a 200 (measured
Oct 11 2026). The page is server-rendered: all 14 divisions and their top 16 horses, with
every points-earning race, are in the one HTML response -- the +/- accordions are CSS only.

HOW IT RUNS
-----------
fetch_eu_stakes.py calls this as a subprocess BEFORE its own work and stages bc_points.json,
so the existing workflow's commit step picks it up without editing the workflow file (the
PAT has no `workflow` scope). Every failure here is non-fatal: it prints BC_FAIL and leaves
the previously committed bc_points.json untouched, so a Cloudflare bad day never costs the
EU build or publishes an empty leaderboard.

STANDINGS RULES (verified against the live page Oct 11 2026)
------------------------------------------------------------
- A division's points are the horse's SURFACE total -- Total Dirt Points for a dirt race,
  Total Turf Points for a turf race. (Simply Joking: 14 dirt pts in the Filly & Mare Sprint,
  only 2 of them from F&M Sprint-division races.)
- Page order = 'Win and You're In' Challenge winners first, then points descending.
- "(OUT)" suffixed to a name means the connections have ruled the horse out.
- The red cell holds nomination problems, e.g. "R1 - Not Nominated".

OUTPUT
------
bc_points.json  {for_date, built_utc, source, event{...}, divisions:[{name, surface,
                 horses:[{name, country, out, challenge_winner, points, board_pos,
                 points_rank, points_tied, nomination, owner, trainer, races:[...]}]}],
                 prev_date, prev{"<division>|<horse>": {points, points_rank, board_pos}}}
"""
import json, os, re, subprocess, sys
from datetime import date, datetime

URL = 'https://members.breederscup.com/Points/PointsLeaderboard'
OUT = 'bc_points.json'
EVENT = {'name': "Breeders' Cup World Championships", 'venue': 'Keeneland',
         'dates': 'Fri Oct 30 – Sat Oct 31, 2026', 'first_day': '2026-10-30',
         'last_day': '2026-10-31', 'pre_entry_deadline': '2026-10-19'}


def surface_of(name, horses):
    """The surface whose totals the page is sorted by (Challenge winners excluded). Keyword
    fallback only if the order fits both or neither -- 'Mile' alone can't decide it, because
    the FanDuel Mile is turf and the Dirt Mile is not."""
    fits = []
    for surf in ('dirt', 'turf'):
        seq = [x['tot'].get(surf, 0) for x in horses if not x['challenge_winner']]
        if seq and all(a >= b for a, b in zip(seq, seq[1:])) and any(seq):
            fits.append(surf)
    if len(fits) == 1:
        return fits[0]
    return 'dirt' if 'Dirt' in name else ('turf' if 'Turf' in name or name.endswith('Mile') else 'dirt')


def fail(msg):
    print('BC_FAIL: ' + msg + ' -- leaving existing ' + OUT + ' untouched')
    sys.exit(0)


def fetch():
    try:
        from curl_cffi import requests
    except ImportError:
        subprocess.run([sys.executable, '-m', 'pip', 'install', '-q', 'curl_cffi', 'beautifulsoup4'],
                       timeout=180, check=False)
        from curl_cffi import requests
    last = ''
    for imp in ('chrome', 'chrome124', 'safari'):
        try:
            r = requests.get(URL, impersonate=imp, timeout=45)
        except Exception as e:
            last = imp + ': ' + str(e)
            continue
        if r.status_code == 200 and 'accordianDivision' in r.text:
            return r.text
        last = '%s: HTTP %s, %d bytes' % (imp, r.status_code, len(r.text))
    fail('fetch blocked (' + last + ')')


def txt(el):
    return re.sub(r'\s+', ' ', el.get_text(' ', strip=True)).strip() if el else ''


def parse(html):
    from bs4 import BeautifulSoup
    s = BeautifulSoup(html, 'html.parser')
    out = []
    for d in s.find_all('div', attrs={'data-parent': '#accordianDivision'}):
        name = txt(s.find(id=d.get('aria-labelledby')).find('button'))
        name = re.sub(r'\s*[+−]\s*', ' ', name).strip()
        name = re.sub(r'\s+', ' ', name)
        horses = []
        for h in d.find_all('div', attrs={'data-parent': lambda p: p and p.endswith('Horse')}):
            btn = s.find(id=h.get('aria-labelledby')).find('button')
            raw = (btn.find(string=True, recursive=False) or '').strip()
            # Trailing tags seen live: country "(IRE)", "(OUT)", "(layoff)", and "(R1)"/"(R2)"
            # which pair with the red nomination note. Peel them all off the end.
            tags = []
            while True:
                m = re.match(r'^(.*?)\s*\(([^()]{1,12})\)$', raw)
                if not m: break
                raw, tags = m.group(1).strip(), [m.group(2).strip()] + tags
            hname = raw
            out_flag = 'OUT' in tags
            country = next((t for t in tags if re.fullmatch(r'[A-Z]{2,3}', t) and t != 'OUT'), '')
            notes = [t for t in tags if t != 'OUT' and t != country]
            tot = {}
            for div in h.select('div.row.small div'):
                mm = re.match(r'Total (Turf|Dirt) Points:\s*(\d+)', txt(div))
                if mm: tot[mm.group(1).lower()] = int(mm.group(2))
            conn = next((txt(p) for p in h.find_all('p') if 'Owner:' in p.get_text()), '')
            owner = re.search(r'Owner:\s*(.*?)(?:\s*Trainer:|$)', conn)
            trainer = re.search(r'Trainer:\s*(.*)$', conn)
            races = []
            for tr in h.select('table.small tr'):
                tds = [txt(td) for td in tr.find_all('td')]
                if len(tds) != 8: continue
                races.append({'bcc': tds[0] == '*', 'date': tds[1], 'track': tds[2], 'race': tds[3],
                              'grade': tds[4], 'division': tds[5], 'pos': tds[6],
                              'points': int(tds[7]) if tds[7].isdigit() else 0})
            horses.append({'name': hname, 'country': country, 'out': out_flag, 'notes': notes,
                           'challenge_winner': 'Challenge Winner' in txt(btn),
                           'tot': tot,
                           'nomination': txt(h.find('td', class_='text-danger')),
                           'owner': owner.group(1).strip() if owner else '',
                           'trainer': trainer.group(1).strip() if trainer else '',
                           'races': races})
        surface = surface_of(name, horses)
        for i, x in enumerate(horses, 1):
            x['board_pos'] = i
            x['points'] = x.pop('tot').get(surface, 0)
        # Points rank ignores Challenge winners' automatic berths; ties share the higher rank.
        pts = sorted((x['points'] for x in horses), reverse=True)
        for x in horses:
            x['points_rank'] = pts.index(x['points']) + 1
            x['points_tied'] = pts.count(x['points']) > 1
        out.append({'name': name, 'surface': surface, 'horses': horses})
    return out


def main():
    divisions = parse(fetch())
    n = sum(len(d['horses']) for d in divisions)
    if len(divisions) < 10 or n < 100:
        fail('parsed only %d divisions / %d horses -- page layout changed?' % (len(divisions), n))
    today = date.today().isoformat()
    old = {}
    if os.path.exists(OUT):
        try: old = json.load(open(OUT))
        except Exception: old = {}
    # prev = the last snapshot from an EARLIER day, so the workflow's four daily runs never
    # overwrite yesterday's baseline with this morning's own numbers.
    if old.get('for_date') and old['for_date'] != today:
        prev_date = old['for_date']
        prev = {d['name'] + '|' + x['name']: {'points': x['points'], 'points_rank': x['points_rank'],
                                              'board_pos': x['board_pos']}
                for d in old.get('divisions', []) for x in d['horses']}
    else:
        prev_date, prev = old.get('prev_date', ''), old.get('prev', {})
    json.dump({'for_date': today, 'built_utc': datetime.utcnow().isoformat() + 'Z', 'source': URL,
               'event': EVENT, 'divisions': divisions, 'prev_date': prev_date, 'prev': prev},
              open(OUT, 'w'), ensure_ascii=False, indent=1)
    print('BC_OK for=%s divisions=%d horses=%d prev=%s' % (today, len(divisions), n, prev_date or 'none'))


if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        fail(type(e).__name__ + ': ' + str(e))

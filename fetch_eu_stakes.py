#!/usr/bin/env python3
"""
Build the EU stakes JSON that the daily digest consumes.

WHY THIS EXISTS
---------------
The digest runs in CCR (Claude Cloud Runner), whose sandbox blocks essentially all
outbound network. Measured Aug 18 2026 from inside CCR:

    rapi=000/0   sdl=000/0   rp=000/0   example.com=000/0   raw.githubusercontent.com=200

000 means the TCP connection never completed. Only raw.githubusercontent.com is
reachable. So NOTHING the digest fetches directly can ever work there -- not
theracingapi.com, not thestatsdontlie.com, not racingpost.com. That is why EU stakes
silently vanished from Aug 17 onward while the identical code worked perfectly on a
laptop.

The fix is to move the fetch off CCR entirely. This script runs in GitHub Actions,
which has normal network access, and commits its output back to the public mirror.
CCR then just downloads the finished JSON from raw.githubusercontent.com -- the one
host it is allowed to reach.

The credential is never in this file. It arrives as RACING_API_CREDS, stored as an
encrypted GitHub Actions secret.

OUTPUT (schema unchanged, so the generator needs no changes):
    eu_upcoming_json.json  [{day_label, races:[{grade,race_name,date_short,track,
                             country,flag,dist_surface}]}]
    eu_recap_json.json     [{grade,race_name,track,country,flag,dist_surface,
                             winner,off_time}]
"""
import json, os, sys, time, urllib.request, base64
from datetime import date, timedelta

CREDS = os.environ.get('RACING_API_CREDS', '').strip()
if not CREDS:
    print('FATAL: RACING_API_CREDS not set', file=sys.stderr)
    sys.exit(1)

BASE = 'https://api.theracingapi.com/v1'
# gb, ire, fr, ger are the only codes this endpoint accepts. 'ita' returns HTTP 422
# "unrecognised region code" and, because codes go as one query string, ONE bad code
# fails the ENTIRE request for every day. Verified individually Aug 17 2026.
REGIONS = '&'.join('region_codes=' + r for r in ('gb', 'ire', 'fr', 'ger'))

GROUP = {'Group 1', 'Group 2', 'Group 3', 'Groupe 1', 'Groupe 2', 'Groupe 3',
         'Gruppo 1', 'Gruppo 2', 'Gruppo 3'}
GRADE = {'Group 1': 'G1', 'Group 2': 'G2', 'Group 3': 'G3',
         'Groupe 1': 'G1', 'Groupe 2': 'G2', 'Groupe 3': 'G3',
         'Gruppo 1': 'G1', 'Gruppo 2': 'G2', 'Gruppo 3': 'G3', 'Listed': 'LR'}
EU_REGIONS = {'gb', 'ire', 'fr', 'ger', 'ita', 'bel', 'swe', 'spa', 'den', 'nor', 'hol', 'aut'}
FLAGS = {'GB': '\U0001f1ec\U0001f1e7', 'IRE': '\U0001f1ee\U0001f1ea', 'FR': '\U0001f1eb\U0001f1f7',
         'GER': '\U0001f1e9\U0001f1ea', 'ITA': '\U0001f1ee\U0001f1f9', 'BEL': '\U0001f1e7\U0001f1ea',
         'SWE': '\U0001f1f8\U0001f1ea', 'SPA': '\U0001f1ea\U0001f1f8', 'DEN': '\U0001f1e9\U0001f1f0',
         'NOR': '\U0001f1f3\U0001f1f4', 'HOL': '\U0001f1f3\U0001f1f1', 'AUT': '\U0001f1e6\U0001f1f9'}
DOW = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
MON = {1: 'Jan', 2: 'Feb', 3: 'Mar', 4: 'Apr', 5: 'May', 6: 'Jun',
       7: 'Jul', 8: 'Aug', 9: 'Sep', 10: 'Oct', 11: 'Nov', 12: 'Dec'}
GO = {'G1': 0, 'G2': 1, 'G3': 2, 'LR': 3}
T = date.today()
PACE = 3          # deliberate spacing; this is a paid subscription, not a free-for-all
FAILED_DAYS = []


def get(path):
    """One GET, validated. Returns parsed JSON or None. Never raises."""
    req = urllib.request.Request(BASE + path)
    req.add_header('Authorization', 'Basic ' + base64.b64encode(CREDS.encode()).decode())
    req.add_header('Accept-Encoding', 'gzip')      # 11.4x smaller on the wire
    req.add_header('User-Agent', 'daily-racing-digest/1.0')
    for attempt in (1, 2, 3):
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                raw = r.read()
                if r.headers.get('Content-Encoding') == 'gzip':
                    import gzip
                    raw = gzip.decompress(raw)
                return json.loads(raw.decode('utf-8'))
        except Exception as e:
            print('  attempt %d failed for %s: %s' % (attempt, path.split('?')[0], e))
            if attempt < 3:
                time.sleep(attempt * 6)
    return None


def clean_course(c):
    for suf in ('(IRE)', '(FR)', '(GER)', '(ITA)', '(GB)'):
        c = (c or '').replace(suf, '')
    return c.strip()


def is_stakes(rec):
    # Flat only. This also excludes the Pure Arabian cards, which carry their own
    # "Group" labels but are a different breed and do not belong in a Thoroughbred digest.
    if str(rec.get('type', '')).strip().lower() not in ('flat', ''):
        return False
    if 'arab' in (rec.get('race_name') or '').lower():
        return False
    if rec.get('is_abandoned') in (True, 'true', 'True'):
        return False
    if str(rec.get('region', '')).lower() not in EU_REGIONS:
        return False
    pat = (rec.get('pattern') or '').strip()
    # LISTED IS INCLUDED. The pre-June-2026 filter excluded it, which on Aug 14 2026 meant
    # 1 race reported instead of 5. Do not "tidy" this back to Group-only.
    return pat in GROUP or pat == 'Listed'


def race_row(c, dt):
    reg = str(c.get('region', 'GB')).upper()
    return {
        'grade': GRADE.get((c.get('pattern') or '').strip(), 'LR'),
        'race_name': (c.get('race_name') or '').replace(' ()', '').strip(),
        'date_short': DOW[dt.weekday()] + '\n' + MON[dt.month] + ' ' + str(dt.day),
        'track': clean_course(c.get('course')),
        'country': reg,
        'flag': FLAGS.get(reg, '\U0001f3c1'),
        'dist_surface': str(c.get('distance_round') or c.get('distance') or '?') +
                        ' · ' + str(c.get('surface') or 'Turf'),
    }


# ----------------------------------------------------------------------- upcoming
buckets = {'TODAY': [], 'TOMORROW': []}
for i in range(8):                       # today .. today+7
    d = T + timedelta(days=i)
    if i:
        time.sleep(PACE)
    data = get('/racecards/pro?date=%s&%s' % (d.isoformat(), REGIONS))
    if data is None or not isinstance(data.get('racecards'), list):
        print('DAY_FAIL %s' % d)
        FAILED_DAYS.append(d.isoformat())
        continue
    cards = data['racecards']
    hits = [c for c in cards if is_stakes(c)]
    print('day %s: %d cards, %d stakes' % (d, len(cards), len(hits)))
    for c in hits:
        try:
            cd = date.fromisoformat(str(c.get('date'))[:10])
        except Exception:
            cd = d
        buckets['TODAY' if cd == T else 'TOMORROW'].append(race_row(c, cd))

for k in buckets:
    buckets[k].sort(key=lambda r: (r['date_short'], GO.get(r['grade'], 9), r['track']))

Y = T - timedelta(days=1)
lbl = lambda p, d: p + ' — ' + DOW[d.weekday()] + ' ' + MON[d.month] + ' ' + str(d.day)
upcoming = [
    {'day_label': lbl('YESTERDAY', Y), 'races': []},
    {'day_label': lbl('TODAY', T), 'races': buckets['TODAY']},
    {'day_label': 'TOMORROW — Next 7 days from ' + DOW[(T + timedelta(days=1)).weekday()] +
                  ' ' + MON[(T + timedelta(days=1)).month] + ' ' + str((T + timedelta(days=1)).day),
     'races': buckets['TOMORROW']},
]

# -------------------------------------------------------------------------- recap
time.sleep(PACE)
recap = []
res = get('/results?start_date=%s&end_date=%s&type=flat' % (Y.isoformat(), Y.isoformat()))
if res is None:
    print('RECAP_FAIL %s' % Y)
    FAILED_DAYS.append('results:' + Y.isoformat())
else:
    for r in (res.get('results') or []):
        if not is_stakes(r):
            continue
        win = '?'
        for run in (r.get('runners') or []):
            if str(run.get('position')) == '1':
                win = (run.get('horse') or '?')
                for suf in (' (IRE)', ' (GB)', ' (FR)', ' (GER)'):
                    win = win.replace(suf, '')
                win = win.strip()
                break
        reg = str(r.get('region', 'GB')).upper()
        recap.append({
            'grade': GRADE.get((r.get('pattern') or '').strip(), 'LR'),
            'race_name': (r.get('race_name') or '').replace(' ()', '').strip(),
            'track': clean_course(r.get('course')),
            'country': reg,
            'flag': FLAGS.get(reg, '\U0001f3c1'),
            'dist_surface': str(r.get('dist') or '?') + ' · ' + str(r.get('surface') or 'Turf'),
            'winner': win,
            'off_time': r.get('off') or '',
        })
    recap.sort(key=lambda x: (GO.get(x['grade'], 9), x['track']))
    # Seed YESTERDAY from results so the upcoming table shows what actually ran.
    upcoming[0]['races'] = [{
        'grade': x['grade'], 'race_name': x['race_name'],
        'date_short': DOW[Y.weekday()] + '\n' + MON[Y.month] + ' ' + str(Y.day),
        'track': x['track'], 'country': x['country'], 'flag': x['flag'],
        'dist_surface': x['dist_surface']} for x in recap]

total = sum(len(b['races']) for b in upcoming)

# Refuse to publish a wholesale-empty result when days failed -- that would overwrite good
# data with an artefact of a network problem, which is the exact class of silent loss this
# whole rebuild exists to stop.
if FAILED_DAYS and total == 0 and not recap:
    print('ABORT: %d fetch failures and nothing to publish; leaving existing JSON untouched'
          % len(FAILED_DAYS), file=sys.stderr)
    sys.exit(1)

json.dump(upcoming, open('eu_upcoming_json.json', 'w'), ensure_ascii=False, indent=1)
json.dump(recap, open('eu_recap_json.json', 'w'), ensure_ascii=False, indent=1)
json.dump({'built_utc': __import__('datetime').datetime.utcnow().isoformat() + 'Z',
           'for_date': T.isoformat(), 'upcoming': total, 'recap': len(recap),
           'failed_days': FAILED_DAYS, 'source': 'theracingapi.com'},
          open('eu_build_status.json', 'w'), indent=1)

print('BUILD_OK for=%s upcoming=%d recap=%d failed_days=%d'
      % (T, total, len(recap), len(FAILED_DAYS)))
for b in upcoming:
    print('  %s (%d)' % (b['day_label'], len(b['races'])))
    for r in b['races']:
        print('      [%s] %s @ %s (%s) %s' % (r['grade'], r['race_name'][:52],
                                              r['track'], r['country'], r['dist_surface']))

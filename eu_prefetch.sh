#!/bin/bash
# EU pre-fetch — SDL-ONLY architecture (Racing API REMOVED June 26, 2026)
#
# Writes:
#   /tmp/eu_upcoming_json.json — EU graded races for YESTERDAY/TODAY/TOMORROW (from thestatsdontlie.com)
#   /tmp/eu_sdl_json.json      — raw SDL parse output (debug/backup)
#   /tmp/eu_recap_json.json    — EU graded results YESTERDAY (from racingpost.com)
#   /tmp/eu_prefetch_status.json — race counts + ISO timestamp
#
# Two sources, both scraping public pages — NO API dependencies:
#   - thestatsdontlie.com/horse-racing/ → upcoming graded stakes
#   - racingpost.com/results/YYYY-MM-DD → yesterday's results
#
# Runs in CCR STEP 0 bootstrap BEFORE agent reads digest_prompt.txt.

set -e

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

# ──────────────────────────────────────────────────────────────────
# SDL UPCOMING — thestatsdontlie.com is the SOLE source
# ──────────────────────────────────────────────────────────────────
SDL_URL="https://www.thestatsdontlie.com/horse-racing/"
echo "EU_PREFETCH: fetching upcoming from ${SDL_URL}"
curl -s -L -A "${UA}" "${SDL_URL}" -o /tmp/sdl.html || true
SDL_BYTES=$(wc -c < /tmp/sdl.html 2>/dev/null || echo 0)
echo "EU_PREFETCH: downloaded ${SDL_BYTES} bytes from SDL"

if [ "${SDL_BYTES}" -lt 50000 ]; then
    echo "EU_PREFETCH_WARN: SDL page too small (${SDL_BYTES} bytes) — writing empty JSONs"
    echo '[{"day_label":"YESTERDAY — ?","races":[]},{"day_label":"TODAY — ?","races":[]},{"day_label":"TOMORROW — ?","races":[]}]' > /tmp/eu_upcoming_bash.json
    echo '[]' > /tmp/eu_sdl_json.json
else
python3 << 'PYSDL'
import re, html, json, os
from datetime import date, timedelta

raw = open('/tmp/sdl.html').read()
# Strip HTML tags, NORMALIZE ALL DASH CHARS to ASCII hyphen, then parse
clean = re.sub(r'<[^>]+>', ' ', raw)
clean = html.unescape(clean)
# CCR Python locale issue fix: replace ALL dash-like unicode chars with regular hyphen
clean = clean.replace('–', '-').replace('—', '-').replace('−', '-').replace('‐', '-').replace('‑', '-')
clean = re.sub(r'\s+', ' ', clean)
# Separator MUST have spaces on both sides; race name allows hyphens (e.g., "Coral-Eclipse Stakes")
pat = re.compile(r'(\d{2}/\d{2}/\d{2})\s+-\s+([^()]{5,100}?)\s+\(([^)]+)\)\s+-\s+([A-Za-z][A-Za-z0-9 ]{3,30}?)(?=\s+\d{2}/\d{2}/\d{2}|\s+[A-Z][a-z]+\s+[A-Z]|\s*$)')
matches = pat.findall(clean)
print('EU_PREFETCH: parsed ' + str(len(matches)) + ' race entries from SDL page (after dash normalization)')

# Debug: log what was actually captured so we can see in CCR logs
for m in matches[:15]:
    print('  RAW_MATCH: date=' + m[0] + ' race=' + m[1].strip()[:50] + ' course=' + m[2] + ' grade=' + m[3].strip())

CC = {}
for c in ['ASCOT','NEWMARKET','YORK','EPSOM','GOODWOOD','SANDOWN','HAYDOCK','DONCASTER','NEWBURY','LINGFIELD','KEMPTON','CHESTER','NEWCASTLE','PONTEFRACT','SALISBURY','WINDSOR','BATH','BEVERLEY','BRIGHTON','CARLISLE','CATTERICK','HAMILTON','LEICESTER','MUSSELBURGH','NOTTINGHAM','REDCAR','RIPON','THIRSK','WARWICK','WOLVERHAMPTON','YARMOUTH']: CC[c]='GB'
for c in ['CURRAGH','THE CURRAGH','LEOPARDSTOWN','NAAS','CORK','TIPPERARY','GALWAY','FAIRYHOUSE','KILLARNEY','LIMERICK','GOWRAN PARK','BELLEWSTOWN','DUNDALK','DOWN ROYAL','PUNCHESTOWN','ROSCOMMON','SLIGO','TRAMORE','WEXFORD']: CC[c]='IRE'
for c in ['CHANTILLY','LONGCHAMP','PARISLONGCHAMP','SAINT-CLOUD','SAINT CLOUD','DEAUVILLE','COMPIEGNE','CLAIREFONTAINE','LYON','BORDEAUX','VICHY','TOULOUSE','MAISONS-LAFFITTE']: CC[c]='FR'
for c in ['COLOGNE','HAMBURG','BADEN-BADEN','HOPPEGARTEN','MUNICH','DUSSELDORF','FRANKFURT','HANNOVER','BREMEN','KREFELD']: CC[c]='GER'

GRADE_MAP = {'group 1':'G1','group 2':'G2','group 3':'G3','grade 1':'G1','grade 2':'G2','grade 3':'G3','listed':'LR'}
FLAGS = {'GB':'\U0001f1ec\U0001f1e7','IRE':'\U0001f1ee\U0001f1ea','FR':'\U0001f1eb\U0001f1f7','GER':'\U0001f1e9\U0001f1ea','ITA':'\U0001f1ee\U0001f1f9'}

today = date.today()
# June 29 2026 fix: TOMORROW bucket now absorbs days +1 through +7 (SDL "this week" is forward-rolling
# and only lists upcoming weekend mid-week; without this we drop weekend G1/G2/G3 races entirely).
YESTERDAY_DATE = today - timedelta(days=1)
TODAY_DATE = today
TOMORROW_DATES = [today + timedelta(days=i) for i in range(1, 8)]

# Raw SDL parse output (all dates, for debug)
all_entries = []
prefix_map = {'YESTERDAY':[],'TODAY':[],'TOMORROW':[]}
for date_s, race, course, grade in matches:
    try:
        dd, mm, yy = date_s.split('/')
        iso = '20' + yy + '-' + mm + '-' + dd
    except: continue
    g_clean = re.sub(r'\s+(?:uk|ie|ire|fr|french|irish|races?)+\s*$', '', grade.strip(), flags=re.IGNORECASE).strip()
    g_clean = re.sub(r'\s+(?:uk|ie|ire|fr|french|irish|races?)+\s*$', '', g_clean, flags=re.IGNORECASE).strip()
    g = GRADE_MAP.get(g_clean.lower(), g_clean)
    if g not in ('G1','G2','G3','LR'): continue
    country = CC.get(course.strip().upper(), 'GB')
    race_clean = html.unescape(race).strip()
    all_entries.append({
        'date_iso': iso, 'grade': g, 'race_name': race_clean,
        'course': course.strip(), 'country': country,
        'flag': FLAGS.get(country, '\U0001f3c1'),
    })
    try:
        race_date = date(int(iso[0:4]), int(iso[5:7]), int(iso[8:10]))
    except: continue
    if race_date == YESTERDAY_DATE:
        pfx = 'YESTERDAY'
    elif race_date == TODAY_DATE:
        pfx = 'TODAY'
    elif race_date in TOMORROW_DATES:
        pfx = 'TOMORROW'
    else:
        continue
    prefix_map[pfx].append({
        'grade': g, 'race_name': race_clean,
        'date_short': race_date.strftime('%a')+'\n'+race_date.strftime('%b')+' '+str(race_date.day),
        'track': course.strip(), 'country': country,
        'flag': FLAGS.get(country, '\U0001f3c1'),
        'dist_surface': '? · Turf',
    })

# Sort by grade priority
GO = {'G1':0,'G2':1,'G3':2,'LR':3}
all_entries.sort(key=lambda x: (x['date_iso'], GO.get(x['grade'],9)))
with open('/tmp/eu_sdl_json.json','w') as f: json.dump(all_entries, f, indent=2)
print('EU_PREFETCH: SDL JSON has ' + str(len(all_entries)) + ' total entries')

# Build the upcoming JSON (3 buckets, TOMORROW spans +1..+7)
result = []
for pfx in ('YESTERDAY','TODAY','TOMORROW'):
    if pfx == 'TOMORROW':
        races = sorted(prefix_map[pfx], key=lambda r: (r.get('date_short',''), GO.get(r.get('grade','LR'),9), r.get('track','')))
        label = 'TOMORROW — Next 7 days from ' + TOMORROW_DATES[0].strftime('%a %b') + ' ' + str(TOMORROW_DATES[0].day)
    else:
        races = sorted(prefix_map[pfx], key=lambda r: (GO.get(r.get('grade','LR'),9), r.get('track','')))
        single = YESTERDAY_DATE if pfx == 'YESTERDAY' else TODAY_DATE
        label = pfx + ' — ' + single.strftime('%a %b') + ' ' + str(single.day)
    result.append({'day_label': label, 'races': races})
with open('/tmp/eu_upcoming_bash.json','w') as f: json.dump(result, f, indent=2)
total = sum(len(d['races']) for d in result)
print('EU_PREFETCH_DONE: ' + str(total) + ' EU races written to /tmp/eu_upcoming_bash.json (bash producer — merger writes consumed path)')
for d in result:
    rstr = ', '.join('['+r['grade']+'] '+r['race_name']+' @ '+r['track'] for r in d['races']) if d['races'] else '(none)'
    print('  ' + d['day_label'] + ' (' + str(len(d['races'])) + '): ' + rstr)

# Write status file
import datetime as _dtm
status = {
    'ok': True, 'total_races': total,
    'by_day': {d['day_label'].split()[0]: len(d['races']) for d in result},
    'source': 'thestatsdontlie.com (SDL-only — API removed)',
    'fetched_at': _dtm.datetime.utcnow().isoformat()+'Z',
}
with open('/tmp/eu_prefetch_status.json','w') as f: json.dump(status, f, indent=2)

# Also generate eu_upcoming_section.html for backward compat (generator may read it)
FLAGS2 = FLAGS
GI2 = {'G1':'<span class="grade-icon">\U0001f3c6</span><span class="grade-g1">G1</span>',
       'G2':'<span class="grade-icon">\U0001f948</span><span class="grade-g2">G2</span>',
       'G3':'<span class="grade-icon">\U0001f949</span><span class="grade-g3">G3</span>',
       'LR':'<span class="grade-icon">✏️</span><span class="grade-listed">LR</span>'}
s5i = ''
for day in result:
    s5i += '<div class="day-header">\U0001f4c5 ' + str(day['day_label']) + '</div>\n'
    races = day['races']
    if races:
        s5i += '<table class="race-table"><thead><tr><th style="width:13%">Date</th><th style="width:47%">Race</th><th style="width:26%">Track</th><th style="width:14%">Dist · Surface</th></tr></thead><tbody>\n'
        for r in races:
            fl = FLAGS2.get(r['country'], '\U0001f3c1')
            ds = r['date_short'].replace('\n','<br>')
            s5i += ('<tr><td style="font-size:11px;text-align:center;font-weight:bold;color:#1a1a2e;line-height:1.4">'+ds+'</td>'
                +'<td class="race-name">'+GI2.get(r['grade'],'')+'&nbsp;'+r['race_name']+'</td>'
                +'<td>'+fl+' '+r['track']+'</td><td>'+r['dist_surface']+'</td></tr>\n')
        s5i += '</tbody></table>\n'
    else:
        s5i += '<div class="stable-no-news">No EU graded stakes scheduled.</div>\n'
    s5i += '<div class="track-spacer">&nbsp;</div>\n'
s5html = ('<div class="section-header"><h2><span class="sh-icon">\U0001f4c5</span>Upcoming EU Stakes — Yesterday, Today &amp; Tomorrow</h2></div>\n'
    +'<div class="upcoming-wrapper">\n'+s5i+'</div>\n')
with open('/tmp/eu_upcoming_section.html','w') as f: f.write(s5html)
print('EU_HTML_DONE: ' + str(total) + ' EU races → /tmp/eu_upcoming_section.html')
PYSDL
fi

# ──────────────────────────────────────────────────────────────────
# RACING POST RESULTS — yesterday's results (unchanged)
# ──────────────────────────────────────────────────────────────────
YEST=$(date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null || date -v-1d '+%Y-%m-%d')
RP_URL="https://www.racingpost.com/results/${YEST}"
echo "EU_RECAP_PREFETCH: fetching YESTERDAY=${YEST} from ${RP_URL}"
curl -s -L -A "${UA}" "${RP_URL}" -o /tmp/rp_yesterday.html || true
RP_BYTES=$(wc -c < /tmp/rp_yesterday.html 2>/dev/null || echo 0)
echo "EU_RECAP_PREFETCH: downloaded ${RP_BYTES} bytes"

if [ "${RP_BYTES}" -lt 100000 ]; then
    echo "EU_RECAP_PREFETCH_WARN: RP page too small (${RP_BYTES} bytes) — writing empty JSON"
    echo '[]' > /tmp/eu_recap_bash.json
else
python3 << 'PYRECAP'
import re, html, json
EU_COURSES = {
    'ASCOT','NEWMARKET','YORK','EPSOM','GOODWOOD','SANDOWN','HAYDOCK','DONCASTER','NEWBURY',
    'LINGFIELD','KEMPTON','CHESTER','PONTEFRACT','BATH','SALISBURY','WINDSOR','BEVERLEY',
    'BRIGHTON','CARLISLE','CATTERICK','HAMILTON','LEICESTER','MUSSELBURGH','NEWCASTLE',
    'NOTTINGHAM','REDCAR','RIPON','THIRSK','WARWICK','WOLVERHAMPTON','YARMOUTH','SOUTHWELL',
    'THE CURRAGH','CURRAGH','LEOPARDSTOWN','NAAS','CORK','TIPPERARY','GOWRAN PARK','GALWAY',
    'FAIRYHOUSE','KILLARNEY','LIMERICK','LAYTOWN','BELLEWSTOWN','BALLINROBE','CLONMEL',
    'DUNDALK','DOWN ROYAL','DOWNPATRICK','LISTOWEL','PUNCHESTOWN','ROSCOMMON','SLIGO','TRAMORE','WEXFORD',
    'CHANTILLY','LONGCHAMP','PARISLONGCHAMP','SAINT-CLOUD','SAINT CLOUD','DEAUVILLE',
    'MAISONS-LAFFITTE','LYON','BORDEAUX','VICHY','TOULOUSE','COMPIEGNE','CLAIREFONTAINE',
    'COLOGNE','HAMBURG','BADEN-BADEN','HOPPEGARTEN','MUNICH','DUSSELDORF','FRANKFURT',
    'HANNOVER','DRESDEN','BREMEN','KREFELD','MULHEIM','HALLE',
    'MILAN','ROME','SIENA','PISA','TURIN','MERANO','VARESE','TREVISO',
    'OVREVOLL','BRO PARK','JAGERSRO','TAGERSRO','KLAMPENBORG','GOTEBORG','GOTHENBURG',
}
FLAGS = {'GB':'\U0001f1ec\U0001f1e7','IRE':'\U0001f1ee\U0001f1ea','FR':'\U0001f1eb\U0001f1f7',
         'GER':'\U0001f1e9\U0001f1ea','ITA':'\U0001f1ee\U0001f1f9','SWE':'\U0001f1f8\U0001f1ea'}
CC = {}
for c in {'ASCOT','NEWMARKET','YORK','EPSOM','GOODWOOD','SANDOWN','HAYDOCK','DONCASTER','NEWBURY','LINGFIELD','KEMPTON','CHESTER','PONTEFRACT','BATH','SALISBURY','WINDSOR','BEVERLEY','BRIGHTON','CARLISLE','CATTERICK','HAMILTON','LEICESTER','MUSSELBURGH','NEWCASTLE','NOTTINGHAM','REDCAR','RIPON','THIRSK','WARWICK','WOLVERHAMPTON','YARMOUTH','SOUTHWELL'}: CC[c]='GB'
for c in {'THE CURRAGH','CURRAGH','LEOPARDSTOWN','NAAS','CORK','TIPPERARY','GOWRAN PARK','GALWAY','FAIRYHOUSE','KILLARNEY','LIMERICK','LAYTOWN','BELLEWSTOWN','BALLINROBE','CLONMEL','DUNDALK','DOWN ROYAL','DOWNPATRICK','LISTOWEL','PUNCHESTOWN','ROSCOMMON','SLIGO','TRAMORE','WEXFORD'}: CC[c]='IRE'
for c in {'CHANTILLY','LONGCHAMP','PARISLONGCHAMP','SAINT-CLOUD','SAINT CLOUD','DEAUVILLE','MAISONS-LAFFITTE','LYON','BORDEAUX','VICHY','TOULOUSE','COMPIEGNE','CLAIREFONTAINE'}: CC[c]='FR'
for c in {'COLOGNE','HAMBURG','BADEN-BADEN','HOPPEGARTEN','MUNICH','DUSSELDORF','FRANKFURT','HANNOVER','DRESDEN','BREMEN','KREFELD','MULHEIM','HALLE'}: CC[c]='GER'
for c in {'MILAN','ROME','SIENA','PISA','TURIN','MERANO','VARESE','TREVISO'}: CC[c]='ITA'
for c in {'OVREVOLL','BRO PARK','JAGERSRO','TAGERSRO','KLAMPENBORG','GOTEBORG','GOTHENBURG'}: CC[c]='SWE'

raw = open('/tmp/rp_yesterday.html').read()
panel_re = re.compile(r'data-diffusion-coursename="([^"]+)"\s+data-diffusion-racetime="([^"]+)"[^>]*data-diffusion-race-id="([^"]+)"(.*?)(?=<div class="rp-raceCourse__panel__race"|<div class="rp-raceCourse__panel__container"|</section>)', re.DOTALL)
panels = panel_re.findall(raw)
print('EU_RECAP_PREFETCH: parsed ' + str(len(panels)) + ' race panels on page')
races = []; seen = set()
for course, off_time, race_id, body in panels:
    cu = course.upper()
    if cu not in EU_COURSES: continue
    nm = re.search(r'rp-raceCourse__panel__race__info__title__link[^>]*>\s*<span>([^<]+)</span>', body)
    if not nm: continue
    fn = html.unescape(nm.group(1)).strip()
    grade = None
    if '(Group 1)' in fn or 'Groupe 1)' in fn or 'Gruppo 1)' in fn: grade = 'G1'
    elif '(Group 2)' in fn or 'Groupe 2)' in fn or 'Gruppo 2)' in fn: grade = 'G2'
    elif '(Group 3)' in fn or 'Groupe 3)' in fn or 'Gruppo 3)' in fn: grade = 'G3'
    elif 'Listed Race' in fn: grade = 'LR'
    if not grade: continue
    cn = re.sub(r'\s*\((?:Group\s*\d|Groupe\s*\d|Gruppo\s*\d|Listed Race)[^)]*\)\s*(?:\([^)]*\))?\s*$', '', fn).strip()
    dm = re.search(r'rp-raceCourse__panel__race__info__distance[^>]*>([^<]+)<', body)
    dist = dm.group(1).strip() if dm else '?'
    gm = re.search(r'Going:\s*([^<]+)<', body)
    going = gm.group(1).strip() if gm else ''
    surface = 'AWT' if any(s in going for s in ('Polytrack','All-Weather','Tapeta')) else 'Turf'
    wm = re.search(r'data-outcome-desc="1st".*?<a[^>]*href="/profile/horse/\d+/([^"]+)"', body, re.DOTALL)
    winner = wm.group(1).replace('-',' ').title() if wm else '?'
    country = CC.get(cu, 'GB')
    key = (cu, off_time, cn.lower())
    if key in seen: continue
    seen.add(key)
    races.append({'grade':grade,'race_name':cn,'track':course.title(),'country':country,
                  'flag':FLAGS.get(country,'\U0001f3c1'),'dist_surface':f"{dist} · {surface}",
                  'winner':winner,'off_time':off_time})
GO = {'G1':0,'G2':1,'G3':2,'LR':3}
races.sort(key=lambda r: (GO.get(r['grade'],9), r['track'], r['off_time']))
with open('/tmp/eu_recap_bash.json','w') as f: json.dump(races, f, indent=2)
print('EU_RECAP_DONE: ' + str(len(races)) + ' EU Group/Listed races written to /tmp/eu_recap_bash.json (bash producer)')
for r in races:
    print('  [' + r['grade'] + '] ' + r['race_name'] + ' | ' + r['track'] + ' (' + r['country'] + ') | ' + r['dist_surface'] + ' | Winner: ' + r['winner'])
PYRECAP
fi

# === WRITE MERGER SCRIPT to /tmp/merge_eu.py (inlined here so CCR has no extra bootstrap download) ===
cat > /tmp/merge_eu.py << 'MERGEEOF'
#!/usr/bin/env python3
# Single source of truth for combining EU race producer outputs.
# Each producer writes its OWN exclusive path; this script is the ONLY writer of consumed paths.
# Eliminates the WebFetch-overwrite trap where a later producer would silently wipe earlier output.
#
# Producer files (any may exist or not):
#   upcoming: /tmp/eu_upcoming_bash.json, /tmp/eu_upcoming_webfetch.json, /tmp/eu_upcoming_cache.json
#   recap:    /tmp/eu_recap_bash.json,    /tmp/eu_recap_webfetch.json
#
# Consumed paths (this script is the ONLY writer):
#   /tmp/eu_upcoming_json.json — read by Step 7.5 generator + verifiers
#   /tmp/eu_recap_json.json    — read by Step 7.5 generator + verifiers + Step 4c-R-EU subagent
#
# Usage: python3 /tmp/merge_eu.py [upcoming|recap|all]   (default: all)
import sys, os, json
GO = {'G1':0,'G2':1,'G3':2,'LR':3}
def normname(n):
    s = (n or '').lower().strip()
    for suf in [' stakes',' s.',' h.',' handicap']:
        if s.endswith(suf): s = s[:-len(suf)]
    for pfx in ['paddy power ','jenningsbet ','al basti equiworld dubai ','jebel ali racecourse and stables ','goffs ','fasig-tipton ','dubai duty free ','coral-']:
        if s.startswith(pfx): s = s[len(pfx):]
    return s.strip()
def _load(path):
    if not os.path.exists(path): return None
    try:
        with open(path) as f: return json.load(f)
    except Exception as e:
        print('MERGE_WARN: could not parse ' + path + ' — ' + str(e), file=sys.stderr); return None
def merge_upcoming():
    bash = _load('/tmp/eu_upcoming_bash.json') or []
    webfetch = _load('/tmp/eu_upcoming_webfetch.json') or []
    cache = _load('/tmp/eu_upcoming_cache.json') or []
    by_prefix = {'YESTERDAY':[], 'TODAY':[], 'TOMORROW':[]}
    day_label = {'YESTERDAY':'', 'TODAY':'', 'TOMORROW':''}
    seen = {'YESTERDAY':set(), 'TODAY':set(), 'TOMORROW':set()}
    def absorb(source, source_name):
        added = 0
        for day in source:
            pfx = (day.get('day_label','').split() or [''])[0]
            if pfx not in by_prefix: continue
            if not day_label[pfx]: day_label[pfx] = day.get('day_label','')
            for race in day.get('races', []):
                key = (race.get('grade',''), normname(race.get('race_name','')))
                if not key[1]: continue
                if key in seen[pfx]: continue
                seen[pfx].add(key); by_prefix[pfx].append(race); added += 1
        if added > 0: print('  MERGE_UPCOMING: ' + source_name + ' added ' + str(added) + ' races')
    absorb(bash, 'bash'); absorb(webfetch, 'webfetch'); absorb(cache, 'cache')
    for pfx in by_prefix:
        if pfx == 'TOMORROW':
            by_prefix[pfx].sort(key=lambda r: (r.get('date_short',''), GO.get(r.get('grade','LR'),9), r.get('track','')))
        else:
            by_prefix[pfx].sort(key=lambda r: (GO.get(r.get('grade','LR'),9), r.get('track','')))
    result = []
    for pfx in ('YESTERDAY','TODAY','TOMORROW'):
        lbl = day_label[pfx] or (pfx + ' — ?')
        result.append({'day_label': lbl, 'races': by_prefix[pfx]})
    with open('/tmp/eu_upcoming_json.json','w') as f: json.dump(result, f, indent=2)
    total = sum(len(d['races']) for d in result)
    print('MERGE_UPCOMING_DONE: ' + str(total) + ' total races written to /tmp/eu_upcoming_json.json')
    for d in result: print('  ' + d['day_label'] + ' (' + str(len(d['races'])) + ')')
    return total
def merge_recap():
    bash = _load('/tmp/eu_recap_bash.json') or []
    webfetch = _load('/tmp/eu_recap_webfetch.json') or []
    result = []; seen = set()
    def absorb(source, source_name):
        added = 0
        for race in source:
            key = (race.get('grade',''), normname(race.get('race_name','')))
            if not key[1]: continue
            if key in seen: continue
            seen.add(key); result.append(race); added += 1
        if added > 0: print('  MERGE_RECAP: ' + source_name + ' added ' + str(added) + ' races')
    absorb(bash, 'bash'); absorb(webfetch, 'webfetch')
    result.sort(key=lambda r: (GO.get(r.get('grade','LR'),9), r.get('course','')))
    with open('/tmp/eu_recap_json.json','w') as f: json.dump(result, f, indent=2)
    print('MERGE_RECAP_DONE: ' + str(len(result)) + ' EU Group/Listed races written to /tmp/eu_recap_json.json')
    return len(result)
if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'all'
    if mode in ('upcoming','all'): merge_upcoming()
    if mode in ('recap','all'): merge_recap()
MERGEEOF
chmod +x /tmp/merge_eu.py

# === MERGE: producer outputs → consumed paths ===
# Run the merger to seed /tmp/eu_upcoming_json.json + /tmp/eu_recap_json.json from bash output.
# Later CCR steps (Step 5-RP, Step 7.0.5, Step 7.0.6) write their own *_webfetch.json or
# *_cache.json producer files and re-run /tmp/merge_eu.py. The merger is the ONLY writer of the
# consumed paths — eliminates the WebFetch-overwrite trap (commit 0f5b0f7 era).
python3 /tmp/merge_eu.py all

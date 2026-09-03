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

# Aug 7 2026 FIX — bound every fetch.
# These curls previously had NO timeout at all. They run in the STEP 0 bootstrap,
# which executes BEFORE the agent reads digest_prompt.txt, so a stalled connection to
# thestatsdontlie.com (500KB) or racingpost.com (2.1MB) hangs the whole CCR session
# until it exhausts its budget and dies -- producing no digest draft and not even the
# Step 8 "AGENT ERROR" failsafe draft. That is the exact signature of the Aug 7 2026
# 6am primary-routine failure (fired 10:09:56Z, zero output, zero trace).
# `|| true` below guards a non-zero exit code but does NOT guard a hang; only --max-time does.
CURL_OPTS=(--connect-timeout 15 --max-time 120 --retry 2 --retry-delay 3 --retry-connrefused)

# Aug 12 2026 FIX — fetch_validated(): retry on HTTP-level blocks AND short bodies.
# curl --retry only covers connection errors and 5xx; it does NOT retry 403/406/429.
# Observed live on Aug 12 2026: racingpost.com returned HTTP 406 with a 5,291-byte block
# page after a few rapid requests. When that happens the byte-size guards below write an
# EMPTY eu_*.json, the merger happily reports "MERGE_UPCOMING_DONE: 0 races", and the
# digest renders "No graded stakes scheduled" for every day with only a WARN in the log.
# That is the Aug 12 2026 upcoming-stakes outage: the file existed, it was just empty.
# Browser-like Accept / Accept-Language headers also markedly reduce 406 rejections.
fetch_validated() {
    local url="$1" out="$2" minbytes="$3" label="$4"
    local attempt code size
    for attempt in 1 2 3; do
        # Aug 13 2026: --compressed REMOVED. If the runtime curl lacks brotli, the server may
        # return br-encoded bytes that curl cannot decode; the file is still large enough to pass
        # the size gate but parses to ZERO races, which looks identical to "the source blocked us".
        # Plain requests return HTTP 200 from both sources, so the flag bought nothing.
        code=$(curl -s -L "${CURL_OPTS[@]}" -A "${UA}" \
            -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8' \
            -H 'Accept-Language: en-GB,en;q=0.9' \
            -o "$out" -w '%{http_code}' "$url" 2>/dev/null || echo 000)
        size=$(wc -c < "$out" 2>/dev/null || echo 0)
        if [ "$code" = "200" ] && [ "$size" -ge "$minbytes" ]; then
            echo "${label}_FETCH: OK on attempt ${attempt} (http ${code}, ${size} bytes)"
            return 0
        fi
        echo "${label}_FETCH_RETRY: attempt ${attempt} rejected (http ${code}, ${size} bytes, need >=${minbytes})"
        [ "$attempt" -lt 3 ] && sleep $((attempt * 6))
    done
    echo "${label}_FETCH_FAIL: all 3 attempts failed (last http ${code}, ${size} bytes) — downstream JSON will be EMPTY"
    return 1
}


# ══════════════════════════════════════════════════════════════════════════════
# RACING API — PRIMARY EU SOURCE  (restored Aug 14 2026)
#
# History: all Racing API code was purged Jun 27 2026 (commit bd9cfca) on the
# directive "IT CAN NOT USE THAT EVER AGAIN", after the agent repeatedly reported
# the API as unavailable. That diagnosis was wrong twice over:
#   1. The FAILURES were calling-mechanism failures, not data failures -- urllib
#      blocked by Cloudflare JA3, subprocess blocked inside heredocs. Plain
#      `curl -u` works fine and is what we use here.
#   2. The old filter EXPLICITLY DISCARDED Listed races ("Listed, non-graded ...
#      excluded by Python filter"), so even a working API would have surfaced
#      only Group races. On Aug 14 2026 that meant 1 race instead of 5.
#
# Measured Aug 14 2026: SDL scraping found 1 EU stakes race. This API returned 5,
# matching a manual track-by-track audit exactly -- 3 Listed at Cork/Newbury and a
# Listed at Clairefontaine that SDL could not see at all (it carries no French
# racing). It also supplies real distances, fixing the "? · Turf" placeholders.
#
# The credential is NEVER stored in this file. digest_prompt.txt and eu_prefetch.sh
# are mirrored to a PUBLIC repo; the key lives only in the private CCR routine
# prompt and arrives as the RACING_API_CREDS environment variable. If it is unset
# or the API fails, this block writes nothing and the SDL/Racing Post scrapers
# below run exactly as before.
# ══════════════════════════════════════════════════════════════════════════════
# ══════════════════════════════════════════════════════════════════════════════
# TIER 0 — PRE-BUILT JSON FROM THE PUBLIC MIRROR  (added Aug 18 2026)
#
# THIS IS THE ONLY TIER THAT WORKS INSIDE CCR. Measured from inside CCR Aug 18 2026:
#   api.theracingapi.com 000/0 | thestatsdontlie.com 000/0 | racingpost.com 000/0
#   example.com 000/0          | raw.githubusercontent.com 200
# 000 = the TCP connection never completed. CCR blocks essentially all egress; only
# raw.githubusercontent.com is reachable. Every direct-fetch tier below is therefore
# dead in CCR and alive only on a laptop -- which is exactly why EU stakes silently
# vanished from Aug 17 while identical code passed every local test.
#
# A GitHub Actions workflow (.github/workflows/eu-stakes.yml in the public mirror) runs
# fetch_eu_stakes.py on GitHub's own machines, where the network works, and commits the
# finished JSON. We just download it.
#
# STALENESS IS GRADED, NOT BINARY  (rewritten Sep 3 2026)
# -------------------------------------------------------
# The old rule was `for_date == today or reject outright`. That destroyed the Sep 3 email:
# GitHub dispatched the 09:27 UTC cron 4-11.5 HOURS late every day from Aug 27 on (runs all
# had conclusion=success and 0 min queue -- GitHub's scheduler simply fired late), so at the
# 10:00 UTC digest the mirror still held yesterday's build, tier 0 was rejected, and the only
# EU races that survived were whatever the SDL WebFetch happened to scrape. The Longchamp
# G3/Listed card and the Haydock G1 vanished.
#
# The rejection was also unnecessary. A build for_date=D covers D through D+7, so yesterday's
# build still contains today's and this week's races -- it just files them under the wrong
# day_label. Verified Sep 3: the Sep 2 build held 8 races incl. today's Salisbury G3 and
# Saturday's Haydock G1, all discarded. So instead of trusting day_label we RE-BUCKET every
# race by its own date, which makes the pipeline immune to how late the Action runs.
#
# Two things this must NOT do, both of which were the point of the original strict gate:
#   1. Never present stale RESULTS as yesterday's. A build for_date=D has recap for D-1, so
#      it is only valid as "yesterday" when age==0. Older builds ship upcoming only.
#   2. Never let a stale build suppress the live fetch. Only age==0 sets tier0_ok/rapi_ok.
#      A stale build lands in its own producer slot as a FLOOR; the direct fetch and the
#      scrapers still run and the merger unions on top of it.
# ══════════════════════════════════════════════════════════════════════════════
MIRROR="https://raw.githubusercontent.com/Dzik22/DailyRacingEmail-Public/main"
# Clear BOTH flags here, once. The API block used to do `rm -f /tmp/rapi_ok` itself, which
# ran AFTER tier 0 had set it and silently wiped it -- the scrapers then re-ran and
# overwrote 19 good races with 6. Caught by the tier-0 smoke test.
rm -f /tmp/tier0_ok /tmp/rapi_ok /tmp/eu_upcoming_tier0.json /tmp/eu_recap_tier0.json
TODAY_ISO=$(date '+%Y-%m-%d')
if curl -sSL "${CURL_OPTS[@]}" "${MIRROR}/eu_build_status.json?cb=$$" -o /tmp/mirror_status.json 2>/dev/null; then
  MSTAT=$(python3 -c "
import json
from datetime import date
try:
    d = json.load(open('/tmp/mirror_status.json'))
    fd = d.get('for_date','?')
    try:
        age = (date.today() - date(*[int(x) for x in fd.split('-')])).days
    except Exception:
        age = 999
    print(fd, d.get('upcoming',0), d.get('recap',0), len(d.get('failed_days',[])), age)
except Exception:
    print('? 0 0 0 999')
" 2>/dev/null || echo '? 0 0 0 999')
  set -- $MSTAT
  MDATE="$1"; MUP="$2"; MREC="$3"; MFAIL="$4"; MAGE="$5"
  echo "EU_TIER0: mirror build for_date=${MDATE} (age ${MAGE}d) upcoming=${MUP} recap=${MREC} failed_days=${MFAIL} (today=${TODAY_ISO})"
  # age 0 = built for today. age 1-3 = the Action ran late (see header); still usable for
  # upcoming because a build covers for_date .. for_date+7. Beyond 3 days the tail no longer
  # reaches far enough forward to be worth anything.
  if [ "$MAGE" -ge 0 ] 2>/dev/null && [ "$MAGE" -le 3 ] 2>/dev/null; then
    curl -sSL "${CURL_OPTS[@]}" "${MIRROR}/eu_upcoming_json.json?cb=$$" -o /tmp/tier0_upcoming_raw.json 2>/dev/null || true
    curl -sSL "${CURL_OPTS[@]}" "${MIRROR}/eu_recap_json.json?cb=$$"    -o /tmp/tier0_recap_raw.json    2>/dev/null || true
    # Re-bucket by each race's OWN date so a late build files races correctly instead of
    # under a day_label that was true when the Action ran. Writes the tier0 producer slot;
    # the merger unions it with the bash/webfetch/cache producers.
    TIER0_N=$(MAGE="$MAGE" python3 - <<'T0EOF' 2>/dev/null || echo 0
import json, os, re
from datetime import date, timedelta

MON = {'Jan':1,'Feb':2,'Mar':3,'Apr':4,'May':5,'Jun':6,
       'Jul':7,'Aug':8,'Sep':9,'Oct':10,'Nov':11,'Dec':12}
DOW = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun']
GO  = {'G1':0,'G2':1,'G3':2,'LR':3}
T   = date.today()
age = int(os.environ.get('MAGE', '0'))

try:
    raw = json.load(open('/tmp/tier0_upcoming_raw.json'))
    assert isinstance(raw, list)
except Exception:
    print(0); raise SystemExit(0)

def resolve(race):
    """'Thu\\nSep 3' -> a real date. Month+day is unambiguous inside a +/-20d window."""
    m = re.search(r'([A-Z][a-z]{2})\s+(\d{1,2})', str(race.get('date_short','')))
    if not m:
        return None
    mo, dy = MON.get(m.group(1)), int(m.group(2))
    if not mo:
        return None
    for off in range(-12, 21):
        c = T + timedelta(days=off)
        if c.month == mo and c.day == dy:
            return c
    return None

buckets, seen = {'YESTERDAY': [], 'TODAY': [], 'TOMORROW': []}, set()
unresolved = 0
for day in raw:
    pfx = (str(day.get('day_label','')).split() or [''])[0]
    for r in day.get('races', []):
        d = resolve(r)
        if d is None:
            # Keep it rather than lose it, but only from a same-day build where the
            # original day_label is still trustworthy.
            if age == 0 and pfx in buckets:
                unresolved += 1
            else:
                continue
            tgt = pfx
        elif d < T - timedelta(days=1):
            continue                      # already run and older than yesterday
        elif d == T - timedelta(days=1):
            tgt = 'YESTERDAY'
        elif d == T:
            tgt = 'TODAY'
        else:
            tgt = 'TOMORROW'
        key = (r.get('grade',''), re.sub(r'\s+', ' ', str(r.get('race_name','')).lower()).strip(),
               d.isoformat() if d else pfx)
        if not key[1] or key in seen:
            continue
        seen.add(key)
        if d is not None:                 # restamp so downstream shows the right day
            r = dict(r, date_short=DOW[d.weekday()] + '\n' +
                     [k for k, v in MON.items() if v == d.month][0] + ' ' + str(d.day))
        buckets[tgt].append(r)

for k in buckets:
    buckets[k].sort(key=lambda r: (r.get('date_short',''), GO.get(r.get('grade','LR'), 9), r.get('track','')))

Y, TM = T - timedelta(days=1), T + timedelta(days=1)
inv = {v: k for k, v in MON.items()}
lbl = lambda p, d: p + ' — ' + DOW[d.weekday()] + ' ' + inv[d.month] + ' ' + str(d.day)
out = [
    {'day_label': lbl('YESTERDAY', Y), 'races': buckets['YESTERDAY']},
    {'day_label': lbl('TODAY', T),     'races': buckets['TODAY']},
    {'day_label': 'TOMORROW — Next 7 days from ' + DOW[TM.weekday()] + ' ' + inv[TM.month] +
                  ' ' + str(TM.day), 'races': buckets['TOMORROW']},
]
json.dump(out, open('/tmp/eu_upcoming_tier0.json', 'w'), ensure_ascii=False, indent=1)

# Results are for for_date-1. Only a same-day build's recap is actually yesterday's.
if age == 0:
    try:
        rec = json.load(open('/tmp/tier0_recap_raw.json'))
        if isinstance(rec, list):
            json.dump(rec, open('/tmp/eu_recap_tier0.json', 'w'), ensure_ascii=False, indent=1)
    except Exception:
        pass

print(sum(len(b['races']) for b in out))
T0EOF
)
    TIER0_N=${TIER0_N:-0}
    if [ "$TIER0_N" -gt 0 ] 2>/dev/null; then
      if [ "$MAGE" = "0" ]; then
        touch /tmp/tier0_ok /tmp/rapi_ok
        echo "EU_TIER0_OK: ${TIER0_N} races from today's pre-built mirror JSON — no direct fetching needed"
      else
        # Deliberately do NOT set tier0_ok/rapi_ok: this is a floor, not a substitute.
        echo "EU_TIER0_STALE_USABLE: mirror build is ${MAGE}d old (${MDATE}); re-bucketed ${TIER0_N} races by race date and kept them as a floor. Direct fetch still runs; merger unions on top. Recap skipped (would be ${MAGE}d stale)."
      fi
    else
      echo "EU_TIER0_REJECT: mirror JSON present but empty or unparseable — falling through"
    fi
  else
    echo "EU_TIER0_UNUSABLE: mirror build for ${MDATE} is ${MAGE}d old (>3) — too stale to contribute. Falling through to direct fetch."
  fi
else
  echo "EU_TIER0_UNREACHABLE: could not fetch mirror build status — falling through"
fi

if [ ! -f /tmp/tier0_ok ] && [ -n "${RACING_API_CREDS:-}" ]; then
  echo "EU_RAPI: credential present — theracingapi.com is PRIMARY for EU stakes"
  RAPI_DIR=/tmp/rapi; mkdir -p "$RAPI_DIR"; rm -f "$RAPI_DIR"/*.json 2>/dev/null || true
  # region_codes cuts the payload ~5x (592KB vs 3.1MB per day) -- 8 days goes from ~6MB
  # to ~1.2MB, which matters because this runs inside the CCR session budget.
  # VALID region codes are gb, ire, fr, ger ONLY. "ita" is rejected with
  # HTTP 422 "unrecognised region code" and, because the codes are sent as one query string,
  # ONE bad code fails the ENTIRE request for every day. Verified individually Aug 17 2026.
  # Filtering by region cuts each day from ~3.1MB (all regions) to ~592KB.
  RAPI_REGIONS="region_codes=gb&region_codes=ire&region_codes=fr&region_codes=ger"
  RAPI_DAY_FAIL=0
  # Aug 17 2026: pace the calls deliberately. This is a paid subscription with rate limits and
  # nine requests back-to-back is needlessly aggressive on someone else's service. A 3s gap makes
  # the whole window ~25s instead of ~8s, which is irrelevant inside a 40-minute pipeline but
  # keeps us comfortably inside any throttle. Do NOT remove this to save time.
  RAPI_PACE=3
  for i in 0 1 2 3 4 5 6 7; do
    [ "$i" -gt 0 ] && sleep "$RAPI_PACE"
    D=$(date -d "+${i} day" '+%Y-%m-%d' 2>/dev/null || date -v+${i}d '+%Y-%m-%d')
    F="${RAPI_DIR}/card_${D}.json"
    dayok=0
    # Aug 17 2026 FIX: validate EVERY day's response. The previous version parsed each file
    # with a bare try/except, so any day that returned an error, a truncated body or a
    # malformed payload silently contributed ZERO races -- indistinguishable from a day with
    # no stakes racing. That is how the York Ebor Festival (4 Group 1s) went missing.
    for attempt in 1 2 3; do
      # --compressed: gzip cuts the wire transfer 11.4x (2,030,250 -> 177,358 bytes for a
      # 41-card day, byte-identical after decompression). Across the 8-day window that is
      # ~6.9MB -> ~600KB. This is safe here ONLY because the check below requires a parseable
      # racecards list, so a failed decode is caught rather than silently yielding zero races.
      code=$(curl -s -u "${RACING_API_CREDS}" --compressed "${CURL_OPTS[@]}" \
        "https://api.theracingapi.com/v1/racecards/pro?date=${D}&${RAPI_REGIONS}" \
        -o "$F" -w '%{http_code}' 2>/dev/null || echo 000)
      if [ "$code" = "200" ] && python3 -c "
import json,sys
d=json.load(open('$F'))
sys.exit(0 if isinstance(d.get('racecards'), list) else 1)
" 2>/dev/null; then dayok=1; break; fi
      echo "EU_RAPI_CARD_RETRY ${D}: attempt ${attempt} rejected (http ${code}, $(wc -c < "$F" 2>/dev/null || echo 0) bytes)"
      [ "$attempt" -lt 3 ] && sleep $((attempt * 6))
    done
    if [ "$dayok" = "1" ]; then
      echo "EU_RAPI_CARD ${D}: OK (http ${code}, $(wc -c < "$F" 2>/dev/null || echo 0) bytes)"
    else
      echo "EU_RAPI_CARD_FAIL ${D}: all 3 attempts failed — races for this DATE ARE MISSING, not absent"
      rm -f "$F"
      RAPI_DAY_FAIL=$((RAPI_DAY_FAIL+1))
    fi
  done
  if [ "$RAPI_DAY_FAIL" -gt 0 ]; then
    echo "EU_RAPI_PARTIAL: CRITICAL — ${RAPI_DAY_FAIL} of 8 days could not be fetched."
    echo "  EU coverage for those dates is INCOMPLETE. This is a fetch failure, NOT an empty calendar."
  fi
  sleep "$RAPI_PACE"
  YEST_A=$(date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null || date -v-1d '+%Y-%m-%d')
  code=$(curl -s -u "${RACING_API_CREDS}" --compressed "${CURL_OPTS[@]}" \
    "https://api.theracingapi.com/v1/results?start_date=${YEST_A}&end_date=${YEST_A}&type=flat" \
    -o "${RAPI_DIR}/results.json" -w '%{http_code}' 2>/dev/null || echo 000)
  echo "EU_RAPI_RESULTS ${YEST_A}: http ${code} ($(wc -c < "${RAPI_DIR}/results.json" 2>/dev/null || echo 0) bytes)"

python3 << 'PYRAPI'
import json, os, glob
from datetime import date, timedelta

GROUP = {'Group 1','Group 2','Group 3','Groupe 1','Groupe 2','Groupe 3','Gruppo 1','Gruppo 2','Gruppo 3'}
GRADE = {'Group 1':'G1','Group 2':'G2','Group 3':'G3','Groupe 1':'G1','Groupe 2':'G2','Groupe 3':'G3',
         'Gruppo 1':'G1','Gruppo 2':'G2','Gruppo 3':'G3','Listed':'LR'}
EU_REGIONS = {'gb','ire','fr','ger','ita','bel','swe','spa','den','nor','hol','aut'}
FLAGS = {'GB':'\U0001f1ec\U0001f1e7','IRE':'\U0001f1ee\U0001f1ea','FR':'\U0001f1eb\U0001f1f7',
         'GER':'\U0001f1e9\U0001f1ea','ITA':'\U0001f1ee\U0001f1f9','BEL':'\U0001f1e7\U0001f1ea',
         'SWE':'\U0001f1f8\U0001f1ea','SPA':'\U0001f1ea\U0001f1f8','DEN':'\U0001f1e9\U0001f1f0',
         'NOR':'\U0001f1f3\U0001f1f4','HOL':'\U0001f1f3\U0001f1f1','AUT':'\U0001f1e6\U0001f1f9'}
DOW=['Mon','Tue','Wed','Thu','Fri','Sat','Sun']
MON={1:'Jan',2:'Feb',3:'Mar',4:'Apr',5:'May',6:'Jun',7:'Jul',8:'Aug',9:'Sep',10:'Oct',11:'Nov',12:'Dec'}
T = date.today()

def clean_course(c):
    return (c or '').replace('(IRE)','').replace('(FR)','').replace('(GER)','').replace('(ITA)','').strip()

def is_stakes(rec):
    # Flat only: excludes jumps and, critically, the Pure Arabian cards that carry
    # their own "Group" labels but are a different breed and do not belong here.
    if str(rec.get('type','')).strip().lower() not in ('flat',''): return False
    if 'arab' in (rec.get('race_name') or '').lower(): return False
    if rec.get('is_abandoned') in (True,'true','True'): return False
    if str(rec.get('region','')).lower() not in EU_REGIONS: return False
    pat = (rec.get('pattern') or '').strip()
    return pat in GROUP or pat == 'Listed'

# ---------------------------------------------------------------- UPCOMING
buckets = {'TODAY': [], 'TOMORROW': []}
for f in sorted(glob.glob('/tmp/rapi/card_*.json')):
    try: d = json.load(open(f))
    except Exception: continue
    cards = d.get('racecards') or d.get('data') or (d if isinstance(d, list) else [])
    for c in cards:
        if not is_stakes(c): continue
        try: dt = date.fromisoformat(str(c.get('date'))[:10])
        except Exception: continue
        if dt == T: key = 'TODAY'
        elif T < dt <= T + timedelta(days=7): key = 'TOMORROW'
        else: continue
        reg = str(c.get('region','GB')).upper()
        dist = c.get('distance_round') or c.get('distance') or '?'
        surf = c.get('surface') or 'Turf'
        buckets[key].append({
            'grade': GRADE.get((c.get('pattern') or '').strip(), 'LR'),
            'race_name': (c.get('race_name') or '').replace(' ()','').strip(),
            'date_short': DOW[dt.weekday()] + '\n' + MON[dt.month] + ' ' + str(dt.day),
            'track': clean_course(c.get('course')),
            'country': reg,
            'flag': FLAGS.get(reg, '\U0001f3c1'),
            'dist_surface': str(dist) + ' · ' + str(surf),
        })

GO = {'G1':0,'G2':1,'G3':2,'LR':3}
for k in buckets: buckets[k].sort(key=lambda r: (r['date_short'], GO.get(r['grade'],9), r['track']))
Y = T - timedelta(days=1)
lbl = lambda p, d: p + ' — ' + DOW[d.weekday()] + ' ' + MON[d.month] + ' ' + str(d.day)
upcoming = [{'day_label': lbl('YESTERDAY', Y), 'races': []},
            {'day_label': lbl('TODAY', T), 'races': buckets['TODAY']},
            {'day_label': 'TOMORROW — Next 7 days from ' + DOW[(T+timedelta(days=1)).weekday()] + ' ' + MON[(T+timedelta(days=1)).month] + ' ' + str((T+timedelta(days=1)).day),
             'races': buckets['TOMORROW']}]

# ------------------------------------------------------------------ RECAP
recap = []
if os.path.exists('/tmp/rapi/results.json'):
    try:
        rd = json.load(open('/tmp/rapi/results.json'))
        for r in (rd.get('results') or rd.get('data') or []):
            if not is_stakes(r): continue
            win = '?'
            for run in (r.get('runners') or []):
                if str(run.get('position')) == '1':
                    win = (run.get('horse') or '?').replace(' (IRE)','').replace(' (GB)','').replace(' (FR)','').strip()
                    break
            reg = str(r.get('region','GB')).upper()
            recap.append({
                'grade': GRADE.get((r.get('pattern') or '').strip(), 'LR'),
                'race_name': (r.get('race_name') or '').replace(' ()','').strip(),
                'track': clean_course(r.get('course')),
                'country': reg,
                'flag': FLAGS.get(reg, '\U0001f3c1'),
                'dist_surface': str(r.get('dist') or '?') + ' · ' + str(r.get('surface') or 'Turf'),
                'winner': win,
                'off_time': r.get('off') or '',
            })
        recap.sort(key=lambda x: (GO.get(x['grade'],9), x['track']))
        # seed the YESTERDAY bucket from results so the upcoming table shows what ran
        upcoming[0]['races'] = [{
            'grade': x['grade'], 'race_name': x['race_name'],
            'date_short': DOW[Y.weekday()] + '\n' + MON[Y.month] + ' ' + str(Y.day),
            'track': x['track'], 'country': x['country'], 'flag': x['flag'],
            'dist_surface': x['dist_surface']} for x in recap]
    except Exception as e:
        print('EU_RAPI_RECAP_ERR: ' + str(e))

tot = sum(len(b['races']) for b in upcoming)
if tot > 0 or recap:
    json.dump(upcoming, open('/tmp/eu_upcoming_bash.json','w'), ensure_ascii=False)
    json.dump(recap, open('/tmp/eu_recap_bash.json','w'), ensure_ascii=False)
    open('/tmp/rapi_ok','w').write('1')
    json.dump({'days_fetched': len(glob.glob('/tmp/rapi/card_*.json')), 'upcoming': tot, 'recap': len(recap)}, open('/tmp/rapi_status.json','w'))
    print('EU_RAPI_DONE: ' + str(tot) + ' upcoming EU stakes races, ' + str(len(recap)) + ' recap races')
    for b in upcoming:
        print('  ' + b['day_label'] + ' (' + str(len(b['races'])) + ')')
        for r in b['races']:
            print('     [' + r['grade'] + '] ' + r['race_name'][:52] + ' @ ' + r['track'] + ' (' + r['country'] + ') ' + r['dist_surface'])
    for r in recap:
        print('  RECAP [' + r['grade'] + '] ' + r['race_name'][:48] + ' @ ' + r['track'] + ' — ' + r['winner'])
else:
    print('EU_RAPI_EMPTY: API returned no EU stakes races — falling back to SDL/Racing Post scraping')
PYRAPI

else
  echo "EU_RAPI: RACING_API_CREDS not set — using SDL + Racing Post scraping"
fi

if [ -f /tmp/rapi_ok ]; then
  echo "EU_PREFETCH_SKIP: Racing API already supplied EU data — skipping scraper (saves ~20s and avoids needless load on the source)"
else
# ──────────────────────────────────────────────────────────────────
# SDL UPCOMING — thestatsdontlie.com is the SOLE source
# ──────────────────────────────────────────────────────────────────
SDL_URL="https://www.thestatsdontlie.com/horse-racing/"
echo "EU_PREFETCH: fetching upcoming from ${SDL_URL}"
fetch_validated "${SDL_URL}" /tmp/sdl.html 50000 EU_PREFETCH_SDL || true
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
# Aug 13 2026: distinguish "page fetched but unparseable" from "page fetched, genuinely no races".
# A large SDL page that yields zero regex matches means the encoding or markup changed -- that is a
# PARSE failure and must never be reported downstream as "no racing scheduled".
if len(matches) == 0 and len(raw) > 200000:
    print('EU_PREFETCH_PARSE_FAIL: SDL page is ' + str(len(raw)) + ' bytes but ZERO races parsed.')
    print('  This is a PARSE/ENCODING failure, NOT an empty race calendar. Do not report "no racing".')
    print('  Check: page markup changed, or the response was compressed and left undecoded.')
elif len(matches) == 0:
    print('EU_PREFETCH_EMPTY: SDL page small (' + str(len(raw)) + ' bytes) and zero races parsed.')

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
fi

if [ -f /tmp/rapi_ok ]; then
  echo "EU_PREFETCH_SKIP: Racing API already supplied EU data — skipping scraper (saves ~20s and avoids needless load on the source)"
else
# ──────────────────────────────────────────────────────────────────
# RACING POST RESULTS — yesterday's results (unchanged)
# ──────────────────────────────────────────────────────────────────
YEST=$(date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null || date -v-1d '+%Y-%m-%d')
RP_URL="https://www.racingpost.com/results/${YEST}"
echo "EU_RECAP_PREFETCH: fetching YESTERDAY=${YEST} from ${RP_URL}"
fetch_validated "${RP_URL}" /tmp/rp_yesterday.html 100000 EU_RECAP_RP || true
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
fi
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
import sys, os, json, re
GO = {'G1':0,'G2':1,'G3':2,'LR':3}
def normname(n):
    s = (n or '').lower().strip()
    # Drop a trailing grade parenthetical BEFORE the suffix strip. The Racing API appends
    # "(Group 1)" / "(Listed)" to race names and the scrapers do not, so the same race
    # arriving from two producers deduped to two different keys and printed twice.
    # Seen Sep 3 2026: "Betfair Sprint Cup Stakes (Group 1)" vs "Betfair Sprint Cup Stakes".
    s = re.sub(r'\s*\((?:group|groupe|gruppo|grade|listed|g)\s*\d?\)\s*$', '', s).strip()
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
    tier0 = _load('/tmp/eu_upcoming_tier0.json') or []
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
    # tier0 FIRST: it is the Racing API via the mirror, the highest-quality producer and the
    # only one with canonical day_labels. A stale tier0 build is already re-bucketed by race
    # date in the Tier 0 block, so absorbing it first is safe even when the Action ran late.
    absorb(tier0, 'tier0'); absorb(bash, 'bash'); absorb(webfetch, 'webfetch'); absorb(cache, 'cache')
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
    tier0 = _load('/tmp/eu_recap_tier0.json') or []
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
    # tier0 recap is only ever written for an age==0 build, so it is genuinely yesterday's.
    absorb(tier0, 'tier0'); absorb(bash, 'bash'); absorb(webfetch, 'webfetch')
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

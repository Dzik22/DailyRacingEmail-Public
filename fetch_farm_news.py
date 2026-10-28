#!/usr/bin/env python3
"""
Build farm_news.json -- news about Mike's Wasabi-held stallions straight from the farms that stand
them -- for the FARM NEWS block inside the digest's SIRE LINES section.

WHY THIS EXISTS
---------------
Mike's suggestion (Oct 27 2026): stallion farms post news whenever a son or daughter of one of
their sires wins a graded stakes, and they also announce fees, sales results and syndications,
all of which move a share's value. Same constraint as the other fetchers: CCR can reach only
raw.githubusercontent.com, so this runs in the eu-stakes GitHub Action and commits its output.

SOURCES (all probed Oct 27 2026 with curl_cffi, 200 unless noted)
------------------------------------------------------------------
- RSS: Gainesway, Claiborne, Taylor Made Stallions, WinStar, Airdrie -- standard WordPress /feed/.
  Lane's End's Drupal /rss.xml is a per-horse feed whose body carries each horse's SIRE.
  An item counts only if it names one of THAT farm's roster sires, so "Annapolis" the city or
  "complexity" the word in another farm's post can never match.
- Stallion pages, diffed day over day (no news feed exists): Hill 'n' Dale's Army Mule page (it
  lists his stakes winners), Mill Ridge's Casa Creed page, Murmur Farm's Blofeld page. The first
  run only records a baseline; after that, new lines that look like stakes/fee/share news become
  items.
- Arzak ("2 Amsterdam"): no website found, so no farm source.

- TDN (added the same day, Mike's request): the /tag/stallion-shares/ feed -- TDN's public archive of
  share sales and online stallion-share auctions -- plus a search feed per sire. Private share deals
  through agents are usually unreported, so no source can promise every trade.
- TDN graded winners (Oct 28 2026): the Racing API carries no USA races at all, so USA graded wins by
  roster sires come from the results chart TDN prints in every stakes write-up:
  "GLEN COVE S.-GIII , $200,000, Belmont, 10-25, ... 1– GROUND SUPPORT, 124, f, 3, by Army Mule 1st Dam".
  Exact, so no headline guessing. A race TDN never writes up is missed (Mike: "oh well").

Every failure is per-source and non-fatal; on a total failure the old farm_news.json stays as is.

OUTPUT
------
farm_news.json  {for_date, built_utc, sources:{farm: "ok N"|"fail ..."}, items:[{date, farm,
                 sires, title, link, graded, kind}], pages:{url: [lines]}, graded_hits:[{date, sire,
                 farm, winner, grade, race_name, course, region, source, link}]}
items and graded_hits are rolling 30-day histories, newest first.
"""
import html, json, re, subprocess, sys
from datetime import date, datetime, timedelta
from email.utils import parsedate_to_datetime

OUT = 'farm_news.json'
KEEP_DAYS = 30
FEEDS = [
    ('Gainesway', 'https://gainesway.com/feed/', ['Charge It']),
    ('Claiborne', 'https://claibornefarm.com/feed/', ['Prince of Monaco', 'Annapolis', 'Mindframe', 'Johannes']),
    ('Taylor Made', 'https://www.taylormadestallions.com/feed/', ['Dr. Schivel', "Arthur's Ride"]),
    ('WinStar', 'https://www.winstarfarm.com/feed/', ['Straight No Chaser', 'Tappan Street']),
    ('Airdrie Stud', 'https://www.airdriestud.com/feed/', ['Complexity']),
    ("Lane's End", 'https://www.lanesend.com/rss.xml', ['Honor A.P.']),
]
PAGES = [
    ("Hill 'n' Dale", 'https://www.hillndalefarms.com/army-mule', ['Army Mule']),
    ('Mill Ridge', 'https://www.millridge.com/casa-creed', ['Casa Creed']),
    ('Murmur Farm', 'https://www.murmurfarm.com/Blofeld.html', ['Blofeld']),
]
# TDN (WordPress): the stallion-shares tag feed is the public share-sale archive (Tattersalls/Arqana/
# AKTEM online sales, private share deals); the per-sire search feed returns every article that names
# the sire. Search terms drop punctuation where TDN's own spelling varies (Honor A. P., Arthur’s Ride).
TDN = 'https://www.thoroughbreddailynews.com'
TDN_SHARES = TDN + '/tag/stallion-shares/feed/'
TDN_TERMS = {'Honor A.P.': 'Honor A. P.', "Arthur's Ride": 'Arthur Ride', 'Dr. Schivel': 'Schivel'}
SHARE_WORDS = r"(?:shares?|half-share|breeding rights?|syndicat\w*|stallion seasons?|interest in)"
GRADED = re.compile(r'\((?:G|Gr\.?\s?|Grade\s)(?:[123]|I{1,3})\)|\bG(?:[123]|I{1,3})\b|\bGrade\s(?:[123]|I{1,3})\b')
NEWSY = re.compile(r'Stakes|\(G|Grade|Fee|share|syndicat|sold|\$', re.I)
# TDN's results chart: RACE NAME-G<grade>, purse, track, M-D, ... 1– WINNER, weight, sex, age, by SIRE 1st Dam
CHART = re.compile(r"([A-Z0-9][A-Z0-9'’.&\- ]{2,80}?)\s*-\s*G(III|II|I|[123])\b\s*,\s*(?:[A-Z]{0,2}\$|€|£)[\d,]+,"
                   r"\s*([^,]{2,40}),\s*(\d{1,2})-(\d{1,2}),.{0,240}?\b1\s*[–-]\s*([^,]{2,40}),\s*\d+,\s*[a-z]+,"
                   r"\s*\d+,\s*by\s+(.{2,40}?)\s+1st Dam", re.S)


def sire_re(name, ci=True):
    # "Honor A.P." matches Honor AP / Honor A. P. / HONOR A.P.; "Arthur's Ride" matches Arthurs Ride.
    # ci=False (TDN, which covers every horse in the country) accepts only Title Case or ALL CAPS, so
    # the plain words "complexity" or "charge it" in an article can never match.
    def pat(ps): return r"[\s.'’]*".join(re.escape(p) for p in ps)
    parts = re.findall(r'[A-Za-z0-9]+', name)
    body = pat(parts) if ci else '(?:' + pat(parts) + '|' + pat([p.upper() for p in parts]) + ')'
    return re.compile(r'(?<![A-Za-z])' + body + r'(?![A-Za-z])', re.I if ci else 0)


def share_near(name, text):
    # A share/breeding-right word within ~80 chars of the sire's name, either side.
    sr = sire_re(name, ci=False).pattern
    return re.search(sr + r'.{0,80}?\b' + SHARE_WORDS + r'\b|\b' + SHARE_WORDS + r'\b.{0,80}?' + sr, text, re.S | re.I) is not None


def tdn_charts(body, pub, roster, norm):
    # Graded winners in a TDN article whose sire is on the roster. pub = the article's ISO date, which
    # supplies the year (a chart dated after the article belongs to the previous year).
    out = []
    for m in CHART.finditer(body):
        hit = roster.get(norm(m.group(7)))
        if not hit:
            continue
        y = int(pub[:4])
        try:
            d = date(y, int(m.group(4)), int(m.group(5)))
            if d.isoformat() > pub:
                d = date(y - 1, d.month, d.day)
        except ValueError:
            continue
        out.append({'date': d.isoformat(), 'sire': hit[0], 'farm': hit[1],
                    'winner': re.sub(r'\s*\([A-Za-z]{2,4}\)\s*$', '', m.group(6)).strip().title(),
                    'grade': 'G' + {'I': '1', 'II': '2', 'III': '3'}.get(m.group(2), m.group(2)),
                    'race_name': re.sub(r'\s+', ' ', m.group(1)).strip().title(),
                    'course': m.group(3).strip(), 'region': '', 'source': 'TDN'})
    return out


def rss_items(xml):
    for it in re.findall(r'<item>(.*?)</item>', xml, re.S):
        title = re.sub(r'\s+', ' ', text_of((re.search(r'<title>(.*?)</title>', it, re.S) or [None, ''])[1])).strip()
        link = text_of((re.search(r'<link>(.*?)</link>', it, re.S) or [None, ''])[1]).strip()
        pub = (re.search(r'<pubDate>(.*?)</pubDate>', it, re.S) or [None, ''])[1].strip()
        try:
            d = parsedate_to_datetime(pub).date().isoformat()
        except Exception:
            continue
        yield d, title, link, re.sub(r'\s+', ' ', text_of(it))


def text_of(s):
    s = html.unescape(html.unescape(s or ''))
    s = re.sub(r'<!\[CDATA\[|\]\]>', ' ', s)
    s = re.sub(r'<script.*?</script>|<style.*?</style>', ' ', s, flags=re.S)
    return re.sub(r'<[^>]+>', '\n', s)


def get(requests, url, timeout=40):
    r = requests.get(url, impersonate='chrome', timeout=timeout)
    if r.status_code != 200:
        raise RuntimeError('HTTP %d' % r.status_code)
    return r.text


def main():
    try:
        from curl_cffi import requests
    except ImportError:
        subprocess.run([sys.executable, '-m', 'pip', 'install', '-q', 'curl_cffi'], timeout=180, check=False)
        from curl_cffi import requests
    t = date.today()
    try:
        prev = json.load(open(OUT))
    except Exception:
        prev = {}
    status, new_items, pages = {}, [], dict(prev.get('pages', {}))

    for farm, url, sires in FEEDS:
        try:
            xml = get(requests, url)
            n = 0
            for it in re.findall(r'<item>(.*?)</item>', xml, re.S):
                title = text_of((re.search(r'<title>(.*?)</title>', it, re.S) or [None, ''])[1]).strip()
                link = text_of((re.search(r'<link>(.*?)</link>', it, re.S) or [None, ''])[1]).strip()
                pub = (re.search(r'<pubDate>(.*?)</pubDate>', it, re.S) or [None, ''])[1].strip()
                try:
                    d = parsedate_to_datetime(pub).date().isoformat()
                except Exception:
                    continue
                body = text_of(it)
                hit = [s for s in sires if sire_re(s).search(body)]
                if not hit:
                    continue
                n += 1
                new_items.append({'date': d, 'farm': farm, 'sires': hit, 'title': re.sub(r'\s+', ' ', title),
                                  'link': link, 'graded': bool(GRADED.search(title)),   # title only: bodies cite old (G1)s
                                  'kind': 'feed'})
            status[farm] = 'ok %d' % n
        except Exception as e:
            status[farm] = 'fail ' + str(e)[:80]

    for farm, url, sires in PAGES:
        try:
            lines = []
            for l in text_of(get(requests, url)).split('\n'):
                l = re.sub(r'\s+', ' ', l).strip()
                if 15 <= len(l) <= 300 and l not in lines:
                    lines.append(l)
            old = pages.get(url)
            fresh = [l for l in lines if old is not None and l not in old and NEWSY.search(l)]
            for l in fresh[:6]:
                new_items.append({'date': t.isoformat(), 'farm': farm, 'sires': sires, 'title': l, 'link': url,
                                  'graded': bool(GRADED.search(l)), 'kind': 'page'})
            pages[url] = lines
            status[farm] = ('baseline %d lines' % len(lines)) if old is None else ('ok %d new' % len(fresh))
        except Exception as e:
            status[farm] = 'fail ' + str(e)[:80]

    # TDN. A share item = the stallion-shares tag feed, or any article with a share word next to the
    # sire's name. A news item = the sire named in the HEADLINE (body-only mentions are too incidental).
    import time
    from fetch_sire_lines import SIRES as _ROSTER, ROSTER as _RNORM, norm as _norm
    tdn_n, tdn_fail, chart_hits = 0, [], []
    # TDN can be slow (Oct 28: three 40 s timeouts, a 4m16s run). fetch_eu_stakes.py kills this script
    # at 420 s and the whole file is then lost, so cap TDN at 20 s a request and 240 s in all. A skipped
    # sire is caught up the next night: each search feed holds its 30 newest articles.
    tdn_t0 = time.time()
    cutoff30 = (t - timedelta(days=KEEP_DAYS)).isoformat()
    for label, url, names in ([('shares tag', TDN_SHARES, [n for n, _ in _ROSTER])]
                              + [(n, TDN + '/?s=%22' + TDN_TERMS.get(n, n).replace(' ', '+') + '%22&feed=rss2', [n])
                                 for n, _ in _ROSTER]):
        if time.time() - tdn_t0 > 240:
            tdn_fail.append(label + ': skipped (TDN time budget)')
            continue
        try:
            xml = get(requests, url, timeout=20)
            for d, title, link, body in rss_items(xml):
                if d < cutoff30:
                    continue
                for h in tdn_charts(body, d, _RNORM, _norm):
                    chart_hits.append(dict(h, link=link))
                for nm in names:
                    if not sire_re(nm, ci=False).search(title + ' ' + body):
                        continue
                    if url == TDN_SHARES or share_near(nm, title + ' ' + body):
                        kind = 'share'
                    elif sire_re(nm, ci=False).search(title):
                        kind = 'news'
                    else:
                        continue
                    new_items.append({'date': d, 'farm': 'TDN', 'sires': [nm], 'title': title, 'link': link,
                                      'graded': bool(GRADED.search(title)), 'kind': kind})
                    tdn_n += 1
        except Exception as e:
            tdn_fail.append(label + ': ' + str(e)[:60])
        time.sleep(1.5)
    status['TDN'] = ('ok %d, %d graded wins' % (tdn_n, len(chart_hits))) + ('; fail ' + ' | '.join(tdn_fail) if tdn_fail else '')
    if len(tdn_fail) > len(_ROSTER):
        status['TDN'] = 'fail ' + ' | '.join(tdn_fail)[:200]

    if all(v.startswith('fail') for v in status.values()):
        print('FARM_FAIL: every source failed; previous %s left untouched: %s' % (OUT, json.dumps(status)))
        return

    cutoff = (t - timedelta(days=KEEP_DAYS)).isoformat()
    seen, items = set(), []
    for it in sorted(new_items + prev.get('items', []), key=lambda x: x.get('date', ''), reverse=True):
        k = (it.get('farm'), it.get('title'), tuple(it.get('sires', [])) if it.get('farm') == 'TDN' else ())
        if it.get('date', '') >= cutoff and k not in seen:
            seen.add(k); items.append(it)
    # Graded winners from TDN charts: one row per winner+race (a day's recap and the race's own story
    # print the same chart).
    seen, ghits = set(), []
    for h in sorted(chart_hits + prev.get('graded_hits', []), key=lambda x: (x.get('date', ''), x.get('grade', '')), reverse=True):
        k = (_norm(h.get('winner')), h.get('race_name', '').lower(), h.get('date'))
        if h.get('date', '') >= cutoff and k not in seen:
            seen.add(k); ghits.append(h)
    try:
        from fetch_sire_lines import SIRES   # one roster, so the section renders even if the API build fails
    except Exception:
        SIRES = []
    json.dump({'for_date': t.isoformat(), 'built_utc': datetime.utcnow().isoformat() + 'Z', 'sources': status,
               'sires': [{'name': n, 'farm': f} for n, f in SIRES],
               'items': items, 'pages': pages, 'graded_hits': ghits}, open(OUT, 'w'), ensure_ascii=False, indent=1)
    print('FARM_OK items=%d graded_hits=%d %s' % (len(items), len(ghits), json.dumps(status)))
    for h in ghits[:8]:
        print('  [%s] %s by %s -- %s @ %s %s' % (h['grade'], h['winner'], h['sire'], h['race_name'], h['course'], h['date']))
    for it in items[:12]:
        print('  %s [%s] %s%s: %s' % (it['date'], it['farm'], '/'.join(it['sires']), ' G' if it['graded'] else '',
                                     it['title'][:90]))


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print('FARM_FAIL: ' + str(e))
    sys.exit(0)

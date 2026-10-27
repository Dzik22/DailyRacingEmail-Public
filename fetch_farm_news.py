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

Every failure is per-source and non-fatal; on a total failure the old farm_news.json stays as is.

OUTPUT
------
farm_news.json  {for_date, built_utc, sources:{farm: "ok N"|"fail ..."}, items:[{date, farm,
                 sires, title, link, graded, kind}], pages:{url: [lines]}}
items is a rolling 30-day history, newest first.
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
GRADED = re.compile(r'\((?:G|Gr\.?\s?|Grade\s)(?:[123]|I{1,3})\)|\bG(?:[123]|I{1,3})\b|\bGrade\s(?:[123]|I{1,3})\b')
NEWSY = re.compile(r'Stakes|\(G|Grade|Fee|share|syndicat|sold|\$', re.I)


def sire_re(name):
    # "Honor A.P." matches Honor AP / Honor A. P. / HONOR A.P.; "Arthur's Ride" matches Arthurs Ride.
    parts = [re.escape(p) for p in re.findall(r'[A-Za-z0-9]+', name)]
    return re.compile(r'(?<![A-Za-z])' + r"[\s.'’]*".join(parts) + r'(?![A-Za-z])', re.I)


def text_of(s):
    s = html.unescape(html.unescape(s or ''))
    s = re.sub(r'<!\[CDATA\[|\]\]>', ' ', s)
    s = re.sub(r'<script.*?</script>|<style.*?</style>', ' ', s, flags=re.S)
    return re.sub(r'<[^>]+>', '\n', s)


def get(requests, url):
    r = requests.get(url, impersonate='chrome', timeout=40)
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

    if all(v.startswith('fail') for v in status.values()):
        print('FARM_FAIL: every source failed; previous %s left untouched: %s' % (OUT, json.dumps(status)))
        return

    cutoff = (t - timedelta(days=KEEP_DAYS)).isoformat()
    seen, items = set(), []
    for it in sorted(new_items + prev.get('items', []), key=lambda x: x.get('date', ''), reverse=True):
        k = (it.get('farm'), it.get('title'))
        if it.get('date', '') >= cutoff and k not in seen:
            seen.add(k); items.append(it)
    try:
        from fetch_sire_lines import SIRES   # one roster, so the section renders even if the API build fails
    except Exception:
        SIRES = []
    json.dump({'for_date': t.isoformat(), 'built_utc': datetime.utcnow().isoformat() + 'Z', 'sources': status,
               'sires': [{'name': n, 'farm': f} for n, f in SIRES],
               'items': items, 'pages': pages}, open(OUT, 'w'), ensure_ascii=False, indent=1)
    print('FARM_OK items=%d %s' % (len(items), json.dumps(status)))
    for it in items[:12]:
        print('  %s [%s] %s%s: %s' % (it['date'], it['farm'], '/'.join(it['sires']), ' G' if it['graded'] else '',
                                     it['title'][:90]))


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print('FARM_FAIL: ' + str(e))
    sys.exit(0)

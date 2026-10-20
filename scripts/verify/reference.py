# Independent implementation of the app's counting rules, with full JSON parsing. Usage: reference.py <projects dir>
import json, os, sys, math, datetime, collections
root = sys.argv[1]
MSG = ('user', 'assistant', 'attachment', 'system')
mains, subs = [], []
for proj in os.listdir(root):
    pd = os.path.join(root, proj)
    if not os.path.isdir(pd): continue
    for e in os.listdir(pd):
        if e.endswith('.jsonl'): mains.append(f'{proj}/{e}')
        sd = os.path.join(pd, e, 'subagents')
        if os.path.isdir(sd): subs += [f'{proj}/{e}/subagents/{a}' for a in os.listdir(sd) if a.startswith('agent-') and a.endswith('.jsonl')]
order = sorted(mains + subs)
def ts(s):
    try: return datetime.datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp()
    except Exception: return None
files = {}
for rel in order:
    sub = rel in subs
    start = None; keys = {}; usage = {}
    offset = 0
    with open(os.path.join(root, rel), 'rb') as fh:
        for raw in fh:
            here = offset; offset += len(raw)
            try: d = json.loads(raw)
            except Exception: continue
            if not isinstance(d, dict) or d.get('type') not in MSG or not isinstance(d.get('timestamp'), str): continue
            t = ts(d['timestamp'])
            if t is None: continue
            main_thread = not sub and d.get('isSidechain') is not True
            if main_thread and start is None: start = t
            bucket = math.floor(t / 900)
            if d['type'] == 'user' and main_thread:
                k = ('u', d['uuid']) if d.get('uuid') else ('line', rel, here)
                keys.setdefault(k, bucket)
            elif d['type'] == 'assistant':
                m = d.get('message') if isinstance(d.get('message'), dict) else {}
                k = ('m', m['id']) if m.get('id') else ('line', rel, here)
                u = m.get('usage') or {}
                tok = [u.get('input_tokens') or 0, u.get('output_tokens') or 0, u.get('cache_read_input_tokens') or 0, u.get('cache_creation_input_tokens') or 0]
                if k not in usage or sum(tok) >= sum(usage[k][2]): usage[k] = (bucket, m.get('model') or 'unknown', tok)
                if main_thread and m.get('model') != '<synthetic>': keys.setdefault(k, bucket)
    files[rel] = dict(sub=sub, start=start, keys=keys, usage=usage)
# tokens: one per response, largest usage wins; on a tie the transcript listed first keeps it
resp = {}
for rel in order:
    for k, v in files[rel]['usage'].items():
        if k in resp and sum(resp[k][2]) >= sum(v[2]): continue
        resp[k] = v
main_order = [r for r in order if not files[r]['sub']]
holders = collections.Counter(k for r in main_order for k in files[r]['keys'])
msg_bucket = {}
for r in main_order:
    for k, b in files[r]['keys'].items(): msg_bucket.setdefault(k, b)
sessions = []
for i, r in enumerate(main_order):
    f = files[r]
    if f['start'] is None: continue
    K = set(f['keys'])
    copy = False
    if K and all(holders[k] > 1 for k in K):
        for j, r2 in enumerate(main_order):
            if j == i: continue
            K2 = files[r2]['keys']
            if (len(K2) > len(K) or (len(K2) == len(K) and j < i)) and K <= K2.keys(): copy = True; break
    if not copy: sessions.append(f['start'])
local_day = lambda t: datetime.datetime.fromtimestamp(t).date()
days = collections.defaultdict(dict)
for s in sessions: d = str(local_day(s)); days[d]['sessions'] = days[d].get('sessions', 0) + 1
for b in msg_bucket.values(): d = str(local_day(b * 900)); days[d]['messages'] = days[d].get('messages', 0) + 1
for b, model, tok in resp.values():
    if model == '<synthetic>' or sum(tok) == 0: continue
    d = str(local_day(b * 900)); t = days[d].setdefault('tokens', {}).setdefault(model, [0, 0, 0, 0])
    for i in range(4): t[i] += tok[i]
hours = [0] * 24
for s in sessions: hours[datetime.datetime.fromtimestamp(s).hour] += 1
today = datetime.date.today(); ranges = {}
for name, n in (('All', None), ('30d', 30), ('7d', 7)):
    first = today - datetime.timedelta(days=n - 1) if n else datetime.date.min
    inr = lambda dd: first <= dd <= today
    ss = [s for s in sessions if inr(local_day(s))]
    h = collections.Counter(datetime.datetime.fromtimestamp(s).hour for s in ss)
    msgs = [b for b in msg_bucket.values() if inr(local_day(b * 900))]
    active = {local_day(b * 900) for b in msgs} | {local_day(s) for s in ss}
    per = collections.Counter(); total = 0
    for b, model, tok in resp.values():
        if model == '<synthetic>' or sum(tok) == 0 or not inr(local_day(b * 900)): continue
        per[model] += sum(tok); total += sum(tok); active.add(local_day(b * 900))
    peak = min((x for x in h if h[x] == max(h.values())), default=None)
    fav = min((m for m in per if per[m] == max(per.values())), default=None)
    ranges[name] = dict(sessions=len(ss), messages=len(msgs), totalTokens=total, activeDays=len(active), peakHour=peak, favoriteModel=fav)
print(json.dumps(dict(days=days, hours=hours, ranges=ranges), sort_keys=True, indent=2))

# Diffs two --dump --json reports day by day and model by model. Usage: compare.py <a.json> <b.json>
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
problems = 0
for day in sorted(set(a['days']) | set(b['days'])):
    x, y = a['days'].get(day, {}), b['days'].get(day, {})
    for f in ('sessions', 'messages'):
        if x.get(f, 0) != y.get(f, 0): problems += 1; print(f'{day} {f}: app {x.get(f, 0)} vs reference {y.get(f, 0)}')
    for m in sorted(set(x.get('tokens', {})) | set(y.get('tokens', {}))):
        tx, ty = x.get('tokens', {}).get(m, [0]*4), y.get('tokens', {}).get(m, [0]*4)
        if tx != ty: problems += 1; print(f'{day} {m}: app {tx} vs reference {ty}')
if a['hours'] != b['hours']: problems += 1; print('hours differ', a['hours'], b['hours'])
for r in a['ranges']:
    if a['ranges'][r] != b['ranges'][r]: problems += 1; print(r, 'app', a['ranges'][r], 'reference', b['ranges'][r])
cells = sum(len(v.get('tokens', {})) * 4 + 2 for v in a['days'].values())
print(f'compared {len(a["days"])} days, {cells} day/model/field values, 24 hours, 3 ranges: {"IDENTICAL" if problems == 0 else f"{problems} DIFFERENCES"}')
print(json.dumps(a['ranges'], indent=1))
# The panel's own per-day numbers (StatsBuilder) must agree with the raw per-day data.
bad = 0
for day, s in a.get('statsDays', {}).items():
    raw = a['days'].get(day, {})
    tok = sum(sum(v) for v in raw.get('tokens', {}).values())
    if (s['sessions'], s['messages'], s['tokens']) != (raw.get('sessions', 0), raw.get('messages', 0), tok): bad += 1; print('panel/raw mismatch', day, s, raw)
print('panel per-day totals vs raw data:', 'CONSISTENT' if bad == 0 else f'{bad} mismatches')
sys.exit(1 if problems or bad else 0)

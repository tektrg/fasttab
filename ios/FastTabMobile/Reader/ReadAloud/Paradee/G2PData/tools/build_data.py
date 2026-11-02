"""Convert misaki's us/gb gold+silver JSON into Paradee's compact, sorted TSV lexicons.

Line format (UTF-8): key \t value \n, sorted by the UTF-8 bytes of key (binary-searched on device).
value is either a phoneme string, or a POS-keyed entry: {TAG=ps|TAG=ps|...}, where an empty ps means
misaki's None ("no reading for this tag, spell it").
Silver keys that misaki would never consult (gold has them, counting gold's case-grown variants) are dropped.
Usage: build_data.py <misaki data dir> <out dir>
"""
import json, os, sys

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)


def grow(d):
    e = {}
    for k, v in d.items():
        if len(k) < 2:
            continue
        if k == k.lower():
            if k != k.capitalize():
                e[k.capitalize()] = v
        elif k == k.lower().capitalize():
            e[k.lower()] = v
    return {**e, **d}


def enc(v):
    if isinstance(v, str):
        assert v and not any(c in v for c in '\t\n{}|='), v
        return v
    parts = []
    for tag, ps in v.items():
        assert ps is None or (ps and not any(c in ps for c in '\t\n{}|=')), (tag, ps)
        parts.append(f'{tag}={ps or ""}')
    return '{' + '|'.join(parts) + '}'


def write(name, d):
    keys = sorted(d, key=lambda k: k.encode('utf-8'))
    with open(os.path.join(out, name), 'w', encoding='utf-8', newline='\n') as f:
        for k in keys:
            assert '\t' not in k and '\n' not in k
            f.write(f'{k}\t{enc(d[k])}\n')
    return len(keys)


for accent in ('us', 'gb'):
    gold = json.load(open(os.path.join(src, f'{accent}_gold.json'), encoding='utf-8'))
    silver = json.load(open(os.path.join(src, f'{accent}_silver.json'), encoding='utf-8'))
    grown_gold = grow(gold)
    kept = {k: v for k, v in silver.items() if k not in grown_gold}
    assert all(isinstance(v, str) for v in kept.values())
    n1 = write(f'paradee-{accent}-gold.tsv', gold)
    n2 = write(f'paradee-{accent}-silver.tsv', kept)
    print(accent, 'gold', n1, 'silver', n2, 'of', len(silver))

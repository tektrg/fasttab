"""Generate misaki goldens exactly as Paradee/Kokoro configure it:
en.G2P(trf=False, british=..., fallback=EspeakFallback(british), unk='').
Usage: gen_golden.py <sentences.txt|wikitext.json> <out.json> [--debug] [--limit N] [--seed S]
"""
import json, sys, random
from misaki import en, espeak

src, out = sys.argv[1], sys.argv[2]
debug = '--debug' in sys.argv
limit = int(sys.argv[sys.argv.index('--limit') + 1]) if '--limit' in sys.argv else None
seed = int(sys.argv[sys.argv.index('--seed') + 1]) if '--seed' in sys.argv else 0

if src.endswith('.json'):
    sents = json.load(open(src))
    random.Random(seed).shuffle(sents)
else:
    sents = [l.strip() for l in open(src, encoding='utf-8') if l.strip()]
if limit:
    sents = sents[:limit]

g2ps = {
    'us': en.G2P(trf=False, british=False, fallback=espeak.EspeakFallback(british=False), unk=''),
    'gb': en.G2P(trf=False, british=True, fallback=espeak.EspeakFallback(british=True), unk=''),
}
nlp = g2ps['us'].nlp
rows = []
for s in sents:
    row = {'text': s}
    for k, g in g2ps.items():
        ps, toks = g(s)
        row[k] = ps
        oov = sorted({t.text for t in toks if getattr(t, 'rating', None) == 2 or t._.rating == 2})
        if oov:
            row[k + '_fallback'] = oov
    if debug:
        row['spacy'] = [[t.text, t.tag_, t.whitespace_] for t in nlp(s)]
    rows.append(row)

with open(out, 'w', encoding='utf-8') as f:
    if debug:
        json.dump(rows, f, ensure_ascii=False, indent=0)
    else:
        json.dump({'source': 'misaki 0.9.4, en.G2P(trf=False, fallback=EspeakFallback, unk="") as used by Paradee/Kokoro',
                   'sentences': rows}, f, ensure_ascii=False, indent=1)
print(len(rows), 'rows ->', out)

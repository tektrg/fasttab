"""Learn letter-to-sound rules from misaki's own dictionaries (Apache 2.0), for words misaki can't find.

1. Align every dictionary word letter-by-letter with its phonemes (hard EM: each letter -> 0..2 phoneme
   symbols; a stress mark travels with the vowel after it, GB length marks with the vowel before).
2. For every letter, count which chunk it produced in each context (k letters left, m right, k,m <= 3).
3. Keep a context only if it is frequent enough and predicts something different from its
   less specific parent contexts (so the table stays small); ship as a sorted TSV:
   key = left + "(" + letter + ")" + right   ('#' marks the word edge), value = chunk ('_' = silent).
Usage: train_lts.py <misaki data dir> <out.tsv> us|gb [--eval] [--order=two|size] [--min=3] [--nosec]
  --eval holds out 2% of words and prints accuracy; ship a table trained without it.
  Shipped tables: --order=two --min=3 (the defaults). Alignment is cached next to <out.tsv>.
"""
import json, math, random, sys, collections, os

data_dir, out_path, accent = sys.argv[1], sys.argv[2], sys.argv[3]
EVAL = '--eval' in sys.argv
MAXK = 3
ORDER = next((a.split('=')[1] for a in sys.argv if a.startswith('--order=')), 'two')
MINCOUNT = int(next((a.split('=')[1] for a in sys.argv if a.startswith('--min=')), '3'))
NOSEC = '--nosec' in sys.argv
if ORDER == 'size':
    SHAPES = sorted([(k, m) for k in range(MAXK + 1) for m in range(MAXK + 1)], key=lambda s: (-(s[0] + s[1]), -s[1]))
else:   # contexts that see both neighbours first, then one-sided ones
    SHAPES = sorted([(k, m) for k in range(MAXK + 1) for m in range(MAXK + 1)], key=lambda s: (-(min(s[0], 1) + min(s[1], 1)), -(s[0] + s[1]), abs(s[0] - s[1]), -s[1]))
STRESS = 'ˈˌ'

def load(name):
    return json.load(open(os.path.join(data_dir, f'{accent}_{name}.json'), encoding='utf-8'))

data = {}
for src in (load('silver'), load('gold')):   # gold overrides silver
    for k, v in src.items():
        if isinstance(v, dict):
            v = v.get('DEFAULT')
        if not isinstance(v, str) or not k.isalpha() or not k.isascii() or len(k) < 2 or len(k) > 18:
            continue
        lk = k.lower()
        if k != lk and lk in data and data[lk][1]:
            continue   # a lowercase key already gave this word
        data[lk] = (v, k == lk)
words = sorted((w, v) for w, (v, _) in data.items())

def symbols(ps):
    out, pending = [], ''
    for c in ps:
        if c in STRESS:
            pending += c
        elif c == 'ː' and out:
            out[-1] += c
        else:
            out.append(pending + c)
            pending = ''
    return out

pairs = []
for w, ps in words:
    syms = symbols(ps)
    if 0 < len(syms) <= 2 * len(w):
        pairs.append((w, syms))
random.Random(1).shuffle(pairs)
n_eval = len(pairs) // 50 if EVAL else 0
evalset, train = pairs[:n_eval], pairs[n_eval:]
print(accent, 'train', len(train), 'eval', len(evalset), file=sys.stderr)

# --- hard-EM alignment ---
def strip(sym):
    return sym.lstrip(STRESS)

co = collections.defaultdict(collections.Counter)
for w, syms in train[:60000]:
    for c in w:
        for s in syms:
            co[c][strip(s)] += 1
logp = {}
for c, cnt in co.items():
    tot = sum(cnt.values())
    for s, n in cnt.items():
        logp[(c, s)] = math.log(n / tot)
logp_len = {0: math.log(0.25), 1: math.log(0.65), 2: math.log(0.10)}

def chunk_score(c, chunk, model):
    if model is None:
        if not chunk:
            return logp_len[0]
        return logp_len[len(chunk)] + sum(logp.get((c, strip(s)), -12.0) for s in chunk)
    return model.get((c, chunk), -14.0 - 2 * len(chunk))

def align(w, syms, model):
    n, m = len(w), len(syms)
    NEG = -1e18
    dp = [[NEG] * (m + 1) for _ in range(n + 1)]
    bp = [[0] * (m + 1) for _ in range(n + 1)]
    dp[0][0] = 0.0
    for i in range(1, n + 1):
        c = w[i - 1]
        row, prev = dp[i], dp[i - 1]
        for j in range(0, m + 1):
            best, arg = NEG, 0
            for L in (0, 1, 2):
                if j - L < 0 or prev[j - L] == NEG:
                    continue
                key = tuple(strip(s) for s in syms[j - L:j]) if model is None else ''.join(strip(s) for s in syms[j - L:j])
                sc = prev[j - L] + (chunk_score(c, key, None) if model is None else chunk_score(c, key, model))
                if sc > best:
                    best, arg = sc, L
            row[j], bp[i][j] = best, arg
    if dp[n][m] == NEG:
        return None
    chunks, j = [], m
    for i in range(n, 0, -1):
        L = bp[i][j]
        chunks.append(syms[j - L:j])
        j -= L
    return chunks[::-1]

model = None
CACHE = os.path.join(os.path.dirname(os.path.abspath(out_path)), f'align-{accent}-{int(EVAL)}.pkl')
for it in range(0 if os.path.exists(CACHE) else 4):
    counts = collections.defaultdict(collections.Counter)
    for w, syms in train[:60000]:
        a = align(w, syms, model)
        if a is None:
            continue
        for c, ch in zip(w, a):
            counts[c][''.join(strip(s) for s in ch)] += 1
    model = {}
    for c, cnt in counts.items():
        tot = sum(cnt.values()) + 0.5 * len(cnt)
        for ch, k in cnt.items():
            model[(c, ch)] = math.log((k + 0.5) / tot)
    print('iteration', it, 'chunks', len(model), file=sys.stderr)

# --- context counts ---
import pickle
if os.path.exists(CACHE):
    alignments = pickle.load(open(CACHE, 'rb'))
else:
    alignments = [(w, align(w, syms, model)) for w, syms in train]
    pickle.dump(alignments, open(CACHE, 'wb'))
table = collections.defaultdict(collections.Counter)
aligned = 0
for w, a in alignments:
    if a is None:
        continue
    aligned += 1
    padded = '#' * MAXK + w + '#' * MAXK
    for i, ch in enumerate(a):
        out = ''.join(ch) or '_'
        p = i + MAXK
        for k, m in SHAPES:
            table[padded[p - k:p] + '(' + padded[p] + ')' + padded[p + 1:p + 1 + m]][out] += 1
print('aligned', aligned, 'contexts', len(table), file=sys.stderr)

def parents(key):
    l, rest = key.split('(', 1)
    c, r = rest.split(')', 1)
    ps = []
    if l:
        ps.append(l[1:] + '(' + c + ')' + r)
    if r:
        ps.append(l + '(' + c + ')' + r[:-1])
    return ps

best = {k: cnt.most_common(1)[0] for k, cnt in table.items()}
kept = {}
for key, (out, n) in best.items():
    tot = sum(table[key].values())
    ps = parents(key)
    if not ps:
        kept[key] = out          # bare letter: always kept
        continue
    if tot < MINCOUNT:
        continue
    if all(best[p][0] == out for p in ps):
        continue                 # parents already say the same
    kept[key] = out
print('kept', len(kept), file=sys.stderr)

def predict(w, rules):
    padded = '#' * MAXK + w + '#' * MAXK
    out = []
    for i in range(len(w)):
        p = i + MAXK
        for k, m in SHAPES:
            key = padded[p - k:p] + '(' + padded[p] + ')' + padded[p + 1:p + 1 + m]
            if key in rules:
                if rules[key] != '_':
                    out.append(rules[key])
                break
    ps = ''.join(out)
    return fix_stress(ps)

def fix_stress(ps):
    if NOSEC:
        ps = ps.replace('ˌ', '')
    vowels = set('AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ')
    first = ps.find('ˈ')
    if first >= 0:
        ps = ps[:first + 1] + ps[first + 1:].replace('ˈ', 'ˌ')
    elif any(c in vowels for c in ps):
        j = ps.find('ˌ')
        if j >= 0:
            ps = ps[:j] + 'ˈ' + ps[j + 1:]
        else:
            j = next(i for i, c in enumerate(ps) if c in vowels)
            ps = ps[:j] + 'ˈ' + ps[j:]
    return ps

if EVAL:
    ok = okns = 0
    per = 0
    for w, syms in evalset:
        ref = ''.join(syms)
        hyp = predict(w, kept)
        ok += hyp == ref
        okns += hyp.replace('ˈ', '').replace('ˌ', '') == ref.replace('ˈ', '').replace('ˌ', '')
    names = [(w, syms) for w, syms in evalset if not data[w][1]]
    okn = sum(predict(w, kept) == ''.join(syms) for w, syms in names)
    okn2 = sum(predict(w, kept).replace('ˌ','').replace('ˈ','') == ''.join(syms).replace('ˌ','').replace('ˈ','') for w, syms in names)
    print(f'names {len(names)} exact {okn / max(len(names),1):.3f} no-stress {okn2 / max(len(names),1):.3f}', file=sys.stderr)
    print(f'held-out words exact {ok / len(evalset):.3f}  ignoring stress {okns / len(evalset):.3f}', file=sys.stderr)
    for w, syms in evalset[:15]:
        print(' ', w, ''.join(syms), predict(w, kept), file=sys.stderr)

with open(out_path, 'w', encoding='utf-8', newline='\n') as f:
    for key in sorted(kept, key=lambda k: k.encode('utf-8')):
        f.write(f'{key}\t{kept[key]}\n')

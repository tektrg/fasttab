# Paradee G2P data — how it is made

`ParadeeG2P` (`../../G2P/`) is a Swift port of misaki's English G2P (misaki 0.9.4, commit `fba1236`,
Apache 2.0 — notice in `../misaki-LICENSE.txt`). These scripts rebuild everything it loads.
Not app code: exclude this folder from the app target.

| File in `G2PData/` | What | Built by |
| --- | --- | --- |
| `paradee-{us,gb}-gold.lzfse`, `-silver.lzfse` | misaki's dictionaries as sorted `key\tvalue` lines (binary-searched in place) | `build_data.py` |
| `paradee-{us,gb}-lts.lzfse` | letter-to-sound rules for words no dictionary has, learned from the same dictionaries | `train_lts.py` |

## Rebuild

```bash
python3 -m venv /tmp/g2p/venv && /tmp/g2p/venv/bin/pip install misaki num2words spacy phonemizer-fork espeakng-loader
git clone https://github.com/hexgrad/misaki /tmp/g2p/misaki          # data: /tmp/g2p/misaki/misaki/data
python3 build_data.py /tmp/g2p/misaki/misaki/data /tmp/g2p/out
python3 train_lts.py /tmp/g2p/misaki/misaki/data /tmp/g2p/out/paradee-us-lts.tsv us   # ~3 min each
python3 train_lts.py /tmp/g2p/misaki/misaki/data /tmp/g2p/out/paradee-gb-lts.tsv gb
for f in /tmp/g2p/out/*.tsv; do compression_tool -encode -a lzfse -i "$f" -o "${f%.tsv}.lzfse"; done
```

The app decompresses with `NSData.decompressed(using: .lzfse)`; `compression_tool` writes the same format.

## Test fixture

`FastTabMobileTests/Fixtures/ParadeeG2PGolden.json` = Python misaki on `golden_sentences.txt`, configured
exactly as Kokoro/Paradee run it (`en.G2P(trf=False, british=..., fallback=EspeakFallback(...), unk="")`).
espeak-ng and spaCy are only needed here, to make the reference — the app ships neither.

```bash
python3 gen_golden.py golden_sentences.txt ParadeeG2PGolden.json   # then reformat one row per line if you like
```

## Measured (macOS, Nov 2026)

| Set | Exact sentence, rows misaki read without espeak | Words (all rows) |
| --- | --- | --- |
| fixture, 313 sentences (US / GB) | 100% / 100% | 99.3% / 99.3% |
| 800 unseen WikiText sentences (US / GB) | 93.6% / 93.9% | 96.3% / 96.3% |

Rows with a word misaki sent to espeak can't match (we have no espeak); for those words the
letter-to-sound rules agree with espeak on ~23% (US) / ~28% (GB) of words exactly.

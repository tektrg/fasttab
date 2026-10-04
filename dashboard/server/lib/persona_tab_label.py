#!/usr/bin/env python3
"""The herdr tab label of a persona start: `<persona> · <first words>`.

Several tabs of one persona (e.g. three `portfolio` workers) were
indistinguishable in herdr; a few words of the first message tell them
apart: `portfolio · fix the login bug`.

Nothing identifies a persona by its tab label (personas map to rows by
folder — `personas.resolve_persona_for_cwd`), so the suffix is display
only. Exact-label checks elsewhere (`CHIEF_TAB_LABEL`, `DEV_SERVER_LABELS`)
are for tabs no persona start makes.

SAFETY: the label reaches herdr as one argv element locally and through
`shlex.quote` over ssh (`build_remote_command`). On top of that the suffix
keeps only letters, digits, space and `- _ .` — no shell metacharacter, quote,
control character or emoji survives, whatever the message holds.
"""
import re
import unicodedata

#: Between the persona name and the message words.
LABEL_SEPARATOR = " · "

#: First N words of the message, at most this many characters (cut on a
#: word boundary; a single longer word is hard-cut).
SUFFIX_MAX_WORDS = 4
SUFFIX_MAX_CHARS = 28

#: Quotes join their word ("don't" -> "dont") instead of splitting it.
_DROPPED_QUOTES = "'\"`‘’“”"
_WORD_PUNCTUATION = "-_."


def _keep_char(ch):
    return ch.isalnum() or ch in _WORD_PUNCTUATION


def message_suffix(message):
    """A few lowercase words from the start of `message`, safe charset only;
    "" when nothing usable is left."""
    text = unicodedata.normalize("NFC", message or "").lower()
    text = "".join(ch for ch in text if ch not in _DROPPED_QUOTES)
    text = "".join(ch if _keep_char(ch) else " " for ch in text)
    words = [w.strip(_WORD_PUNCTUATION) for w in text.split()]
    words = [w for w in words if w][:SUFFIX_MAX_WORDS]
    suffix = ""
    for word in words:
        candidate = f"{suffix} {word}" if suffix else word
        if len(candidate) > SUFFIX_MAX_CHARS:
            break
        suffix = candidate
    if not suffix and words:
        suffix = words[0][:SUFFIX_MAX_CHARS]
    return suffix


def persona_tab_label(persona_name, message):
    """`<persona> · <suffix>`, or just the persona name when the message
    yields no suffix."""
    suffix = message_suffix(message)
    return f"{persona_name}{LABEL_SEPARATOR}{suffix}" if suffix else persona_name

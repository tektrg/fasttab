#!/usr/bin/env bash
# Publishes an opening AskUserQuestion picker to the chief dashboard in
# seconds, so the PO sees a worker's question without waiting for the next
# screen-reading sweep.
#
# WHY THIS EXISTS
# ---------------
# Nothing pushes a question today: the only detector is the paneScreen sweep
# (15s window after phase 5A, 45s before), which screen-scrapes every pane.
# PreToolUse matching AskUserQuestion runs BEFORE the picker is shown, and its
# stdin payload carries the question + options as structured JSON — so this
# takes the alert from ~15s to <=4s (hook write -> 2s hookCache poll -> 2s SSE).
#
# THE HARD CONSTRAINT THIS IS SHAPED AROUND
# ------------------------------------------
# answer_pane_question() (scripts/chief-dashboard-server.py) re-reads the pane
# fresh at send time and REFUSES unless the client's title+question match the
# freshly parsed screen block exactly. The hook's strings come from raw tool
# input; the screen's from a parsed, wrapped, glyph-cleaned terminal box —
# they will NOT match. So this hook's copy is DISPLAY-ONLY (row
# "questionPreview"): rendered as text with NO Confirm button. The sweep's
# screen-parsed copy stays the only answerable one. Do NOT try to make the
# hook copy answerable; do NOT normalise one to match the other.
#
# STORAGE — mirrors the state hook's sidecar convention:
# $TMPDIR/delivery-ops-herdr/<sanitized-pane>.question.json, holding
#   {"ts": 1757000000, "title": "...", "question": "...",
#    "multi": false, "options": [{"index": 1, "label": "...",
#    "description": "..."}]}
# poll_hook_cache skips that suffix (else every question becomes a phantom
# pane row). PostToolUse on the same matcher DELETES the file — that is what
# makes an answered question disappear immediately. SessionEnd deletes both
# sidecars. A SIGKILLed session leaves the file behind; the sweep retires the
# preview within one interval (screen is the authority). No time-based expiry
# on top — a second independent expiry is how the two quietly disagree.
#
# HOOK SAFETY (learned from herdr-agent-state.sh — read its header first)
# ------------------------------------------------------------------------
# Fail open, always: no pane id, malformed payload, any error -> exit 0
# silently. A PreToolUse hook must never block or delay the question reaching
# the human. Bounded stdin drain with a WALL-CLOCK ceiling ($SECONDS, ~2s —
# a 60x50ms tick-count loop measured past 30s at load average 57 because each
# tick forks sleep). Poll for a COMPLETE JSON object (last char `}`): a fixed
# 1s fuse once read a 1.1s payload as empty and reported nothing, silently.
# Opt out with CHIEF_QUESTION_HOOK=off. Only the FIRST question of a
# multi-question turn is recorded (it is the one showing); PostToolUse clears
# the whole file when the turn's questions are answered.
#
# Usage: chief-question-hook.sh ask|clear|release
set -uo pipefail

MODE="${1:-}"
CACHE_DIR="${TMPDIR:-/tmp}/delivery-ops-herdr"
QUESTION_SUFFIX=".question.json"

# Drain stdin bounded so the caller never blocks on a full pipe (a
# PostToolUse body carries the whole tool response and can exceed it).
# Sets PAYLOAD (up to 8KB) or empty. Always exit-0-safe.
PAYLOAD=""
_drain_payload() {
  local ceiling="${1:-2}"
  local _payload_file _drain _ticks _started _seen
  _payload_file="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/chief-question-hook.$$")"
  cat > "$_payload_file" < /dev/stdin 2>/dev/null &
  _drain=$!
  _ticks=0
  _seen=""
  _started=$SECONDS
  while [ "$_ticks" -lt 40 ] && [ $((SECONDS - _started)) -lt "$ceiling" ]; do
    _seen="$(<"$_payload_file")"
    case "$_seen" in
      *'}') break ;;
    esac
    sleep 0.05
    _ticks=$((_ticks + 1))
  done
  PAYLOAD="$(head -c 8192 "$_payload_file" 2>/dev/null || true)"
  rm -f "$_payload_file" 2>/dev/null || true
  disown "$_drain" 2>/dev/null || true
  kill -9 "$_drain" 2>/dev/null || true
}

case "$MODE" in
  ask) _drain_payload 2 ;;
  clear|release) _drain_payload 1 ;;  # content irrelevant; just don't wedge the pipe
  *) exit 0 ;;
esac

[ "${CHIEF_QUESTION_HOOK:-on}" != "off" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
PANE_KEY="$(printf '%s' "$HERDR_PANE_ID" | tr -c 'A-Za-z0-9' '-')"
[ -n "$PANE_KEY" ] || exit 0
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0
QFILE="$CACHE_DIR/$PANE_KEY$QUESTION_SUFFIX"

if [ "$MODE" = "release" ]; then
  # SessionEnd: drop both sidecars (the state hook's own release already
  # drops .why; deleting both here is idempotent and covers a hook that
  # never saw its SessionStart).
  rm -f "$QFILE" "$CACHE_DIR/$PANE_KEY.why" 2>/dev/null || true
  exit 0
fi

if [ "$MODE" = "clear" ]; then
  rm -f "$QFILE" 2>/dev/null || true
  exit 0
fi

# --- ask: extract first question + its options, grep over raw JSON ----------
# No jq in a hook that must never fail; display-only copy, truncation beats
# absence. Values are sanitized before writing (no backslashes/quotes survive
# to break the sidecar JSON).
_flat="$(printf '%s' "$PAYLOAD" | tr '\n' ' ')"
_pick() {  # $1 = key; prints first match value or empty
  printf '%s' "$_flat" \
    | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 \
    | sed 's/^[^:]*:[[:space:]]*"//; s/"$//'
}
_clean() {  # strip backslashes + quotes + control chars, collapse space, cap
  printf '%s' "$1" | tr -d '\\"' | tr -d '\000-\037' | tr -s ' ' | head -c 500
}
QUESTION="$(_clean "$(_pick question)")"
[ -n "$QUESTION" ] || exit 0  # nothing extractable -> report nothing, not a blank row
TITLE="$(_clean "$(_pick header)")"
MULTI=false
case "$_flat" in
  *'"multiSelect"'*true*) MULTI=true ;;
esac
# Option label+description pairs, in payload order, capped (a picker never
# shows more). Extracted per {...} option object — label and description come
# from the SAME braces, so no positional zip can misalign them (an earlier
# revision zipped two grep lists over a \001 delimiter, which this Mac's
# bash 3.2 read would not split on — labels came out glued to descriptions).
OPTCHUNKS="$(printf '%s' "$_flat" | grep -o '{[^{}]*}' | head -12)"
_pick1() {  # $1 = chunk, $2 = key; first match value or empty
  printf '%s' "$1" \
    | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 \
    | sed 's/^[^:]*:[[:space:]]*"//; s/"$//'
}
OPTS=""; _i=0
while IFS= read -r _chunk; do
  case "$_chunk" in
    *'"label"'*) ;;
    *) continue ;;
  esac
  _lab="$(_clean "$(_pick1 "$_chunk" label)")"
  [ -n "$_lab" ] || continue
  _i=$((_i + 1))
  _desc="$(_clean "$(_pick1 "$_chunk" description)")"
  OPTS="$OPTS{\"index\": $_i, \"label\": \"$_lab\", \"description\": \"$_desc\"}, "
done <<< "$OPTCHUNKS"
OPTS="${OPTS%, }"
NOW="$(date +%s 2>/dev/null || echo 0)"
printf '{"ts": %s, "title": "%s", "question": "%s", "multi": %s, "options": [%s]}\n' \
  "$NOW" "$TITLE" "$QUESTION" "$MULTI" "$OPTS" > "$QFILE" 2>/dev/null || true
exit 0

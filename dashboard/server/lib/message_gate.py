"""The non-Claude message gate: which herdr panes must never be typed into.

A non-Claude agent (OpenCode, Codex, …) draws its own question pickers and
permission boxes, and the dashboard reads them only by screen heuristics
(`other_tui_screens.py`, wording partly guessed). Free text typed into such
a pane can land in a box nobody saw and answer it. AgentBar therefore only
messages a pane row when it has hook data (`RowButtons.messageRoute`,
`agent.hasHookData`), and hook data only ever comes from Claude's hooks.

This module is that rule on the server, so EVERY client (AgentBar, the web
UI, the phone PWA, a curl) gets it on `POST /api/session/message`
(Compact/Clear go through the same route). It is a strict subset of
AgentBar's own gate — a row AgentBar would message (hasHookData) always
passes here — so AgentBar never sees a new refusal.

Rule: a herdr pane row whose `agentKind` (herdr's `agent` field) is not
`claude` and that has no hook data is refused. A herdr row with no
`agentKind` at all is refused too (unknown tool = assume blind). Status-only
rows (Claude Desktop / CLI, `source` != herdr) are Claude by construction
and never refused here.
"""

CLAUDE_AGENT_KIND = "claude"
HERDR_SOURCE = "herdr"

BLIND_AGENT_REFUSAL = (
    "refused: {kind} prompts are invisible to the dashboard — a message "
    "could answer a question or permission box nobody saw. Type in its "
    "terminal instead")


def blind_agent_refusal(agent):
    """The refusal text for a row nothing may be typed into, else None."""
    agent = agent or {}
    if agent.get("source") != HERDR_SOURCE:
        return None
    kind = agent.get("agentKind")
    if kind == CLAUDE_AGENT_KIND or agent.get("hasHookData"):
        return None
    return BLIND_AGENT_REFUSAL.format(kind=kind or "this agent's")

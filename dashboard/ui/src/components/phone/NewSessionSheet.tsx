import { useEffect, useState } from "react";
import { Button, Modal, Radio, Switch, TextInput } from "@mantine/core";
import { listStartablePersonas, startPersona, type StartablePersona } from "../../api";

/** "New session" — start a Claude session for a persona from the phone.
 *  The server decides what is listed (remotely: only personas opted in
 *  with `remoteStart`) and validates everything again on submit; this
 *  sheet only collects persona + first message + "Start fresh". The new
 *  row appears through the normal feeds. */
export function NewSessionSheet({
  opened,
  onClose,
  onToast,
}: {
  opened: boolean;
  onClose: () => void;
  onToast: (msg: string, ok: boolean) => void;
}) {
  const [personas, setPersonas] = useState<StartablePersona[] | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [persona, setPersona] = useState<string>("");
  const [text, setText] = useState("");
  const [fresh, setFresh] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!opened) return;
    let dead = false;
    setError(null);
    setLoadFailed(false);
    listStartablePersonas().then((list) => {
      if (dead) return;
      setPersonas(list ?? []);
      setLoadFailed(list === null);
      if (list && !list.some((p) => p.name === persona)) setPersona(list[0]?.name ?? "");
    });
    return () => {
      dead = true;
    };
    // `persona` only keeps a still-listed choice; re-list on open only.
  }, [opened]);

  const chosen = personas?.find((p) => p.name === persona);
  const canSubmit = !!chosen && text.trim() !== "" && !busy;

  const submit = async () => {
    if (!canSubmit || !chosen) return;
    setBusy(true);
    setError(null);
    const res = await startPersona({ persona: chosen.name, text, fresh });
    setBusy(false);
    if (res.ok) {
      onToast(`${res.mode === "resumed" ? "resumed" : "started"}: ${chosen.name}`, true);
      setText("");
      setFresh(false);
      onClose();
    } else {
      setError(res.error || "start failed");
    }
  };

  return (
    <Modal
      opened={opened}
      onClose={onClose}
      fullScreen
      radius={0}
      transitionProps={{ duration: 160 }}
      classNames={{ content: "phone-sheet", body: "phone-sheet-body", header: "phone-sheet-head" }}
      title={<div className="phone-sheet-title">New session</div>}
    >
      <div className="phone-sheet-scroll">
        {personas === null ? (
          <div className="empty">loading…</div>
        ) : personas.length === 0 ? (
          <div className="empty new-session-empty">
            {loadFailed
              ? "Couldn't load personas."
              : "No persona can be started from here. On the Mac, set \"remoteStart\": true on a persona in personas.json."}
          </div>
        ) : (
          <Radio.Group value={persona} onChange={setPersona} name="persona">
            <div className="new-session-personas">
              {personas.map((p) => (
                <Radio
                  key={p.name}
                  value={p.name}
                  label={p.name}
                  description={p.description}
                  className="new-session-persona"
                />
              ))}
            </div>
          </Radio.Group>
        )}
        {error && <div className="new-session-error">{error}</div>}
      </div>

      <div className="phone-sheet-footer">
        <TextInput
          value={text}
          onChange={(e) => setText(e.currentTarget.value)}
          placeholder="First message…"
          aria-label="first message"
          enterKeyHint="send"
          onKeyDown={(e) => {
            if (e.key === "Enter") void submit();
          }}
        />
        <div className="phone-sheet-actions">
          <Switch
            checked={fresh}
            onChange={(e) => setFresh(e.currentTarget.checked)}
            label={chosen?.idleStart === "resume" && !fresh ? "Start fresh (else resumes)" : "Start fresh"}
            className="new-session-fresh"
          />
          <Button size="sm" disabled={!canSubmit} loading={busy} onClick={() => void submit()}>
            Start
          </Button>
        </div>
      </div>
    </Modal>
  );
}

import { createContext, useContext, useMemo, useSyncExternalStore, type ReactNode } from "react";
import { createToastStore, type ToastInput, type ToastStore } from "./toastStore";
import "./Toast.css";

const ToastContext = createContext<ToastStore | null>(null);

export function ToastProvider({ children }: { children: ReactNode }) {
  const store = useMemo(() => createToastStore(), []);
  const toast = useSyncExternalStore(store.subscribe, store.get);
  return (
    <ToastContext.Provider value={store}>
      {children}
      <div className="ui-toast-region" role="status" aria-live="polite">
        {toast && (
          <div className="ui-toast" key={toast.id}>
            <span className="ui-toast__msg">{toast.message}</span>
            {toast.actionLabel && (
              <button type="button" className="ui-toast__action" onClick={() => store.triggerAction(toast.id)}>
                {toast.actionLabel}
              </button>
            )}
          </div>
        )}
      </div>
    </ToastContext.Provider>
  );
}

/** `show({ message, actionLabel: "Undo", onAction })` — bottom, 5s. */
export function useToast(): { show: (input: ToastInput) => number; dismiss: () => void } {
  const store = useContext(ToastContext);
  if (!store) throw new Error("useToast needs <ToastProvider>");
  return useMemo(() => ({ show: store.show, dismiss: store.dismiss }), [store]);
}

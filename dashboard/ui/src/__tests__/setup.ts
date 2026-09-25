import { GlobalRegistrator } from "@happy-dom/global-registrator";
GlobalRegistrator.register();
// react-dom needs this to run act() without warning on every pass.
(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

// Mantine (via use-media-query / use-resize-observer) calls
// window.matchMedia, which happy-dom does not implement. Without this the
// whole suite throws the moment a Mantine component mounts.
if (typeof window !== "undefined" && !window.matchMedia) {
  window.matchMedia = ((query: string) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: () => {},
    removeListener: () => {},
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => false,
  }) as unknown as MediaQueryList) as typeof window.matchMedia;
}

// Mantine's floating UI measures the viewport on open; happy-dom has no
// ResizeObserver, so provide a no-op stub before any component mounts.
if (typeof window !== "undefined" && !window.ResizeObserver) {
  window.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  } as unknown as typeof window.ResizeObserver;
}

// Minimal ambient types for noVNC's RFB (the package ships no .d.ts). Only the surface vm-console uses.
declare module '@novnc/novnc/lib/rfb.js' {
  export default class RFB extends EventTarget {
    constructor(target: HTMLElement, url: string, options?: Record<string, unknown>);
    scaleViewport: boolean;
    viewOnly: boolean;
    disconnect(): void;
  }
}

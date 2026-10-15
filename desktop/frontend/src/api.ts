export type Input = {
  buttons: number[];
  leftX: number;
  leftY: number;
  rightX: number;
  rightY: number;
  leftTrigger: number;
  rightTrigger: number;
};
export type Setting = { supported: boolean; enabled: boolean };
export type Data = {
  snapshot?: unknown;
  title?: string;
  slot?: number;
  mappings?: Record<string, number | null>;
  turbo?: Setting;
  calibration?: Setting;
  lighting?: unknown;
  color?: string;
  brightness?: number;
  mode?: number;
  versions?: Record<string, string>;
  identity?: { deviceID: number };
  backup?: string;
};
export type State = {
  platformSupported: boolean;
  platformMessage: string;
  devices: {
    path: string;
    name: string;
    product: string;
    accessible: boolean;
  }[];
  path: string;
  dryRun: boolean;
  monitoring: boolean;
  monitorWanted: boolean;
  input: Input | null;
  data: Data;
  logs: { time: string; action: string; mode: string; message: string }[];
  busy: string;
  error: string;
  build: string;
};
type Native = {
  Status(): Promise<State>;
  Refresh(): Promise<State>;
  Select(path: string): Promise<State>;
  SetDryRun(value: boolean): Promise<State>;
  Perform(
    action: string,
    params: Record<string, unknown>,
  ): Promise<Record<string, unknown>>;
  Monitor(value: boolean): Promise<State>;
  CopyReport(): Promise<void>;
  ExportReport(): Promise<string>;
};
declare global {
  interface Window {
    go?: { main: { App: Native } };
    runtime?: {
      EventsOn(
        name: string,
        cb: (event: {
          event: string;
          state?: Input;
          running?: boolean;
        }) => void,
      ): () => void;
    };
  }
}
export const native = !!window.go?.main?.App;
export const initial: State = {
  platformSupported: true,
  platformMessage: "",
  devices: [],
  path: "",
  dryRun: true,
  monitoring: false,
  monitorWanted: false,
  input: null,
  data: {},
  logs: [],
  busy: "",
  error: "",
  build: "Browser preview",
};
let preview = initial;
const unavailable = async (): Promise<never> => {
  throw new Error(
    "Open the desktop app to access a controller. This is a browser preview.",
  );
};
export const api: Native = window.go?.main.App ?? {
  Status: async () => preview,
  Refresh: async () => preview,
  Select: unavailable,
  SetDryRun: async (value) => {
    preview = { ...preview, dryRun: value };
    return preview;
  },
  Perform: unavailable,
  Monitor: unavailable,
  CopyReport: unavailable,
  ExportReport: unavailable,
};
export const names = [
  "D-pad up",
  "D-pad right",
  "D-pad down",
  "D-pad left",
  "A",
  "B",
  "View",
  "X",
  "Y",
  "Menu",
  "LB",
  "RB",
  "LT",
  "RT",
  "L3",
  "R3",
  "C",
  "Z",
  "M1",
  "M2",
  "M3",
  "M4",
];

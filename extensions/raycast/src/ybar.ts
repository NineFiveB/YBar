// The socket client. YBar's daemon listens on a Unix socket and speaks the
// sketchybar wire format: argv tokens NUL-separated with a trailing NUL,
// each direction framed by a little-endian u32 length. A reply that starts
// with "[!]" is an error. Nothing here shells out: Raycast's Node runs with
// a bare PATH, and the socket needs none.
import * as net from "node:net";
import * as os from "node:os";
import { getPreferenceValues } from "@raycast/api";

export class YBarError extends Error {}

interface Preferences {
  socketPath?: string;
}

const REPLY_TIMEOUT_MS = 10_000;

export function socketPath(): string {
  const preferred = getPreferenceValues<Preferences>().socketPath?.trim();
  if (preferred) return preferred;
  const user = os.userInfo().username;
  if (process.platform === "win32") {
    const base = process.env.LOCALAPPDATA ?? os.homedir();
    return `${base}\\ybar\\ybar_${user}.sock`;
  }
  return `/tmp/ybar_${user}.socket`;
}

function encode(args: string[]): Buffer {
  const parts: Buffer[] = [];
  for (const arg of args) {
    parts.push(Buffer.from(arg, "utf8"), Buffer.from([0]));
  }
  parts.push(Buffer.from([0]));
  const payload = Buffer.concat(parts);
  const header = Buffer.alloc(4);
  header.writeUInt32LE(payload.length, 0);
  return Buffer.concat([header, payload]);
}

/** One request, one reply. Resolves with the daemon's text; rejects with YBarError. */
export function send(args: string[]): Promise<string> {
  const path = socketPath();
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let settled = false;
    const finish = (fn: () => void) => {
      if (settled) return;
      settled = true;
      fn();
    };
    const socket = net.createConnection({ path });
    socket.setTimeout(REPLY_TIMEOUT_MS);
    socket.on("connect", () => socket.write(encode(args)));
    socket.on("data", (chunk) => {
      chunks.push(chunk);
      const all = Buffer.concat(chunks);
      if (all.length < 4) return;
      const expected = all.readUInt32LE(0);
      if (all.length < 4 + expected) return;
      const text = all.subarray(4, 4 + expected).toString("utf8");
      socket.end();
      finish(() => (isError(text) ? reject(new YBarError(text)) : resolve(text)));
    });
    socket.on("timeout", () => {
      socket.destroy();
      finish(() => reject(new YBarError("YBar did not answer within 10 seconds.")));
    });
    socket.on("error", (error: NodeJS.ErrnoException) => {
      const gone = error.code === "ENOENT" || error.code === "ECONNREFUSED";
      finish(() =>
        reject(new YBarError(gone ? `YBar is not running (no socket at ${path}).` : error.message)),
      );
    });
    socket.on("close", () =>
      finish(() => reject(new YBarError("YBar closed the connection without a reply."))),
    );
  });
}

function isError(reply: string): boolean {
  return reply.split("\n").some((line) => line.startsWith("[!]"));
}

// --- The settings layer ---------------------------------------------------

export type SettingType = "number" | "string" | "bool" | "color" | "enum" | "list";

export interface SettingRow {
  key: string;
  type: SettingType;
  label: string;
  section: string;
  apply: "live" | "reload";
  default: unknown;
  value: unknown;
  overridden: boolean;
  options?: string[];
  min?: number;
  max?: number;
}

export interface SettingsReply {
  theme: string;
  file: string;
  schema: SettingRow[];
  values: Record<string, unknown>;
  overrides: Record<string, unknown>;
}

export interface ThemeRow {
  name: string;
  path: string;
  current: boolean;
}

export async function querySettings(): Promise<SettingsReply> {
  return JSON.parse(await send(["--query", "settings"])) as SettingsReply;
}

export async function queryThemes(): Promise<ThemeRow[]> {
  return JSON.parse(await send(["--query", "themes"])) as ThemeRow[];
}

/** Writes one key. The daemon validates against the schema and reloads for layout keys. */
export async function setSetting(key: string, token: string): Promise<void> {
  await send(["--settings", "set", `${key}=${token}`]);
}

export async function resetSettings(keys: string[]): Promise<void> {
  await send(["--settings", "reset", ...keys]);
}

export async function useTheme(name: string): Promise<void> {
  await send(["--theme", "use", name]);
}

export async function reloadBar(): Promise<void> {
  await send(["--reload"]);
}

// --- Value helpers --------------------------------------------------------

/** The CLI spelling of a value for a row's type. */
export function tokenOf(row: SettingRow, value: unknown): string {
  switch (row.type) {
    case "bool":
      return value ? "on" : "off";
    case "list":
      return Array.isArray(value) ? value.map(String).join(",") : String(value ?? "");
    default:
      return String(value ?? "");
  }
}

/** What a list row shows for a value. */
export function display(row: SettingRow, value: unknown): string {
  switch (row.type) {
    case "bool":
      return value ? "on" : "off";
    case "list":
      return Array.isArray(value) ? value.map(String).join(", ") : String(value ?? "");
    case "string":
      return value === "" ? "(empty)" : String(value);
    default:
      return String(value ?? "");
  }
}

/** Validate a text-field entry for a row; returns an error message or undefined. */
export function validate(row: SettingRow, text: string): string | undefined {
  const trimmed = text.trim();
  switch (row.type) {
    case "number": {
      const n = Number(trimmed);
      if (trimmed === "" || !Number.isFinite(n)) return "Enter a number.";
      if (row.min !== undefined && n < row.min) return `At least ${row.min}.`;
      if (row.max !== undefined && n > row.max) return `At most ${row.max}.`;
      return undefined;
    }
    case "color":
      if (!/^(0x[0-9a-f]{8}|#([0-9a-f]{6}|[0-9a-f]{8}))$/i.test(trimmed)) {
        return "Use 0xAARRGGBB, #RRGGBB or #AARRGGBB.";
      }
      return undefined;
    case "enum":
      if (row.options && !row.options.includes(trimmed)) return `One of ${row.options.join(", ")}.`;
      return undefined;
    default:
      return undefined;
  }
}

export function sectionsOf(rows: SettingRow[]): [string, SettingRow[]][] {
  const order: string[] = [];
  const groups = new Map<string, SettingRow[]>();
  for (const row of rows) {
    if (!groups.has(row.section)) {
      groups.set(row.section, []);
      order.push(row.section);
    }
    groups.get(row.section)!.push(row);
  }
  return order.map((section) => [section, groups.get(section)!]);
}

import { showToast, Toast } from "@raycast/api";
import { SettingRow, YBarError } from "./ybar";

export async function reportFailure(title: string, error: unknown): Promise<void> {
  const message = error instanceof YBarError ? error.message : String(error);
  await showToast({ style: Toast.Style.Failure, title, message });
}

/** A layout key re-runs the config; say so, since the bar blinks. */
export async function reportSaved(row: SettingRow): Promise<void> {
  await showToast({
    style: Toast.Style.Success,
    title: row.apply === "reload" ? "Saved, bar reloading" : "Saved",
    message: row.label,
  });
}

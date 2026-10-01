import { showToast, Toast } from "@raycast/api";
import { showFailureToast } from "@raycast/utils";
import { SettingRow } from "./ybar";

export async function reportFailure(title: string, error: unknown): Promise<void> {
  await showFailureToast(error, { title });
}

/** A layout key re-runs the config; say so, since the bar blinks. */
export async function reportSaved(row: SettingRow): Promise<void> {
  await showToast({
    style: Toast.Style.Success,
    title: row.apply === "reload" ? "Saved, bar reloading" : "Saved",
    message: row.label,
  });
}

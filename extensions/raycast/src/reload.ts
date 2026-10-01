import { showHUD } from "@raycast/api";
import { reportFailure } from "./feedback";
import { reloadBar } from "./ybar";

export default async function Command() {
  try {
    await reloadBar();
    await showHUD("YBar reloaded");
  } catch (failure) {
    await reportFailure("Could not reload YBar", failure);
  }
}

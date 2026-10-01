import { Action, ActionPanel, Icon, List, showToast, Toast } from "@raycast/api";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import * as os from "node:os";
import { promisify } from "node:util";
import { reportFailure } from "./feedback";

const INSTALL_URL = "https://github.com/NineFiveB/YBar/blob/main/docs/INSTALL.md";

/** Where a Homebrew or `make app` install puts the binary. Absolute paths: Raycast's Node has no PATH to search. */
const BINARIES = [
  "/opt/homebrew/bin/ybar",
  "/usr/local/bin/ybar",
  `${os.homedir()}/Applications/YBar.app/Contents/MacOS/ybar`,
  "/Applications/YBar.app/Contents/MacOS/ybar",
];

export function findBinary(): string | undefined {
  return BINARIES.find((path) => existsSync(path));
}

/**
 * The empty state every command shows when the socket does not answer.
 * "Not running" and "not installed" are different problems, so the actions
 * differ: a found binary can be started, a missing one needs the guide.
 */
export function Unreachable({ error, onRetry }: { error: Error; onRetry: () => void }) {
  const binary = findBinary();

  async function start() {
    if (!binary) return;
    try {
      await showToast({ style: Toast.Style.Animated, title: "Starting YBar…" });
      await promisify(execFile)(binary, ["start"]);
      await new Promise((resolve) => setTimeout(resolve, 3000));
      onRetry();
      await showToast({ style: Toast.Style.Success, title: "YBar started" });
    } catch (failure) {
      await reportFailure("Could not start YBar", failure);
    }
  }

  return (
    <List.EmptyView
      icon={Icon.Plug}
      title={binary ? "YBar is not running" : "YBar is not installed"}
      description={binary ? error.message : `${error.message} Install it from the guide, then come back.`}
      actions={
        <ActionPanel>
          {binary && <Action title="Start YBar" icon={Icon.Play} onAction={start} />}
          <Action title="Try Again" icon={Icon.ArrowClockwise} onAction={onRetry} />
          <Action.OpenInBrowser title="Open Install Guide" url={INSTALL_URL} />
        </ActionPanel>
      }
    />
  );
}

import { Action, ActionPanel, Color, Icon, List, showToast, Toast } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { reportFailure } from "./feedback";
import { queryThemes, useTheme } from "./ybar";

export default function Command() {
  const { data, error, isLoading, revalidate } = useCachedPromise(queryThemes, [], {
    keepPreviousData: true,
  });

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search themes…" navigationTitle="YBar Themes">
      {error && !data ? (
        <List.EmptyView icon={Icon.Plug} title="YBar is not reachable" description={error.message} />
      ) : data && data.length === 0 ? (
        <List.EmptyView
          icon={Icon.Folder}
          title="No themes found"
          description="Install one with `ybar theme install <git-url>` or put a theme under ~/.config/ybar/themes."
        />
      ) : (
        data?.map((theme) => (
          <List.Item
            key={theme.name}
            title={theme.name}
            subtitle={theme.path}
            icon={theme.current ? { source: Icon.CheckCircle, tintColor: Color.Green } : Icon.Circle}
            accessories={theme.current ? [{ tag: { value: "current", color: Color.Green } }] : []}
            actions={
              <ActionPanel>
                {!theme.current && (
                  <Action
                    title="Use Theme"
                    icon={Icon.Brush}
                    onAction={async () => {
                      try {
                        await useTheme(theme.name);
                        await showToast({ style: Toast.Style.Success, title: `Theme: ${theme.name}` });
                        revalidate();
                      } catch (failure) {
                        await reportFailure(`Could not switch to ${theme.name}`, failure);
                      }
                    }}
                  />
                )}
                <Action.ShowInFinder path={theme.path} />
                <Action.CopyToClipboard title="Copy Path" content={theme.path} />
              </ActionPanel>
            }
          />
        ))
      )}
    </List>
  );
}

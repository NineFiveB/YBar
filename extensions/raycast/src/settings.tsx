import { Action, ActionPanel, Color, Icon, Keyboard, List } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { EditSetting } from "./edit-setting";
import { reportFailure, reportSaved } from "./feedback";
import { SettingRow, display, querySettings, reloadBar, resetSettings, sectionsOf, setSetting } from "./ybar";

export default function Command() {
  const { data, error, isLoading, revalidate } = useCachedPromise(querySettings, [], {
    keepPreviousData: true,
  });

  return (
    <List
      isLoading={isLoading}
      searchBarPlaceholder="Search settings…"
      navigationTitle={data ? `YBar · ${data.theme}` : "YBar Settings"}
    >
      {error && !data ? (
        <List.EmptyView icon={Icon.Plug} title="YBar is not reachable" description={error.message} />
      ) : data && data.schema.length === 0 ? (
        <List.EmptyView
          icon={Icon.Document}
          title="This theme declares no settings"
          description={`${data.theme} has no ybar.settings declaration yet.`}
        />
      ) : (
        sectionsOf(data?.schema ?? []).map(([section, rows]) => (
          <List.Section key={section} title={section}>
            {rows.map((row) => (
              <Row key={row.key} row={row} file={data?.file} onChanged={revalidate} />
            ))}
          </List.Section>
        ))
      )}
    </List>
  );
}

function Row({ row, file, onChanged }: { row: SettingRow; file?: string; onChanged: () => void }) {
  async function toggle() {
    try {
      await setSetting(row.key, row.value ? "off" : "on");
      await reportSaved(row);
      onChanged();
    } catch (failure) {
      await reportFailure(`Could not change ${row.label}`, failure);
    }
  }

  async function reset() {
    try {
      await resetSettings([row.key]);
      await reportSaved(row);
      onChanged();
    } catch (failure) {
      await reportFailure(`Could not reset ${row.label}`, failure);
    }
  }

  const accessories: List.Item.Accessory[] = [
    { text: display(row, row.value) },
    row.overridden
      ? {
          tag: { value: "changed", color: Color.Orange },
          tooltip: `Theme default: ${display(row, row.default)}`,
        }
      : { tag: { value: "theme default", color: Color.SecondaryText } },
  ];

  return (
    <List.Item
      title={row.label}
      subtitle={row.key}
      keywords={[row.key, row.section, row.type]}
      icon={iconFor(row)}
      accessories={accessories}
      actions={
        <ActionPanel>
          <ActionPanel.Section>
            {row.type === "bool" ? (
              <Action title={row.value ? "Switch off" : "Switch on"} icon={Icon.Switch} onAction={toggle} />
            ) : (
              <Action.Push
                title="Edit…"
                icon={Icon.Pencil}
                target={<EditSetting row={row} onDone={onChanged} />}
              />
            )}
            {row.overridden && (
              <Action
                title="Reset to Theme Default"
                icon={Icon.ArrowCounterClockwise}
                shortcut={{ modifiers: ["cmd"], key: "backspace" }}
                onAction={reset}
              />
            )}
          </ActionPanel.Section>
          <ActionPanel.Section>
            <Action
              title="Reload Bar"
              icon={Icon.ArrowClockwise}
              shortcut={Keyboard.Shortcut.Common.Refresh}
              onAction={async () => {
                try {
                  await reloadBar();
                  onChanged();
                } catch (failure) {
                  await reportFailure("Could not reload YBar", failure);
                }
              }}
            />
            <Action.CopyToClipboard title="Copy Key" content={row.key} />
            {file && <Action.CopyToClipboard title="Copy Settings File Path" content={file} />}
          </ActionPanel.Section>
        </ActionPanel>
      }
    />
  );
}

function iconFor(row: SettingRow): Icon | { source: Icon; tintColor: string } {
  switch (row.type) {
    case "color": {
      const argb = String(row.value);
      const rgb = /^0x[0-9a-f]{8}$/i.test(argb) ? `#${argb.slice(4)}` : undefined;
      return rgb ? { source: Icon.CircleFilled, tintColor: rgb } : Icon.Circle;
    }
    case "bool":
      return row.value ? Icon.CheckCircle : Icon.Circle;
    case "number":
      return Icon.Ruler;
    case "enum":
      return Icon.List;
    case "list":
      return Icon.BulletPoints;
    default:
      return Icon.Text;
  }
}

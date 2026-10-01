import { Action, ActionPanel, Color, Icon, Keyboard, List } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { reportFailure, reportSaved } from "./feedback";
import { SettingRow, querySettings, resetSettings, setSetting } from "./ybar";

interface Widget {
  name: string;
  label: string;
  enabled: boolean;
  row?: SettingRow;
}

/**
 * The theme's `widgets.order` list plus one `widgets.<name>` switch per
 * widget. The list reads from the clock outward: the first entry sits next
 * to the clock.
 */
export default function Command() {
  const { data, error, isLoading, revalidate } = useCachedPromise(querySettings, [], {
    keepPreviousData: true,
  });
  const orderRow = data?.schema.find((row) => row.key === "widgets.order" && row.type === "list");
  const switches = (data?.schema ?? []).filter(
    (row) => row.type === "bool" && row.key.startsWith("widgets.") && row.key !== "widgets.order",
  );
  const widgets = assemble(orderRow, switches);

  async function writeOrder(names: string[]) {
    if (!orderRow) return;
    try {
      await setSetting(orderRow.key, names.join(","));
      await reportSaved(orderRow);
      revalidate();
    } catch (failure) {
      await reportFailure("Could not reorder widgets", failure);
    }
  }

  async function toggle(widget: Widget) {
    if (!widget.row) return;
    try {
      await setSetting(widget.row.key, widget.enabled ? "off" : "on");
      await reportSaved(widget.row);
      revalidate();
    } catch (failure) {
      await reportFailure(`Could not change ${widget.label}`, failure);
    }
  }

  return (
    <List isLoading={isLoading} navigationTitle="YBar Widgets" searchBarPlaceholder="Search widgets…">
      {error && !data ? (
        <List.EmptyView icon={Icon.Plug} title="YBar is not reachable" description={error.message} />
      ) : data && widgets.length === 0 ? (
        <List.EmptyView
          icon={Icon.AppWindowGrid3x3}
          title="This theme has no widget switches"
          description="A theme declares `widgets.order` and `widgets.<name>` settings to show up here."
        />
      ) : (
        <List.Section title="From the clock outward">
          {widgets.map((widget, index) => (
            <List.Item
              key={widget.name}
              title={widget.label}
              subtitle={widget.name}
              icon={widget.enabled ? { source: Icon.CheckCircle, tintColor: Color.Green } : Icon.Circle}
              accessories={[
                { text: `${index + 1}` },
                widget.enabled ? { tag: { value: "on", color: Color.Green } } : { tag: "off" },
              ]}
              actions={
                <ActionPanel>
                  <ActionPanel.Section>
                    {widget.row && (
                      <Action
                        title={widget.enabled ? "Switch off" : "Switch on"}
                        icon={Icon.Switch}
                        onAction={() => toggle(widget)}
                      />
                    )}
                    {orderRow && index > 0 && (
                      <Action
                        title="Move Toward the Clock"
                        icon={Icon.ArrowUp}
                        shortcut={Keyboard.Shortcut.Common.MoveUp}
                        onAction={() => writeOrder(swap(widgets, index, index - 1))}
                      />
                    )}
                    {orderRow && index < widgets.length - 1 && (
                      <Action
                        title="Move Away from the Clock"
                        icon={Icon.ArrowDown}
                        shortcut={Keyboard.Shortcut.Common.MoveDown}
                        onAction={() => writeOrder(swap(widgets, index, index + 1))}
                      />
                    )}
                  </ActionPanel.Section>
                  <ActionPanel.Section>
                    {orderRow && orderRow.overridden && (
                      <Action
                        title="Reset Order to Theme Default"
                        icon={Icon.ArrowCounterClockwise}
                        onAction={async () => {
                          try {
                            await resetSettings([orderRow.key]);
                            await reportSaved(orderRow);
                            revalidate();
                          } catch (failure) {
                            await reportFailure("Could not reset the order", failure);
                          }
                        }}
                      />
                    )}
                  </ActionPanel.Section>
                </ActionPanel>
              }
            />
          ))}
        </List.Section>
      )}
    </List>
  );
}

function assemble(orderRow: SettingRow | undefined, switches: SettingRow[]): Widget[] {
  const byName = new Map(switches.map((row) => [row.key.slice("widgets.".length), row]));
  const names: string[] = [];
  const listed = Array.isArray(orderRow?.value) ? (orderRow!.value as unknown[]).map(String) : [];
  for (const name of listed) if (!names.includes(name)) names.push(name);
  for (const name of byName.keys()) if (!names.includes(name)) names.push(name);
  return names.map((name) => {
    const row = byName.get(name);
    return { name, label: row?.label ?? name, enabled: row ? Boolean(row.value) : true, row };
  });
}

function swap(widgets: Widget[], a: number, b: number): string[] {
  const names = widgets.map((widget) => widget.name);
  [names[a], names[b]] = [names[b], names[a]];
  return names;
}

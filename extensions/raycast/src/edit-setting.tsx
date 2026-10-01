import { Action, ActionPanel, Form, useNavigation } from "@raycast/api";
import { useState } from "react";
import { reportFailure, reportSaved } from "./feedback";
import { SettingRow, display, setSetting, tokenOf, validate } from "./ybar";

interface Props {
  row: SettingRow;
  onDone: () => void;
}

/** One field, typed by the row. Heights, widths and colors are text fields on purpose. */
export function EditSetting({ row, onDone }: Props) {
  const { pop } = useNavigation();
  const [error, setError] = useState<string | undefined>();
  const [saving, setSaving] = useState(false);

  async function submit(values: { value: string | boolean }) {
    const raw = values.value;
    const token = typeof raw === "boolean" ? (raw ? "on" : "off") : String(raw).trim();
    if (typeof raw !== "boolean") {
      const problem = validate(row, token);
      if (problem) {
        setError(problem);
        return;
      }
    }
    setSaving(true);
    try {
      await setSetting(row.key, token);
      await reportSaved(row);
      onDone();
      pop();
    } catch (failure) {
      await reportFailure(`Could not save ${row.label}`, failure);
    } finally {
      setSaving(false);
    }
  }

  const hint = hintFor(row);
  const defaultText = `Theme default: ${display(row, row.default)}`;

  return (
    <Form
      isLoading={saving}
      navigationTitle={row.label}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Save" onSubmit={submit} />
        </ActionPanel>
      }
    >
      <Form.Description title="Setting" text={`${row.key} · ${row.section}`} />
      {row.type === "bool" ? (
        <Form.Checkbox id="value" label={row.label} defaultValue={Boolean(row.value)} info={defaultText} />
      ) : row.type === "enum" ? (
        <Form.Dropdown id="value" title={row.label} defaultValue={String(row.value)} info={defaultText}>
          {(row.options ?? []).map((option) => (
            <Form.Dropdown.Item key={option} value={option} title={option} />
          ))}
        </Form.Dropdown>
      ) : (
        <Form.TextField
          id="value"
          title={row.label}
          defaultValue={tokenOf(row, row.value)}
          placeholder={tokenOf(row, row.default)}
          info={`${hint} ${defaultText}.`}
          error={error}
          onChange={(text) => setError(validate(row, text))}
        />
      )}
      <Form.Description
        text={
          row.apply === "reload"
            ? "Saving re-runs the bar's config so the change takes effect."
            : "Saving applies the change to the running bar."
        }
      />
    </Form>
  );
}

function hintFor(row: SettingRow): string {
  switch (row.type) {
    case "number": {
      const range =
        row.min !== undefined && row.max !== undefined
          ? ` between ${row.min} and ${row.max}`
          : row.min !== undefined
            ? ` of at least ${row.min}`
            : row.max !== undefined
              ? ` of at most ${row.max}`
              : "";
      return `A number${range}.`;
    }
    case "color":
      return "A color as 0xAARRGGBB, #RRGGBB or #AARRGGBB.";
    case "list":
      return "Comma-separated.";
    case "string":
      return "Free text.";
    default:
      return "";
  }
}

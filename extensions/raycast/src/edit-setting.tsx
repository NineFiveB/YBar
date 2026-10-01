import { Action, ActionPanel, Form, useNavigation } from "@raycast/api";
import { useForm } from "@raycast/utils";
import { ReactNode } from "react";
import { reportFailure, reportSaved } from "./feedback";
import { SettingRow, display, setSetting, tokenOf, validate } from "./ybar";

interface Props {
  row: SettingRow;
  onDone: () => void;
}

/** One field, typed by the row. Heights, widths and colors are text fields on purpose. */
export function EditSetting({ row, onDone }: Props) {
  switch (row.type) {
    case "bool":
      return <BoolEditor row={row} onDone={onDone} />;
    case "enum":
      return <EnumEditor row={row} onDone={onDone} />;
    default:
      return <TextEditor row={row} onDone={onDone} />;
  }
}

function useSave(row: SettingRow, onDone: () => void) {
  const { pop } = useNavigation();
  return async (token: string) => {
    try {
      await setSetting(row.key, token);
      await reportSaved(row);
      onDone();
      pop();
    } catch (failure) {
      await reportFailure(`Could not save ${row.label}`, failure);
    }
  };
}

function Shell<T extends Form.Values>({
  row,
  children,
  onSubmit,
}: {
  row: SettingRow;
  children: ReactNode;
  onSubmit: (values: T) => void | boolean | Promise<void | boolean>;
}) {
  return (
    <Form
      navigationTitle={row.label}
      actions={
        <ActionPanel>
          <Action.SubmitForm<T> title="Save" onSubmit={onSubmit} />
        </ActionPanel>
      }
    >
      <Form.Description title="Setting" text={`${row.key} · ${row.section}`} />
      {children}
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

function TextEditor({ row, onDone }: Props) {
  const save = useSave(row, onDone);
  const { handleSubmit, itemProps } = useForm<{ value: string }>({
    initialValues: { value: tokenOf(row, row.value) },
    validation: { value: (text) => validate(row, text ?? "") },
    onSubmit: (values) => save(values.value.trim()),
  });
  return (
    <Shell row={row} onSubmit={handleSubmit}>
      <Form.TextField
        title={row.label}
        placeholder={tokenOf(row, row.default)}
        info={`${hintFor(row)} Theme default: ${display(row, row.default)}.`}
        {...itemProps.value}
      />
    </Shell>
  );
}

function BoolEditor({ row, onDone }: Props) {
  const save = useSave(row, onDone);
  const { handleSubmit, itemProps } = useForm<{ value: boolean }>({
    initialValues: { value: Boolean(row.value) },
    onSubmit: (values) => save(values.value ? "on" : "off"),
  });
  return (
    <Shell row={row} onSubmit={handleSubmit}>
      <Form.Checkbox
        label={row.label}
        info={`Theme default: ${display(row, row.default)}.`}
        {...itemProps.value}
      />
    </Shell>
  );
}

function EnumEditor({ row, onDone }: Props) {
  const save = useSave(row, onDone);
  const { handleSubmit, itemProps } = useForm<{ value: string }>({
    initialValues: { value: String(row.value) },
    onSubmit: (values) => save(values.value),
  });
  return (
    <Shell row={row} onSubmit={handleSubmit}>
      <Form.Dropdown
        title={row.label}
        info={`Theme default: ${display(row, row.default)}.`}
        {...itemProps.value}
      >
        {(row.options ?? []).map((option) => (
          <Form.Dropdown.Item key={option} value={option} title={option} />
        ))}
      </Form.Dropdown>
    </Shell>
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

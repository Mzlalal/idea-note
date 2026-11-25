import { isolateHistory } from "@codemirror/commands";
import { ChangeSet, Text, type ChangeSpec } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import { GFM, parser as markdownParser } from "@lezer/markdown";

const parser = markdownParser.configure(GFM);
const serviceList = /^- [\w.-]+(?:<br\s*\/?>\s*- [\w.-]+)+$/i;

/** Clean the Markdown constructs emitted by document exports. */
export function markdownCleanup(doc: Text): ChangeSet {
  const source = doc.toString();
  const metadata = /^(?:\uFEFF)?---[ \t]*\n[\s\S]*?\n(?:---|\.\.\.)[ \t]*(?:\n|$)/.exec(source);
  const start = metadata?.[0].length ?? 0;
  const tree = parser.parse(source.slice(start));
  const inline: ChangeSpec[] = [];
  tree.iterate({
    enter(ref) {
      if (ref.name !== "Escape") return;
      const from = start + ref.from;
      const escaped = source.slice(from, start + ref.to);
      if (escaped === "\\-" && /[\p{L}\p{N}]/u.test(source.charAt(from - 1)) &&
          /[\p{L}\p{N}]/u.test(source.charAt(from + 2))) {
        inline.push({ from, to: from + 1 });
      } else if (escaped === "\\." && ref.node.parent?.name === "Link") {
        inline.push({ from, to: from + 1 });
      }
    },
  });

  const inlineChanges = ChangeSet.of(inline, doc.length);
  const updated = inlineChanges.apply(doc).toString();
  const tableChanges: ChangeSpec[] = [];
  parser.parse(updated.slice(start)).iterate({
    enter(ref) {
      if (ref.name !== "TableHeader" && ref.name !== "TableRow") return;
      if (ref.node.parent?.parent?.name !== "Document") return false;
      const cells = ref.node.getChildren("TableCell");
      const values = cells.map(({ from, to }) => updated.slice(start + from, start + to));
      if (ref.name === "TableRow") {
        const row = updated.slice(start + ref.from, start + ref.to);
        if (!/^\|[^|\\]*\|[^|\\]*\|(?:[ \t]*\|)*$/.test(row)) return false;
        const [services, description, ...metadataCells] = row.split("|").slice(1, -1).map((cell) => cell.trim());
        if (description === undefined || !serviceList.test(services ?? "") ||
            metadataCells.some(Boolean) || !/^(?:- )?[\w.-]*$/.test(description)) return false;
        const header = ref.node.parent?.getChild("TableHeader");
        if (header?.getChildren("TableCell").length !== metadataCells.length + 2) return false;
        const rows = services.split(/<br\s*\/?>\s*/i).map((service) =>
          "| " + [service.slice(2), description.replace(/^- /, ""), ...metadataCells].join(" | ") + " |",
        );
        tableChanges.push({ from: start + ref.from, to: start + ref.to, insert: rows.join("\n") });
        return false;
      }

      for (const [index, cell] of cells.entries()) {
        let value = values[index];
        for (let tag = cell.lastChild; tag?.name === "HTMLTag"; tag = tag.prevSibling) {
          const tagEnd = tag.to - cell.from;
          if (tagEnd !== value.length ||
              !/^<br\s*\/?>$/i.test(value.slice(tag.from - cell.from, tagEnd))) break;
          value = value.slice(0, tag.from - cell.from).trimEnd();
        }
        if (/^\*\*[\p{L}\p{N}\s/]+(?:\*{4}[\p{L}\p{N}\s/]+)+\*\*$/u.test(value)) {
          value = value.replace(/\*{4}/g, "");
        }
        if (value !== values[index]) tableChanges.push({
          from: start + cell.from,
          to: start + cell.to,
          insert: value,
        });
      }
      return false;
    },
  });

  return inlineChanges.compose(ChangeSet.of(tableChanges, updated.length));
}

export function organizeMarkdown(view: EditorView): boolean {
  if (view.state.readOnly) return false;
  const changes = markdownCleanup(view.state.doc);
  if (changes.empty) return false;
  view.dispatch({ changes, userEvent: "input.format", annotations: isolateHistory.of("full") });
  return true;
}

// Markdown-faithful soft breaks for the live preview.
//
// In markdown a single "\n" inside a paragraph is only a *soft* break — a real
// renderer collapses it to a space, so the lines flow as one wrapped paragraph.
// A real break needs a blank line (two "\n"), which ends the paragraph. The
// CodeMirror needs a StateField for decorations spanning line boundaries.

import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import {
  EditorState,
  Extension,
  Range,
  StateField,
} from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, WidgetType } from "@codemirror/view";

import { IMAGE_LINE_RE, parseAdvanced } from "./livePreview";
import { highlightColorFromLine } from "../highlightBlock";

/** A markdown hard break (`two trailing spaces`, trailing `\`, or a trailing
 *  raw HTML `<br>`) keeps its line break — only those, plus blank-line
 *  separators, actually break. */
const HARD_BREAK_RE = /(?: {2,}|\\|<br\s*\/?>)\s*$/i;

/** The single space a soft break collapses to. A widget (not a bare replace)
 *  so the joined words don't run together. */
class SoftBreakWidget extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const s = document.createElement("span");
    s.className = "cm-md-softbreak";
    s.textContent = " ";
    return s;
  }
  ignoreEvent() {
    return false;
  }
}

function buildSoftWraps(state: EditorState): DecorationSet {
  const ranges: Range<Decoration>[] = [];
  const doc = state.doc;
  // Force parsing forward so paragraphs below the lazily-parsed region collapse
  // right away on open, not only after the first interaction.
  const tree = ensureSyntaxTree(state, doc.length, 50) ?? syntaxTree(state);

  tree.iterate({
    enter: (node) => {
      if (node.name !== "Paragraph") return;

      const startLine = doc.lineAt(node.from).number;
      const endLine = doc.lineAt(node.to).number;
      if (endLine <= startLine) return; // single line: no interior break

      const imageLines = new Set<number>();
      if (!state.readOnly) {
        const cursor = node.node.cursor();
        cursor.iterate((child) => {
          if (child.name === "Image") imageLines.add(doc.lineAt(child.from).number);
        });
      }

      for (let n = startLine; n < endLine; n++) {
        const line = doc.line(n);
        // Keep the hidden highlight marker on its own visual line. Joining it
        // to the first content line would hide that content with the marker;
        // subsequent lines retain the same soft-break rules as blockquotes.
        if (highlightColorFromLine(line.text)) continue;
        // A hard break keeps its line break.
        if (HARD_BREAK_RE.test(line.text)) continue;
        const next = doc.line(n + 1);
        // Keep standalone images outside the surrounding editable text line.
        if (!state.readOnly && (imageLines.has(n) || imageLines.has(n + 1) ||
            IMAGE_LINE_RE.test(line.text) || IMAGE_LINE_RE.test(next.text))) continue;
        // Swallow the "\n" plus the continuation line's leading indent, the way
        // a markdown soft break does, and render a single joining space.
        const lead = next.text.length - next.text.replace(/^\s+/, "").length;
        ranges.push(
          Decoration.replace({ widget: new SoftBreakWidget() }).range(
            line.to,
            next.from + lead,
          ),
        );
      }
      return false;
    },
  });

  return Decoration.set(ranges, true);
}

const softWrapField = StateField.define<DecorationSet>({
  create: (state) => buildSoftWraps(state),
  update(deco, tr) {
    if (tr.docChanged || tr.startState.readOnly !== tr.state.readOnly || tr.effects.some((e) => e.is(parseAdvanced)))
      return buildSoftWraps(tr.state);
    return deco.map(tr.changes);
  },
  provide: (f) => EditorView.decorations.from(f),
});

export const paragraphSoftWrap: Extension = [
  softWrapField,
  EditorView.atomicRanges.of((view) => view.state.field(softWrapField)),
];

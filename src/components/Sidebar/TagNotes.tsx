import { useMemo, useState } from "react";
import { tr } from "../../i18n/core";
import { NoteCard } from "./NotesTree";
import { TreeDragProvider } from "./treeDrag";
import type { FileNode } from "../../lib/fs";

export function TagNotes({ nodes, onContextMenu }: {
  nodes: FileNode[];
  onContextMenu: (event: React.MouseEvent, node: FileNode) => void;
}) {
  const [selected, setSelected] = useState("");
  const groups = useMemo(() => {
    const groups = new Map<string, FileNode[]>();
    const visit = (entries: FileNode[]) => {
      for (const entry of entries) {
        if (entry.is_dir) {
          visit(entry.children ?? []);
          continue;
        }
        for (const tag of new Set(entry.tags ?? [])) {
          const notes = groups.get(tag) ?? [];
          notes.push(entry);
          groups.set(tag, notes);
        }
      }
    };
    visit(nodes);
    return new Map([...groups].sort(([left], [right]) => left.localeCompare(right)));
  }, [nodes]);
  const active = groups.has(selected) ? selected : groups.keys().next().value;
  if (!active) return <p className="p-4 text-xs text-[var(--text-muted)]">{tr("还没有标签。右键点击笔记即可编辑标签。")}</p>;
  return (
    <div className="space-y-3 px-2">
      <div className="space-y-0.5">
        {[...groups].map(([tag, notes]) => (
          <button key={tag} type="button" aria-pressed={tag === active} onClick={() => setSelected(tag)}
            className={`flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left ${tag === active ? "bg-[var(--active)] font-semibold text-[var(--accent)]" : "text-[var(--text-muted)] hover:bg-[var(--hover)]"}`}>
            <span aria-hidden="true" className={tag === active ? "" : "grayscale"}>🏷️</span>
            <span className="min-w-0 flex-1 truncate">{tag}</span>
            <span className="tabular-nums">({notes.length})</span>
          </button>
        ))}
      </div>
      <TreeDragProvider>
        <div className="space-y-1.5 border-t border-[var(--border)] pt-2">
          {groups.get(active)?.map((note) => (
            <NoteCard key={note.path} node={note} onContextMenu={onContextMenu} />
          ))}
        </div>
      </TreeDragProvider>
    </div>
  );
}

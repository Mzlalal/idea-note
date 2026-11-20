import type { FileNode } from "./fs";

export function groupNotesByDate(nodes: FileNode[]) {
  const groups = new Map<string, FileNode[]>();
  const visit = (entries: FileNode[]) => {
    for (const note of entries) {
      if (note.is_dir) {
        visit(note.children ?? []);
        continue;
      }

      const stamp = /^(\d{4})(\d{2})(\d{2})[-_]\d{6}\.(?:md|markdown)$/i.exec(note.name);
      const date = stamp
        ? new Date(Number(stamp[1]), Number(stamp[2]) - 1, Number(stamp[3]))
        : null;
      const validStamp = date && date.getFullYear() === Number(stamp?.[1])
        && date.getMonth() + 1 === Number(stamp?.[2]) && date.getDate() === Number(stamp?.[3]);
      const day = validStamp ? date : note.mtime == null ? null : new Date(note.mtime);
      const key = day && Number.isFinite(day.getTime())
        ? [day.getFullYear(), day.getMonth() + 1, day.getDate()].map((part) => String(part).padStart(2, "0")).join(".")
        : "";
      const group = groups.get(key) ?? [];
      group.push(note);
      groups.set(key, group);
    }
  };
  visit(nodes);
  return [...groups].sort(([left], [right]) => right.localeCompare(left)).map(([date, notes]) => ({
    date,
    notes: notes.sort((left, right) => right.name.localeCompare(left.name, undefined, { numeric: true }) || left.path.localeCompare(right.path)),
  }));
}

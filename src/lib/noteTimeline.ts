import type { FileNode } from "./fs";

export function noteCreationTime(note: FileNode): number | null {
  const stamp = /^(\d{4})(\d{2})(\d{2})[-_](\d{2})(\d{2})(\d{2})\.(?:md|markdown)$/i.exec(note.name);
  if (stamp) {
    const [year, month, day, hour, minute, second] = stamp.slice(1).map(Number);
    const date = new Date(year, month - 1, day, hour, minute, second);
    if (date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day
      && hour < 24 && minute < 60 && second < 60) return date.getTime();
  }
  return note.created_at ?? note.mtime ?? null;
}

export function newestNoteFirst(left: FileNode, right: FileNode): number {
  return (noteCreationTime(right) ?? -Infinity) - (noteCreationTime(left) ?? -Infinity)
    || left.path.localeCompare(right.path);
}

export function groupNotesByDate(nodes: FileNode[]) {
  const groups = new Map<string, FileNode[]>();
  const visit = (entries: FileNode[]) => {
    for (const note of entries) {
      if (note.is_dir) {
        visit(note.children ?? []);
        continue;
      }

      const created = noteCreationTime(note);
      const day = created == null ? null : new Date(created);
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
    notes: notes.sort(newestNoteFirst),
  }));
}

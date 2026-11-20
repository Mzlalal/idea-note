import { test } from "node:test";
import assert from "node:assert/strict";
import { groupNotesByDate } from "../src/lib/noteTimeline.ts";

test("timeline groups nested timestamped notes and falls back to local modification date", () => {
  const note = (name) => ({ name, path: name, is_dir: false, mtime: new Date(2026, 10, 19, 12).getTime() });
  const first = note("20261120-190000.md");
  const second = note("20261120-180000.md");
  const renamed = note("Renamed.md");
  assert.deepEqual(groupNotesByDate([second, { is_dir: true, children: [first, renamed] }]), [
    { date: "2026.11.20", notes: [first, second] },
    { date: "2026.11.19", notes: [renamed] },
  ]);
});

test("creation time sorts timestamped and renamed notes independently of later edits", () => {
  const older = { name: "20261120-223703.md", path: "/older", is_dir: false, mtime: new Date(2026, 10, 21).getTime() };
  const newer = { name: "Renamed.md", path: "/newer", is_dir: false, created_at: new Date(2026, 10, 20, 23, 19).getTime() };
  assert.deepEqual(groupNotesByDate([older, newer]), [{ date: "2026.11.20", notes: [newer, older] }]);
});

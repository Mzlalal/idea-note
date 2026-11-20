import { test } from "node:test";
import assert from "node:assert/strict";
import { updateNoteTags } from "../src/lib/noteTags.ts";

test("editing note tags preserves body and unrelated metadata", () => {
  const note = "---\ntitle: Existing\ntags:\n  - old\n---\n# Note\n";
  const tagged = updateNoteTags(note, "风控，会员, 风控");
  assert.equal(tagged, '---\ntags: ["风控","会员"]\ntitle: Existing\n---\n# Note\n');
  assert.equal(updateNoteTags(tagged, ""), "---\ntitle: Existing\n---\n# Note\n");
  assert.equal(updateNoteTags("# Note\n", " "), "# Note\n");
});

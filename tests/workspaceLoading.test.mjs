import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";
import { DirectoryTree } from "../src/lib/directoryTree.ts";
import { abortable } from "../src/lib/ai/cancellation.ts";

// Exercise the actual store actions with controlled disk/vault promises. Only
// unrelated UI/settings initialization is left out of this harness.
const source = readFileSync(new URL("../src/store/useAppStore.ts", import.meta.url), "utf8");
const ast = ts.createSourceFile("store.ts", source, ts.ScriptTarget.Latest, true);
const declaration = ast.statements.filter(ts.isVariableStatement)
  .flatMap((s) => [...s.declarationList.declarations]).find((d) => d.name.getText(ast) === "useAppStore");
const object = declaration.initializer.arguments[0].body.expression;
const actions = new Set([
  "openWorkspaceAt", "closeWorkspace", "refreshTree", "loadDirectory", "loadNotes",
  "setSidebarMode", "openFolder", "save", "saveBeforeClose", "openStartupNote", "setContent",
]);
const methods = object.properties.filter((p) => actions.has(p.name?.getText(ast))).map((p) => p.getText(ast)).join(",\n");
const globals = source.slice(source.indexOf("let workspaceRequest ="), source.indexOf("export const useAppStore ="));
const noteNames = source.slice(source.indexOf("const DRAFT_PREFIX"), source.indexOf("function addTab("));
const autosave = source.slice(source.indexOf("let saveInFlight:"), source.indexOf("/** Rendering more than this"));
const code = ts.transpileModule(`${noteNames}\n${autosave}\n${globals}\nexports.actions = {${methods}};`, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText;
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
};
async function until(check) {
  for (let i = 0; i < 100 && !check(); i++) await Promise.resolve();
  assert.ok(check(), "expected async stage");
}
function setup(overrides = {}) {
  const storage = new Map();
  const vaultPaths = [];
  let state = {
    workspacePath: null, tree: [], notesTree: [], notesLoaded: false, notesLoading: false,
    instantNotes: true, sidebarMode: "files", docKey: 0, isDirty: false, expanded: {},
    activeFilePath: null, openTabs: [], draftContents: {}, content: "", savedContentHash: null,
    flushActiveTab: async () => true, stopGlobalSearch() {}, refreshGitInfo: async () => {},
    openFile: async (path) => { state.activeFilePath = path; }, showToast() {},
  };
  const exports = {};
  vm.runInNewContext(code, {
    exports, DirectoryTree, AbortController, abortable, console, setTimeout, clearTimeout,
    get: () => state, set: (update) => { state = { ...state, ...(typeof update === "function" ? update(state) : update) }; },
    listDirectory: async () => [], listNotesIndex: async () => [], clearNoteExcerpts() {},
    useVaultStore: { getState: () => ({ lock: async () => {}, refresh: async (path) => vaultPaths.push(path) }) },
    localStorage: { setItem: (k, v) => storage.set(k, v), getItem: (k) => storage.get(k), removeItem: (k) => storage.delete(k) },
    WORKSPACE_KEY: "workspace", SIDEBAR_MODE_KEY: "sidebar", emptyFormats: {},
    ensureSyncConfigsLoaded: async () => {}, readExpandedFolders: () => ({}),
    flushSecretEdits: async () => ({ blocked: 0 }), hasPendingSecretEdits: () => false,
    captureDiskStat: async () => {}, tr: (message, params) => message.replace("{{0}}", params?.[0] ?? ""),
    pickSavePath: () => { assert.fail("quick notes must save without a naming dialog"); },
    pushRecent: (path) => [path], dropRecent: () => [], readSyncConfig: () => ({}), readAttachmentConfig: () => ({}),
    window: { alert() {} },
    ...overrides,
  });
  state = { ...state, ...exports.actions };
  return { get: () => state, storage, vaultPaths };
}

test("latest project selection wins and loading appears before disk work finishes", async () => {
  const gate = deferred(), reads = [];
  const app = setup({ listDirectory: async (path) => { reads.push(path); return path === "/slow" ? gate.promise : []; } });
  const slow = app.get().openWorkspaceAt("/slow");
  assert.equal(app.get().loadingWorkspace, "/slow");
  await until(() => reads.length === 1);
  const latest = app.get().openWorkspaceAt("/latest");
  await latest; // The next project does not wait for the old disk read.
  gate.resolve([]);
  await Promise.all([slow, latest]);
  assert.equal(app.get().workspacePath, "/latest");
  assert.equal(app.get().loadingWorkspace, null);
  assert.deepEqual(app.vaultPaths, ["/latest"]);
  assert.equal(app.storage.get("workspace"), "/latest");
});

test("the startup editor writes its timestamped note on immediate close", async () => {
  const created = [];
  const app = setup({
    createQuickNote: async (dir, stamp, content) => {
      created.push({ dir, stamp, content });
      return `/documents/Lite Note/${stamp}.md`;
    },
  });
  app.get().openStartupNote();
  assert.match(app.get().activeFilePath, /^untitled:\/\/\d{8}-\d{6}$/);
  assert.equal(created.length, 0);
  app.get().setContent("written before close");
  assert.equal(await app.get().saveBeforeClose(), true);
  assert.equal(created.length, 1);
  assert.equal(created[0].dir, null);
  assert.equal(created[0].content, "written before close");
  assert.equal(app.get().activeFilePath, `/documents/Lite Note/${created[0].stamp}.md`);
  assert.equal(app.get().isDirty, false);
});

test("closing waits for edits typed during an in-flight save", async () => {
  const first = deferred();
  const writes = [];
  const app = setup({ createQuickNote: async () => "/note.md", writeFile: async (_, content) => {
    writes.push(content);
    if (writes.length === 1) await first.promise;
  } });
  app.get().openStartupNote();
  app.get().setContent("initial");
  await app.get().saveBeforeClose();
  app.get().setContent("second edit");
  const closing = app.get().saveBeforeClose();
  await until(() => writes.length === 1);
  app.get().setContent("last edit");
  first.resolve();
  assert.equal(await closing, true);
  assert.deepEqual(writes, ["second edit", "last edit"]);
  assert.equal(app.get().isDirty, false);
});

test("closing during a pending open prevents it from reopening the workspace", async () => {
  const gate = deferred();
  let reading = false;
  const app = setup({ listDirectory: async () => { reading = true; return gate.promise; } });
  const opening = app.get().openWorkspaceAt("/slow");
  await until(() => reading);
  await app.get().closeWorkspace();
  gate.resolve([]);
  await opening;
  assert.equal(app.get().workspacePath, null);
  assert.equal(app.get().loadingWorkspace, null);
  assert.equal(app.storage.get("workspace"), undefined);
});

test("a stale refresh cannot replace another project's tree", async () => {
  const gate = deferred();
  let reads = 0;
  const app = setup({ listDirectory: async (path) => {
    if (path === "/old" && ++reads === 2) return gate.promise;
    return [{ name: path, path: `${path}/note.md`, is_dir: false }];
  } });
  await app.get().openWorkspaceAt("/old");
  const refresh = app.get().refreshTree();
  await app.get().openWorkspaceAt("/new");
  gate.resolve([{ name: "stale", path: "/old/stale.md", is_dir: false }]);
  await refresh; // Superseded refreshes finish quietly, including fire-and-forget callers.
  assert.equal(app.get().tree[0].path, "/new/note.md");
});

test("notes index is optional, does not delay opening, and is cancelled when leaving notes mode", async () => {
  let signal;
  const app = setup({ listNotesIndex: (_path, s) => {
    signal = s;
    return new Promise((_, reject) => s.addEventListener("abort", () => reject(Error("cancelled"))));
  } });
  await app.get().openWorkspaceAt("/notes");
  assert.equal(signal, undefined);
  app.get().setSidebarMode("notes");
  assert.equal(app.get().notesLoading, true);
  app.get().setSidebarMode("outline");
  assert.equal(signal.aborted, true);
  await Promise.resolve();
  assert.equal(app.get().notesLoading, false);
  assert.equal(app.get().notesError, null);
  assert.equal(app.get().notesLoaded, false);
});

test("opening an unloaded deep folder finds README on disk", async () => {
  const app = setup({ listDirectory: async (path) => path === "/ws" ? [{ name: "deep", path: "/ws/deep", is_dir: true }] :
    [{ name: "README.md", path: "/ws/deep/README.md", is_dir: false }] });
  await app.get().openWorkspaceAt("/ws");
  await app.get().openFolder({ path: "/ws/deep", is_dir: true, children: null });
  assert.equal(app.get().activeFilePath, "/ws/deep/README.md");
  assert.equal(app.get().selectedPath, "/ws/deep");
});

test("forced notes refresh updates tags after a cached index", async () => {
  let tags = ["旧标签"];
  const app = setup({ listNotesIndex: async () => [
    { name: "note.md", path: "/notes/note.md", is_dir: false, tags },
  ] });
  await app.get().openWorkspaceAt("/notes");
  await app.get().loadNotes();
  tags = ["新标签"];
  await app.get().loadNotes(true);
  assert.deepEqual(app.get().notesTree[0].tags, tags);
});

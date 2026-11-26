import { tr } from "../i18n/core.ts";
// Paste or drop images / files into a markdown note: the real file is written
// to the directory configured in Settings › 图片/附件, and a markdown reference
// (image embed or attachment link) is inserted. Three sources are handled:
//   1. blobs on the web clipboard (screenshots, copied images, dragged files)
//   2. real files copied in Finder/Explorer (resolved via the native clipboard)
//   3. real files dropped onto the editor from the OS (handleEditorDrop, whose
//      paths come from the native drag-drop event App listens for)

import { invoke } from "@tauri-apps/api/core";
import type { EditorView } from "@codemirror/view";
import { EditorSelection } from "@codemirror/state";

import { useAppStore, isDraftPath, type AttachmentLocation } from "../store/useAppStore";
import {
  basename,
  dirname,
  isImageFile,
  isMarkdownFile,
  writeBinaryFile,
  saveFileToDir,
} from "./fs";
import { hasClipboardImage, listClipboardFiles, readClipboardText, saveClipboardImageToDir } from "./clipboard";

type Kind = "image" | "attachment";

interface Target {
  /** Absolute directory the file is written into. */
  dir: string;
  /** Build the markdown link/src for the final (possibly suffixed) filename. */
  makeLink: (filename: string) => string;
}

/** Collapse repeated/edge slashes; drop empty segments. Keeps a leading "/". */
function joinPath(...parts: string[]): string {
  const lead = parts[0]?.startsWith("/") ? "/" : "";
  const segs = parts
    .join("/")
    .split(/[\\/]+/)
    .filter(Boolean);
  return lead + segs.join("/");
}

/** Path of `toPath` relative to directory `fromDir` (both absolute), using "/". */
function relativeFrom(fromDir: string, toPath: string): string {
  const from = fromDir.split(/[\\/]+/).filter(Boolean);
  const to = toPath.split(/[\\/]+/).filter(Boolean);
  let i = 0;
  while (i < from.length && i < to.length && from[i] === to[i]) i++;
  const up = from.slice(i).map(() => "..");
  const down = to.slice(i);
  const rel = [...up, ...down].join("/");
  return rel || ".";
}

/** Trim surrounding slashes from a user-entered sub-folder. */
const trimSub = (s: string) => s.trim().replace(/^[\\/]+|[\\/]+$/g, "");

/** Two absolute directories are the same place, ignoring separator style and a
 *  trailing slash. Compared case-sensitively: a false negative only costs a
 *  copy, which is what the caller would have done anyway. */
const sameDir = (a: string, b: string) =>
  a.replace(/[\\/]+/g, "/").replace(/\/+$/, "") ===
  b.replace(/[\\/]+/g, "/").replace(/\/+$/, "");

/**
 * Resolve where a file of `kind` should be written and how its link is formed,
 * from the current settings + active note. Returns null (with a toast) when it
 * can't be resolved — e.g. a relative/project location while the note is an
 * unsaved draft, or an absolute location with no path configured.
 */
function resolveTarget(kind: Kind): Target | null {
  const s = useAppStore.getState();
  const location: AttachmentLocation =
    kind === "image" ? s.imageLocation : s.attachmentLocation;
  const rawDir = kind === "image" ? s.imageDir : s.attachmentDir;

  const mdPath = s.activeFilePath;
  const mdDir = mdPath && !isDraftPath(mdPath) ? dirname(mdPath) : null;

  if (location === "absolute") {
    const base = rawDir.trim().replace(/[\\/]+$/g, "");
    if (!base) {
      s.showToast(tr("请先在设置中填写绝对目录"), "error");
      return null;
    }
    return { dir: base, makeLink: (f) => joinPath(base, f) };
  }

  const sub = trimSub(rawDir);

  if (location === "project") {
    const ws = s.workspacePath;
    if (!ws) {
      s.showToast(tr("当前没有打开的工程，无法保存到工程目录"), "error");
      return null;
    }
    const dir = joinPath(ws, sub);
    if (!mdDir) {
      s.showToast(tr("请先保存笔记后再插入文件"), "error");
      return null;
    }
    return { dir, makeLink: (f) => relativeFrom(mdDir, joinPath(dir, f)) };
  }

  // "relative": a sub-folder beside the note itself.
  if (!mdDir) {
    s.showToast(tr("请先保存笔记后再插入文件"), "error");
    return null;
  }
  return { dir: joinPath(mdDir, sub), makeLink: (f) => joinPath(sub, f) };
}

/** Replace whitespace / markdown- and URL-hostile chars so the link stays valid
 *  without needing escaping (the extension is preserved). */
function sanitizeName(name: string): string {
  return name.replace(/[\s()[\]<>#?*|"]+/g, "_").replace(/_+/g, "_");
}

const pad = (n: number) => String(n).padStart(2, "0");

/** A timestamp stem like 20260625-143012 for blobs that arrive without a name. */
function timestamp(): string {
  const d = new Date();
  return (
    `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}` +
    `-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`
  );
}

/** A filename for a pasted blob: its own name when meaningful, else generated. */
function deriveBlobName(file: File, isImage: boolean): string {
  if (file.name && file.name.trim()) return file.name;
  const subtype = file.type.split("/")[1] || (isImage ? "png" : "bin");
  const ext = subtype === "jpeg" ? "jpg" : subtype;
  return `${isImage ? "image" : "file"}-${timestamp()}.${ext}`;
}

interface Ref {
  link: string;
  name: string;
  isImage: boolean;
}

/** Insert image embeds / attachment links one per line, at document position
 *  `at` (where a drop landed) or over the current selection when it's omitted.
 *  The destination is <>-wrapped (CommonMark) so a link stays valid even when
 *  the configured directory or note path contains spaces. */
function insertRefs(view: EditorView, refs: Ref[], at?: number | null): void {
  if (refs.length === 0) return;
  const range = view.state.selection.main;
  const from = at ?? range.from;
  const to = at ?? range.to;
  let text = "";
  for (const [index, ref] of refs.entries()) {
    if (index > 0) text += ref.isImage || refs[index - 1].isImage ? "\n\n" : "\n";
    text += ref.isImage ? `![](<${ref.link}>)` : `[${ref.name}](<${ref.link}>)`;
  }
  if (refs[0].isImage) {
    const line = view.state.doc.lineAt(from);
    if (from > line.from || (line.number > 1 && view.state.doc.line(line.number - 1).text.trim())) {
      text = (from > line.from ? "\n\n" : "\n") + text;
    }
  }
  // Place the caret on a new paragraph so further typing stays clear of the image.
  if (refs[refs.length - 1].isImage) text += "\n\n";
  view.dispatch({
    changes: { from, to, insert: text },
    selection: EditorSelection.cursor(from + text.length),
  });
  view.focus();
}

const pastedImages = new WeakMap<EditorView, Map<string, string>>();

function rememberPastedImage(view: EditorView, path: string, link: string): void {
  let images = pastedImages.get(view);
  if (!images) {
    images = new Map();
    pastedImages.set(view, images);
  }
  images.set(path, link);
}

/** 编辑器退出后重做历史随之释放，才回收没有引用的图片。 */
export function cleanupPastedImages(view: EditorView, workspace: string | null): void {
  const images = pastedImages.get(view);
  pastedImages.delete(view);
  if (!images || !workspace) return;
  const content = view.state.doc.toString();
  const paths = [...images].filter(([path, link]) => !content.includes(link) &&
    !content.includes(basename(path))).map(([path]) => path);
  if (paths.length) {
    void invoke("trash_unused_pasted_images", { workspace, paths }).catch(console.warn);
  }
}

const toastError = (e: unknown) =>
  useAppStore.getState().showToast(e instanceof Error ? e.message : String(e), "error");

/** Fallback for path-less clipboard data (screenshots, images copied from a web
 *  page): there is no file on disk, so the blob's bytes are shipped to Rust.
 *  Real on-disk files go through saveByPaths instead (no bytes through the
 *  webview) — see savePastedFiles. */
async function saveBlobs(view: EditorView, files: File[]): Promise<void> {
  const refs: Ref[] = [];
  for (const file of files) {
    const isImage = file.type.startsWith("image/") || isImageFile(file.name);
    const target = resolveTarget(isImage ? "image" : "attachment");
    if (!target) return;
    const name = sanitizeName(deriveBlobName(file, isImage));
    try {
      const bytes = Array.from(new Uint8Array(await file.arrayBuffer()));
      const created = await writeBinaryFile(target.dir, name, bytes, isImage);
      const finalName = basename(created);
      const link = target.makeLink(finalName);
      if (isImage) rememberPastedImage(view, created, link);
      refs.push({ link, name: finalName, isImage });
    } catch (e) {
      toastError(e);
      return;
    }
  }
  insertRefs(view, refs);
}

/** Reference a file where it already sits, without copying it: the link is
 *  relative to the note's own directory, or absolute for an unsaved draft that
 *  has no directory to be relative to. */
function inPlaceRef(src: string): Ref {
  const s = useAppStore.getState();
  const mdPath = s.activeFilePath;
  const mdDir = mdPath && !isDraftPath(mdPath) ? dirname(mdPath) : null;
  return {
    link: mdDir ? relativeFrom(mdDir, src) : src,
    name: basename(src),
    isImage: isImageFile(src),
  };
}

/** Copy real on-disk files into the configured dir *by path* — Rust does the
 *  copy (fs::copy), so the bytes never pass through the webview. This is the
 *  path even a multi-hundred-MB file takes. Files matching `linkInPlace` skip
 *  the copy and are linked where they already are; `at` is the position to
 *  insert at (the cursor when omitted). */
async function saveByPaths(
  view: EditorView,
  paths: string[],
  opts: { linkInPlace?: (src: string) => boolean; at?: number | null } = {},
): Promise<void> {
  const refs: Ref[] = [];
  for (const src of paths) {
    if (opts.linkInPlace?.(src)) {
      refs.push(inPlaceRef(src));
      continue;
    }
    const isImage = isImageFile(src);
    const target = resolveTarget(isImage ? "image" : "attachment");
    if (!target) return;
    // Already sitting in the destination — dragging an image straight out of
    // the folder it's stored in. Link it instead of copying it next to itself
    // as name-1.ext. Its real name is used, not a sanitized one: the file
    // isn't being renamed, and insertRefs <>-wraps the link anyway.
    if (sameDir(dirname(src), target.dir)) {
      const name = basename(src);
      refs.push({ link: target.makeLink(name), name, isImage });
      continue;
    }
    const name = sanitizeName(basename(src));
    try {
      const created = await saveFileToDir(src, target.dir, name, isImage);
      const finalName = basename(created);
      const link = target.makeLink(finalName);
      if (isImage) rememberPastedImage(view, created, link);
      refs.push({ link, name: finalName, isImage });
    } catch (e) {
      toastError(e);
      return;
    }
  }
  insertRefs(view, refs, opts.at);
}

/** A filename stem (no extension) for a pasted clipboard image: the source
 *  blob's own name when meaningful, else a timestamp. Rust writes it as .png. */
function clipboardImageStem(blobs: File[]): string {
  const raw = blobs.find((b) => b.type.startsWith("image/"))?.name?.trim();
  if (raw) {
    const dot = raw.lastIndexOf(".");
    return sanitizeName(dot > 0 ? raw.slice(0, dot) : raw);
  }
  return `image-${timestamp()}`;
}

/**
 * Resolve a file paste, preferring native handling so bytes never pass through
 * the webview:
 *   1. A file copied in Finder/Explorer exists on disk → Rust copies it by path.
 *   2. A path-less clipboard image (screenshot, image copied from a web page) →
 *      Rust reads the pasteboard image bytes and writes the file directly.
 *   3. Anything else (a non-image path-less blob) → ship the blob bytes as a
 *      last resort.
 * This is what keeps a large paste from freezing the app.
 */
async function savePastedFiles(view: EditorView, blobs: File[]): Promise<boolean> {
  try {
    const paths = await listClipboardFiles();
    if (paths.length > 0) {
      await saveByPaths(view, paths);
      return true;
    }
  } catch {
    /* no native file paths available — fall through */
  }

  if (blobs.some((b) => b.type.startsWith("image/")) || await hasClipboardImage().catch((error) => {
    if (!blobs.length) throw error;
    return false;
  })) {
    const target = resolveTarget("image");
    if (!target) return true;
    try {
      const created = await saveClipboardImageToDir(target.dir, clipboardImageStem(blobs));
      if (created) {
        const finalName = basename(created);
        const link = target.makeLink(finalName);
        rememberPastedImage(view, created, link);
        insertRefs(view, [{ link, name: finalName, isImage: true }]);
        return true;
      }
    } catch (error) {
      if (!blobs.length) throw error;
      /* clipboard read failed — fall back to the blob bytes below */
    }
  }

  if (blobs.length > 0) await saveBlobs(view, blobs);
  return blobs.length > 0;
}

/** The context menu has no ClipboardEvent, so inspect native image/file data
 * before falling back to text. Non-Markdown editors still paste only text. */
export async function pasteEditorClipboard(view: EditorView): Promise<void> {
  if (view.state.readOnly) return;
  const path = useAppStore.getState().activeFilePath;
  if (path && (isDraftPath(path) || isMarkdownFile(path)) && await savePastedFiles(view, [])) return;
  const text = await readClipboardText();
  if (text && !view.state.readOnly)
    view.dispatch(view.state.replaceSelection(text), { scrollIntoView: true });
  view.focus();
}

/**
 * Editor drop handler (markdown notes only): files dropped onto the note are
 * copied into the configured dir and referenced at `at`, the position under the
 * pointer. A dropped markdown file is linked where it already lives instead of
 * being copied — a note is not an attachment, and duplicating it into 图片/附件
 * would leave two copies to keep in sync. A drop of nothing *but* markdown
 * never gets here: App opens those files instead (see its drag-drop listener).
 */
export function handleEditorDrop(
  view: EditorView,
  paths: string[],
  at?: number | null,
): Promise<void> {
  return saveByPaths(view, paths, { linkInPlace: isMarkdownFile, at });
}

/**
 * Editor paste handler (markdown notes only). Returns true when the paste was
 * consumed as a file paste; false lets CodeMirror handle it as a normal text
 * paste. The actual file writes + link insertion run asynchronously.
 */
export function handleEditorPaste(view: EditorView, event: ClipboardEvent): boolean {
  if (view.state.readOnly) return false;
  const dt = event.clipboardData;

  const blobs: File[] = [];
  if (dt) {
    for (const item of Array.from(dt.items)) {
      if (item.kind === "file") {
        const f = item.getAsFile();
        if (f) blobs.push(f);
      }
    }
  }

  // WebKit sometimes exposes the file list without corresponding items.
  if (blobs.length === 0 && dt) blobs.push(...Array.from(dt.files));

  // Keep text paste synchronous. An HTML flavor alone may represent an image
  // whose bytes are only available through the system clipboard.
  if (blobs.length === 0 && dt?.getData("text/plain")) return false;

  event.preventDefault();
  void savePastedFiles(view, blobs).catch(toastError);
  return true;
}

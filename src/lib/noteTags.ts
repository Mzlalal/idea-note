import { parseDocument } from "yaml";

const frontmatter = /^(\uFEFF?)---[ \t]*\r?\n([\s\S]*?)^---[ \t]*(?:\r?\n|$)/m;

export function updateNoteTags(content: string, input: string): string {
  const tags = [...new Set(input.split(/[,，]/).map((tag) => tag.trim()).filter(Boolean))];
  const match = content.match(frontmatter);
  if (!match || match.index !== 0) {
    if (!tags.length) return content;
    const bom = content.startsWith("\uFEFF") ? "\uFEFF" : "";
    return `${bom}---\ntags: ${JSON.stringify(tags)}\n---\n${content.slice(bom.length)}`;
  }
  const document = parseDocument(match[2]);
  if (document.errors.length) throw document.errors[0];
  if (!document.has("tags") && !tags.length) return content;
  document.delete("tags");
  const metadata = document.contents ? document.toString() : "";
  const tagLine = tags.length ? `tags: ${JSON.stringify(tags)}\n` : "";
  return `${match[1]}---\n${tagLine}${metadata}---\n${content.slice(match[0].length)}`;
}

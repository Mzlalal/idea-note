# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=1.26,<2"]
# ///
"""Serve saved Lite Note Markdown files over MCP stdio."""

import argparse
import hashlib
import os
from pathlib import Path
from tempfile import NamedTemporaryFile

from mcp.server.fastmcp import FastMCP

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("workspace", type=Path)
parser.add_argument("--write", action="store_true", help="Enable note creation and updates")
options = parser.parse_args()
root = options.workspace.resolve(strict=True)
if not root.is_dir():
    parser.error("workspace must be a directory")

server = FastMCP("Lite Note")
extensions = {".md", ".markdown"}


def note_path(relative_path: str) -> Path:
    path = Path(relative_path)
    if path.is_absolute() or path.drive or ".." in path.parts or ".git" in path.parts:
        raise ValueError("Use a relative Markdown path inside the workspace")
    candidate = root
    for part in path.parts:
        candidate /= part
        if candidate.is_symlink():
            raise ValueError("Symbolic links are outside the note interface")
    if not candidate.resolve().is_relative_to(root) or candidate.suffix.lower() not in extensions:
        raise ValueError("Use a relative Markdown path inside the workspace")
    return candidate


def revision(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


@server.tool()
def search_notes(query: str, limit: int = 20) -> list[dict[str, str]]:
    """Search saved Markdown titles and body text with a case-insensitive substring."""
    term = query.strip().casefold()
    if not term or not 1 <= limit <= 100:
        raise ValueError("Provide a search term and a limit from 1 to 100")
    matches = []
    for directory, folders, names in os.walk(root):
        folders[:] = sorted(folder for folder in folders
                            if folder != ".git" and not (Path(directory) / folder).is_symlink())
        for name in sorted(names):
            path = Path(directory) / name
            if path.suffix.lower() not in extensions or path.is_symlink() or not path.is_file():
                continue
            try:
                body = path.read_text(encoding="utf-8-sig")
            except (UnicodeError, FileNotFoundError):
                continue
            if term in path.stem.casefold() or term in body.casefold():
                matches.append({"path": path.relative_to(root).as_posix(), "title": path.stem})
                if len(matches) == limit:
                    return matches
    return matches


@server.tool()
def read_note(path: str) -> dict[str, str]:
    """Read a saved Markdown note and return its content and revision."""
    target = note_path(path)
    if not target.is_file():
        raise ValueError("Note does not exist")
    data = target.read_bytes()
    return {"path": path, "content": data.decode("utf-8-sig"), "revision": revision(data)}


if options.write:
    @server.tool()
    def write_note(path: str, content: str, expected_revision: str | None = None) -> dict[str, str]:
        """Create a new note or replace a saved note using the revision returned by read_note."""
        target = note_path(path)
        data = content.encode("utf-8")
        if expected_revision is None:
            with target.open("xb") as note:
                note.write(data)
        else:
            old = target.read_bytes()
            if revision(old) != expected_revision:
                raise ValueError("Note has changed. Read it again before writing")
            if old.startswith(b"\xef\xbb\xbf"):
                data = b"\xef\xbb\xbf" + data
            temporary = None
            try:
                with NamedTemporaryFile(dir=target.parent, delete=False) as note:
                    temporary = Path(note.name)
                    note.write(data)
                temporary.chmod(target.stat().st_mode & 0o777)
                if revision(target.read_bytes()) != expected_revision:
                    raise ValueError("Note has changed. Read it again before writing")
                temporary.replace(target)
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
        return {"path": path, "revision": revision(data)}


if __name__ == "__main__":
    server.run(transport="stdio")

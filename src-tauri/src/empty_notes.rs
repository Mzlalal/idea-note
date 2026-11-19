use std::fs::{self, File, Metadata};
use std::io::{self, BufRead, BufReader};
use std::path::Path;

use encoding_rs::{DecoderResult, Encoding, UTF_8};
use serde::Serialize;

use crate::tree::{is_excluded, is_markdown};

#[derive(Default, Serialize)]
pub struct CleanupResult {
    removed: Vec<String>,
    failed: usize,
}

#[tauri::command]
pub async fn recycle_empty_notes(
    workspace: String,
    protected_path: Option<String>,
) -> Result<CleanupResult, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let protected = protected_path
            .as_deref()
            .and_then(|path| fs::canonicalize(path).ok());
        clean_workspace(Path::new(&workspace), protected.as_deref(), |path| {
            trash::delete(path).is_ok()
        })
        .map_err(|error| error.to_string())
    })
    .await
    .map_err(|error| error.to_string())?
}

fn clean_workspace(
    workspace: &Path,
    protected: Option<&Path>,
    recycle: impl Fn(&Path) -> bool,
) -> io::Result<CleanupResult> {
    // Check the root up front so a missing workspace is reported as an error.
    let mut directories = vec![fs::read_dir(workspace)?];
    let mut result = CleanupResult::default();

    while let Some(directory) = directories.last_mut() {
        let Some(entry) = directory.next() else {
            directories.pop();
            continue;
        };
        let Ok(entry) = entry else {
            result.failed += 1;
            continue;
        };
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if is_excluded(&name) {
            continue;
        }
        let path = entry.path();
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            result.failed += 1;
            continue;
        };
        if is_link_or_reparse_point(&metadata) {
            continue;
        }
        if metadata.is_dir() {
            match fs::read_dir(path) {
                Ok(children) => directories.push(children),
                Err(_) => result.failed += 1,
            }
        } else if metadata.is_file() && is_markdown(&name) {
            match is_blank_note(&path, &metadata) {
                Ok(true) if protected.is_some_and(|protected| same_file(&path, protected)) => {}
                Ok(true) if recycle(&path) => {
                    result.removed.push(path.to_string_lossy().into_owned())
                }
                Ok(true) | Err(_) => result.failed += 1,
                Ok(false) => {}
            }
        }
    }
    Ok(result)
}

fn same_file(path: &Path, canonical: &Path) -> bool {
    fs::canonicalize(path).is_ok_and(|candidate| candidate == canonical)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn finds_only_blank_markdown_inside_the_workspace() {
        let workspace = tempfile::tempdir().unwrap();
        let root = workspace.path();
        fs::create_dir(root.join("nested")).unwrap();
        fs::create_dir(root.join(".git")).unwrap();
        for (path, bytes) in [
            ("empty.md", b"".as_slice()),
            ("nested/whitespace.MARKDOWN", "\u{3000}\n\t".as_bytes()),
            ("utf16.md", &[0xff, 0xfe, 0x20, 0, 0x0a, 0]),
            ("hidden-content.md", b"<!-- content -->"),
            ("binary.md", &[0, 1]),
            ("empty.txt", b""),
            (".git/keep.md", b""),
            ("active.md", b""),
        ] {
            fs::write(root.join(path), bytes).unwrap();
        }
        let active = fs::canonicalize(root.join("active.md")).unwrap();
        let result =
            clean_workspace(root, Some(&active), |file| fs::remove_file(file).is_ok()).unwrap();
        let removed: BTreeSet<_> = result
            .removed
            .iter()
            .map(|path| Path::new(path).file_name().unwrap().to_str().unwrap())
            .collect();
        assert_eq!(
            removed,
            BTreeSet::from(["empty.md", "utf16.md", "whitespace.MARKDOWN"])
        );
        assert_eq!(result.failed, 0);
        for path in [
            "hidden-content.md",
            "binary.md",
            "empty.txt",
            ".git/keep.md",
            "active.md",
        ] {
            assert!(root.join(path).exists(), "{path}");
        }
    }

    #[test]
    fn keeps_scanning_when_the_recycle_bin_rejects_a_file() {
        let workspace = tempfile::tempdir().unwrap();
        let root = workspace.path();
        for file in ["accepted.md", "rejected.md"] {
            fs::write(root.join(file), "").unwrap();
        }
        let result = clean_workspace(root, None, |file| {
            file.ends_with("accepted.md") && fs::remove_file(file).is_ok()
        })
        .unwrap();
        assert_eq!(result.removed.len(), 1);
        assert_eq!(result.failed, 1);
        assert!(root.join("rejected.md").exists());
    }
}

fn is_link_or_reparse_point(metadata: &Metadata) -> bool {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::fs::MetadataExt;
        use windows::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;
        metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0
    }
    #[cfg(not(target_os = "windows"))]
    metadata.file_type().is_symlink()
}

fn is_blank_note(path: &Path, original: &Metadata) -> io::Result<bool> {
    let mut reader = BufReader::new(File::open(path)?);
    let (encoding, bom_size) = Encoding::for_bom(reader.fill_buf()?).unwrap_or((UTF_8, 0));
    reader.consume(bom_size);
    let mut decoder = encoding.new_decoder_without_bom_handling();
    let mut decoded = [0; 4096];

    // Stop after the first non-whitespace character and keep memory bounded.
    loop {
        let bytes = reader.fill_buf()?;
        let eof = bytes.is_empty();
        let (status, read, written) =
            decoder.decode_to_utf8_without_replacement(bytes, &mut decoded, eof);
        let text = std::str::from_utf8(&decoded[..written]).expect("decoder output is UTF-8");
        if text.chars().any(|c| !c.is_whitespace())
            || matches!(status, DecoderResult::Malformed(..))
        {
            return Ok(false);
        }
        if eof && status == DecoderResult::InputEmpty {
            break;
        }
        reader.consume(read);
    }

    let current = fs::symlink_metadata(path)?;
    Ok(current.is_file()
        && !is_link_or_reparse_point(&current)
        && original.len() == current.len()
        && original.modified()? == current.modified()?)
}

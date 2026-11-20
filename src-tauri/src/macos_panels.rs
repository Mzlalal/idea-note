use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use serde::Serialize;
use tauri::{AppHandle, Emitter};

use crate::{background, project_tabs, tree};

type Callback = extern "C" fn(i32, i64, *const c_char);

extern "C" {
    fn lite_note_panels_supported() -> bool;
    fn lite_note_panels_install(callback: Callback);
    fn lite_note_panels_toggle(panel: i32);
    fn lite_note_panels_settings() -> *mut c_char;
    fn lite_note_panels_configure(setting: i32, enabled: bool);
    fn lite_note_panels_permission(input: bool);
    fn lite_note_panels_documents(request: i64, json: *const c_char);
    fn lite_note_panels_opened(error: *const c_char);
}

static APP: OnceLock<AppHandle> = OnceLock::new();

pub fn supported() -> bool {
    unsafe { lite_note_panels_supported() }
}

pub fn install(app: &AppHandle) {
    if supported() && APP.set(app.clone()).is_ok() {
        unsafe { lite_note_panels_install(panel_callback) };
    }
}

pub fn toggle(app: &AppHandle, panel: i32) {
    if let Err(error) = app.run_on_main_thread(move || unsafe { lite_note_panels_toggle(panel) }) {
        eprintln!("Lite Note 面板切换失败: panel:{panel}, error:{error}");
    }
}

#[tauri::command]
pub async fn macos_panel_settings(app: AppHandle) -> Result<Option<serde_json::Value>, String> {
    if !supported() {
        return Ok(None);
    }
    on_main(&app, read_settings).await?
}

#[tauri::command]
pub async fn set_macos_panel_setting(
    app: AppHandle,
    setting: i32,
    enabled: bool,
) -> Result<Option<serde_json::Value>, String> {
    if !(0..=2).contains(&setting) || !supported() {
        return Err("当前系统或设置项不支持此操作".into());
    }
    on_main(&app, move || {
        unsafe { lite_note_panels_configure(setting, enabled) };
        read_settings()
    })
    .await?
}

#[tauri::command]
pub fn request_macos_panel_permission(app: AppHandle, input: bool) -> Result<(), String> {
    app.run_on_main_thread(move || unsafe { lite_note_panels_permission(input) })
        .map_err(|error| error.to_string())
}

async fn on_main<T: Send + 'static>(
    app: &AppHandle,
    run: impl FnOnce() -> T + Send + 'static,
) -> Result<T, String> {
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    app.run_on_main_thread(move || {
        let _ = sender.send(run());
    })
    .map_err(|error| error.to_string())?;
    tauri::async_runtime::spawn_blocking(move || receiver.recv().map_err(|error| error.to_string()))
        .await
        .map_err(|error| error.to_string())?
}

fn read_settings() -> Result<Option<serde_json::Value>, String> {
    let pointer = unsafe { lite_note_panels_settings() };
    if pointer.is_null() {
        return Err("macOS 面板尚未初始化".into());
    }
    let result = unsafe {
        let bytes = CStr::from_ptr(pointer).to_bytes();
        let result = serde_json::from_slice(bytes).map(Some).map_err(|error| error.to_string());
        libc::free(pointer.cast());
        result
    };
    result
}

// Search requests only read the active workspace. Editor activation belongs to
// a separate action, issued exclusively by an explicit document selection.
extern "C" fn panel_callback(action: i32, request: i64, text: *const c_char) {
    let Some(app) = APP.get() else { return };
    if action == 2 {
        background::toggle_window(app);
        return;
    }
    if text.is_null() {
        return;
    }
    let text = unsafe { CStr::from_ptr(text) }.to_string_lossy().into_owned();
    match action {
        0 => search(app, request, text),
        1 => open_document(app, text),
        _ => {}
    }
}

#[derive(Serialize)]
struct Document {
    path: String,
    title: String,
    detail: String,
    window: String,
}

#[derive(Serialize)]
struct SearchResponse {
    documents: Vec<Document>,
    error: Option<String>,
}

fn search(app: &AppHandle, request: i64, query: String) {
    let project = project_tabs::last_window(app).and_then(|window| {
        project_tabs::window_workspace(app, window.label())
            .map(|workspace| (window.label().to_owned(), workspace))
    });
    let app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let result = match project {
            Some((label, workspace)) => collect_documents(Path::new(&workspace), &query, &label),
            None => Err("请先在 Lite Note 打开一个工作区".into()),
        };
        let response = match result {
            Ok(documents) => SearchResponse { documents, error: None },
            Err(error) => SearchResponse { documents: Vec::new(), error: Some(error) },
        };
        match serde_json::to_vec(&response).ok().and_then(|json| CString::new(json).ok()) {
            Some(json) => {
                if let Err(error) = app.run_on_main_thread(move || unsafe {
                    lite_note_panels_documents(request, json.as_ptr())
                }) {
                    eprintln!("Lite Note 文档搜索结果返回失败: request:{request}, error:{error}");
                }
            }
            None => eprintln!("Lite Note 文档搜索序列化失败: request:{request}"),
        }
    });
}

fn collect_documents(root: &Path, query: &str, label: &str) -> Result<Vec<Document>, String> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return Ok(Vec::new());
    }
    let mut pending = vec![root.to_path_buf()];
    let mut documents = Vec::new();
    while let Some(directory) = pending.pop() {
        let entries = match std::fs::read_dir(&directory) {
            Ok(entries) => entries,
            Err(error) if directory != root => {
                eprintln!("Lite Note 无法读取搜索目录: path:{}, error:{error}", directory.display());
                continue;
            }
            Err(error) => return Err(format!("无法搜索工作区 {}：{error}", root.display())),
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            if tree::is_excluded(name) {
                continue;
            }
            let Ok(kind) = entry.file_type() else { continue };
            let path = entry.path();
            if kind.is_dir() {
                pending.push(path);
                continue;
            }
            let extension = path.extension().and_then(|ext| ext.to_str()).unwrap_or_default();
            if !matches!(extension.to_ascii_lowercase().as_str(), "md" | "markdown" | "txt" | "json" | "log")
                || !path.is_file()
            {
                continue;
            }
            let title = path.file_stem().and_then(|name| name.to_str()).unwrap_or(name);
            if title.to_lowercase().contains(&query) {
                documents.push(Document {
                    title: title.into(),
                    detail: path.strip_prefix(root).unwrap_or(&path).display().to_string(),
                    path: path.display().to_string(),
                    window: label.into(),
                });
            }
        }
    }
    documents.sort_by(|left, right| left.detail.cmp(&right.detail));
    documents.truncate(100);
    Ok(documents)
}

fn open_document(app: &AppHandle, selection: String) {
    let result = (|| {
        let (label, path) = selection.split_once('\n').ok_or_else(|| "文档打开请求无效".to_string())?;
        let workspace = project_tabs::window_workspace(app, label).ok_or_else(|| "工作区已关闭".to_string())?;
        let path = PathBuf::from(path);
        if !path.starts_with(workspace) || !path.is_file() {
            return Err("文档已移动、删除或离开当前工作区".to_string());
        }
        project_tabs::activate(app, label)
            .map_err(|error| format!("无法显示编辑器：{error}"))?;
        app.emit_to(tauri::EventTarget::window(label), "launcher:open-document", path).map_err(|error| format!("无法将文档交给编辑器：{error}"))?;
        Ok(())
    })();
    let error = result.err().and_then(|message| CString::new(message).ok());
    unsafe {
        lite_note_panels_opened(error.as_ref().map_or(std::ptr::null(), |value| value.as_ptr()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launcher_only_matches_document_titles() {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir(root.path().join("nested")).unwrap();
        std::fs::write(root.path().join("文档.md"), "").unwrap();
        std::fs::write(root.path().join("nested/文档.txt"), "").unwrap();
        std::fs::write(root.path().join("other.md"), "文档").unwrap();
        let results = collect_documents(root.path(), " 文档 ", "main-2").unwrap();
        assert_eq!(results.len(), 2);
        assert!(results.iter().all(|result| result.title == "文档" && result.window == "main-2"));
        assert_ne!(results[0].detail, results[1].detail);
        assert!(collect_documents(root.path(), " ", "main").unwrap().is_empty());
    }
}

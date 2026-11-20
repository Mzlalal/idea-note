use std::collections::HashSet;
use std::sync::Mutex;

use tauri::menu::{Menu, MenuItem};
#[cfg(target_os = "macos")]
use tauri::menu::IsMenuItem;
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, State, WebviewWindow, Wry};

use crate::project_tabs;

const PREPARE_QUIT: &str = "app:prepare-quit";

#[derive(Default)]
pub struct Background(Mutex<QuitState>);

#[derive(Default)]
struct QuitState {
    ready: HashSet<String>,
    attempt: u32,
    waiting: Option<HashSet<String>>,
}

struct TrayMenu {
    open: MenuItem<Wry>,
    quit: MenuItem<Wry>,
}

pub fn install(app: &AppHandle) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "tray-open", "Open Lite Note", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "tray-quit", "Quit Lite Note", true, None::<&str>)?;
    #[cfg(target_os = "macos")]
    let panel_entries = if crate::macos_panels::supported() {
        Some((
            MenuItem::with_id(app, "tray-launcher", "应用启动台", true, None::<&str>)?,
            MenuItem::with_id(app, "tray-clipboard", "剪贴板", true, None::<&str>)?,
        ))
    } else {
        None
    };
    #[cfg(target_os = "macos")]
    let menu = {
        let mut entries: Vec<&dyn IsMenuItem<Wry>> = vec![&open];
        if let Some((launcher, clipboard)) = &panel_entries {
            entries.extend([launcher as &dyn IsMenuItem<Wry>, clipboard]);
        }
        entries.push(&quit);
        Menu::with_items(app, &entries)?
    };
    #[cfg(target_os = "windows")]
    let menu = Menu::with_items(app, &[&open, &quit])?;
    let mut tray = TrayIconBuilder::with_id("lite-note")
        .tooltip("Lite Note")
        .menu(&menu)
        .show_menu_on_left_click(cfg!(target_os = "macos"))
        .on_menu_event(|app, event| match event.id().as_ref() {
            "tray-open" => show_last_window(app),
            #[cfg(target_os = "macos")]
            "tray-launcher" => crate::macos_panels::toggle(app, 0),
            #[cfg(target_os = "macos")]
            "tray-clipboard" => crate::macos_panels::toggle(app, 1),
            "tray-quit" => request_quit(app),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if cfg!(target_os = "windows")
                && matches!(
                    event,
                    TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    }
                )
            {
                show_last_window(tray.app_handle());
            }
        });
    if let Some(icon) = app.default_window_icon().cloned() {
        tray = tray.icon(icon);
    }
    tray.build(app)?;
    app.manage(TrayMenu { open, quit });
    Ok(())
}

pub fn on_close_requested(window: &tauri::Window, api: &tauri::CloseRequestApi) {
    if !project_tabs::is_project_window(window.label()) {
        return;
    }
    api.prevent_close();
    // The renderer normally saves before hiding. Early closes can hide
    // immediately because the editor has no document buffer yet.
    if !window
        .state::<Background>()
        .0
        .lock()
        .unwrap()
        .ready
        .contains(window.label())
    {
        let _ = window.hide();
    }
}

pub fn show_last_window(app: &AppHandle) {
    if let Some(window) = project_tabs::last_window(app) {
        let _ = window.show();
        if window.is_minimized().unwrap_or(false) {
            let _ = window.unminimize();
        }
        #[cfg(target_os = "windows")]
        crate::double_ctrl::focus(&window);
        #[cfg(target_os = "macos")]
        let _ = window.set_focus();
    }
}

pub fn toggle_window(app: &AppHandle) {
    let focused = app.webview_windows().into_values().find(|window| {
        project_tabs::is_project_window(window.label())
            && window.is_visible().unwrap_or(false)
            && !window.is_minimized().unwrap_or(false)
            && {
                #[cfg(target_os = "windows")]
                { crate::double_ctrl::is_foreground(window) }
                #[cfg(target_os = "macos")]
                { window.is_focused().unwrap_or(false) }
            }
    });
    if let Some(window) = focused {
        let _ = window.close(); // Flush through the usual close-to-tray path.
    } else {
        show_last_window(app);
    }
}

pub fn request_quit(app: &AppHandle) {
    let background = app.state::<Background>();
    let (attempt, windows) = {
        let mut state = background.0.lock().unwrap();
        if state.waiting.is_some() {
            return;
        }
        state.attempt = state.attempt.wrapping_add(1);
        let windows = state.ready.clone();
        if !windows.is_empty() {
            state.waiting = Some(windows.clone());
        }
        (state.attempt, windows)
    };
    if windows.is_empty() {
        app.exit(0);
        return;
    }
    for label in windows {
        if app
            .emit_to(
                tauri::EventTarget::webview_window(label.as_str()),
                PREPARE_QUIT,
                attempt,
            )
            .is_err()
        {
            finish_quit(app, &label, attempt, false);
        }
    }
}

fn finish_quit(app: &AppHandle, label: &str, attempt: u32, saved: bool) {
    let background = app.state::<Background>();
    let exit = {
        let mut state = background.0.lock().unwrap();
        if state.attempt != attempt {
            return;
        }
        let Some(waiting) = state.waiting.as_mut() else {
            return;
        };
        if !waiting.remove(label) {
            return;
        }
        let exit = saved && waiting.is_empty();
        if exit || !saved {
            state.waiting = None;
        }
        exit
    };
    if exit {
        app.exit(0);
    } else if !saved {
        project_tabs::reveal(app, label);
    }
}

pub fn on_window_destroyed(window: &tauri::Window) {
    let app = window.app_handle();
    let background = app.state::<Background>();
    let attempt = {
        let mut state = background.0.lock().unwrap();
        state.ready.remove(window.label());
        state.attempt
    };
    finish_quit(app, window.label(), attempt, true);
}

#[tauri::command]
pub fn register_background_window(window: WebviewWindow, state: State<'_, Background>) {
    if project_tabs::is_project_window(window.label()) {
        state.0.lock().unwrap().ready.insert(window.label().into());
    }
}

#[tauri::command]
pub fn background_quit_ready(window: WebviewWindow, attempt: u32, saved: bool) {
    finish_quit(window.app_handle(), window.label(), attempt, saved);
}

#[tauri::command]
pub fn set_tray_labels(app: AppHandle, open: String, quit: String) -> Result<(), String> {
    let menu = app.state::<TrayMenu>();
    menu.open
        .set_text(open)
        .and_then(|_| menu.quit.set_text(quit))
        .map_err(|error| error.to_string())
}

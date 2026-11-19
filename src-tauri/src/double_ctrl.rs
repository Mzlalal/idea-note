use std::mem::size_of;
use std::sync::{mpsc, Mutex, OnceLock};

use tauri::AppHandle;
use windows::{
    core::w,
    Win32::{
        Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM},
        System::{
            LibraryLoader::GetModuleHandleW,
            Threading::{AttachThreadInput, GetCurrentThreadId},
        },
        UI::{
            Input::{
                GetRawInputData,
                KeyboardAndMouse::{
                    GetAsyncKeyState, VK_CONTROL, VK_LCONTROL, VK_LWIN, VK_MENU, VK_RCONTROL,
                    VK_RWIN, VK_SHIFT,
                },
                RegisterRawInputDevices, HRAWINPUT, RAWINPUT, RAWINPUTDEVICE, RAWINPUTHEADER,
                RIDEV_INPUTSINK, RID_INPUT, RIM_TYPEKEYBOARD,
            },
            WindowsAndMessaging::{
                CreateWindowExW, DefWindowProcW, DispatchMessageW, GetForegroundWindow,
                GetMessageTime, GetMessageW, GetWindowThreadProcessId, RegisterClassW,
                SetForegroundWindow, HWND_MESSAGE, MSG, RI_KEY_BREAK, RI_KEY_E0, WINDOW_EX_STYLE,
                WINDOW_STYLE, WM_INPUT, WNDCLASSW,
            },
        },
    },
};

const DOUBLE_TAP_MS: u32 = 350;

#[derive(Default)]
struct CtrlTaps {
    enabled: bool,
    pressed: Option<(u32, u32)>,
    last_release: Option<u32>,
}

impl CtrlTaps {
    fn key(&mut self, ctrl: bool, down: bool, key: u32, time: u32, other_modifier: bool) -> bool {
        if !self.enabled {
            return false;
        }
        if !ctrl || other_modifier {
            if down || ctrl {
                self.pressed = None;
                self.last_release = None;
            }
            return false;
        }
        if down {
            match self.pressed {
                None => self.pressed = Some((key, time)),
                Some((held, _)) if held == key => {}
                Some(_) => {
                    self.pressed = None;
                    self.last_release = None;
                }
            }
            return false;
        }
        let Some((pressed, start)) = self.pressed.take() else {
            return false;
        };
        if pressed != key || time.wrapping_sub(start) > DOUBLE_TAP_MS {
            self.last_release = None;
            return false;
        }
        if self
            .last_release
            .is_some_and(|last| time.wrapping_sub(last) <= DOUBLE_TAP_MS)
        {
            self.last_release = None;
            return true;
        }
        self.last_release = Some(time);
        false
    }
}

static APP: OnceLock<AppHandle> = OnceLock::new();
static KEYBOARD: OnceLock<Result<(), String>> = OnceLock::new();
static TAPS: Mutex<CtrlTaps> = Mutex::new(CtrlTaps {
    enabled: false,
    pressed: None,
    last_release: None,
});

// Raw Input receives keyboard events across foreground applications without a
// low-level hook timeout. Its message pump stays off the window/UI thread.
pub fn install(app: &AppHandle) {
    let _ = APP.set(app.clone());
    KEYBOARD.get_or_init(|| {
        let (status, ready) = mpsc::channel();
        std::thread::Builder::new()
            .name("lite-note-keyboard".into())
            .spawn(move || {
                let result = unsafe { register_keyboard() };
                let registered = result.is_ok();
                let _ = status.send(result.map_err(|error| error.to_string()));
                if registered {
                    let mut message = MSG::default();
                    unsafe {
                        while GetMessageW(&mut message, None, 0, 0).0 > 0 {
                            DispatchMessageW(&message);
                        }
                    }
                }
            })
            .map_err(|error| error.to_string())?;
        ready.recv().map_err(|error| error.to_string())?
    });
}

unsafe fn register_keyboard() -> windows::core::Result<()> {
    let module = GetModuleHandleW(None)?;
    let instance = HINSTANCE(module.0);
    let class = w!("LiteNoteKeyboard");
    if RegisterClassW(&WNDCLASSW {
        lpfnWndProc: Some(on_input),
        hInstance: instance,
        lpszClassName: class,
        ..Default::default()
    }) == 0
    {
        return Err(windows::core::Error::from_win32());
    }
    let window = CreateWindowExW(
        WINDOW_EX_STYLE(0),
        class,
        w!(""),
        WINDOW_STYLE(0),
        0,
        0,
        0,
        0,
        Some(HWND_MESSAGE),
        None,
        Some(instance),
        None,
    )?;
    RegisterRawInputDevices(
        &[RAWINPUTDEVICE {
            usUsagePage: 1, // Generic Desktop
            usUsage: 6,     // Keyboard
            dwFlags: RIDEV_INPUTSINK,
            hwndTarget: window,
        }],
        size_of::<RAWINPUTDEVICE>() as u32,
    )
}

#[tauri::command]
pub fn set_double_ctrl_activation(enabled: bool) -> Result<(), String> {
    KEYBOARD
        .get()
        .ok_or("keyboard listener is unavailable")?
        .clone()?;
    *TAPS.lock().map_err(|error| error.to_string())? = CtrlTaps {
        enabled,
        ..Default::default()
    };
    Ok(())
}

unsafe extern "system" fn on_input(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_INPUT {
        let mut input = RAWINPUT::default();
        let mut size = size_of::<RAWINPUT>() as u32;
        let read = GetRawInputData(
            HRAWINPUT(lparam.0 as _),
            RID_INPUT,
            Some((&mut input as *mut RAWINPUT).cast()),
            &mut size,
            size_of::<RAWINPUTHEADER>() as u32,
        );
        if read != u32::MAX && input.header.dwType == RIM_TYPEKEYBOARD.0 {
            let keyboard = input.data.keyboard;
            let flags = u32::from(keyboard.Flags);
            let ctrl = [VK_CONTROL.0, VK_LCONTROL.0, VK_RCONTROL.0].contains(&keyboard.VKey);
            let right = keyboard.VKey == VK_RCONTROL.0 || flags & RI_KEY_E0 != 0;
            let key = if right { VK_RCONTROL.0 } else { VK_LCONTROL.0 };
            let other_modifier = ctrl
                && [VK_SHIFT, VK_MENU, VK_LWIN, VK_RWIN]
                    .iter()
                    .any(|modifier| GetAsyncKeyState(i32::from(modifier.0)) < 0);
            let activate = TAPS.lock().is_ok_and(|mut taps| {
                taps.key(
                    ctrl,
                    flags & RI_KEY_BREAK == 0,
                    u32::from(key),
                    GetMessageTime() as u32,
                    other_modifier,
                )
            });
            if activate {
                if let Some(app) = APP.get() {
                    let handle = app.clone();
                    let _ =
                        app.run_on_main_thread(move || crate::background::toggle_window(&handle));
                }
            }
        }
    }
    DefWindowProcW(window, message, wparam, lparam)
}

/// The other app owns foreground input when the shortcut is pressed there.
/// Share its input queue for this explicit activation, then detach immediately.
pub fn focus(window: &tauri::WebviewWindow) {
    if let Ok(target) = window.hwnd() {
        unsafe {
            if SetForegroundWindow(target).as_bool() {
                return;
            }
            let foreground = GetForegroundWindow();
            if !foreground.is_invalid() {
                let other_thread = GetWindowThreadProcessId(foreground, None);
                let own_thread = GetCurrentThreadId();
                if other_thread != 0
                    && other_thread != own_thread
                    && AttachThreadInput(own_thread, other_thread, true).as_bool()
                {
                    let focused = SetForegroundWindow(target).as_bool();
                    let _ = AttachThreadInput(own_thread, other_thread, false);
                    if focused {
                        return;
                    }
                }
            }
        }
    }
    let _ = window.set_focus();
}

pub fn is_foreground(window: &tauri::WebviewWindow) -> bool {
    window
        .hwnd()
        .is_ok_and(|handle| handle == unsafe { GetForegroundWindow() })
}

#[cfg(test)]
mod tests {
    use super::*;

    const CTRL: u32 = VK_LCONTROL.0 as u32;

    #[test]
    fn registers_keyboard_input_for_background_delivery() {
        std::thread::spawn(|| unsafe {
            use windows::Win32::UI::Input::GetRegisteredRawInputDevices;

            register_keyboard().unwrap();
            let mut count = 0;
            let size = size_of::<RAWINPUTDEVICE>() as u32;
            assert_ne!(
                GetRegisteredRawInputDevices(None, &mut count, size),
                u32::MAX
            );
            let mut devices = vec![RAWINPUTDEVICE::default(); count as usize];
            let returned =
                GetRegisteredRawInputDevices(Some(devices.as_mut_ptr()), &mut count, size);
            assert_ne!(returned, u32::MAX);
            assert!(devices.iter().any(|device| {
                device.usUsagePage == 1
                    && device.usUsage == 6
                    && device.dwFlags.0 & RIDEV_INPUTSINK.0 != 0
                    && !device.hwndTarget.is_invalid()
            }));
        })
        .join()
        .unwrap();
    }

    #[test]
    fn two_quick_taps_activate_only_when_enabled() {
        let mut taps = CtrlTaps::default();
        let tap = |taps: &mut CtrlTaps, time| {
            assert!(!taps.key(true, true, CTRL, time, false));
            taps.key(true, false, CTRL, time + 30, false)
        };
        assert!(!tap(&mut taps, 20));
        assert!(!tap(&mut taps, 100));
        taps.enabled = true;
        assert!(!tap(&mut taps, 200));
        assert!(tap(&mut taps, 280));
        assert!(!tap(&mut taps, 360));
        assert!(!tap(&mut taps, 900));
    }

    #[test]
    fn chords_and_long_presses_do_not_count() {
        let mut taps = CtrlTaps {
            enabled: true,
            ..Default::default()
        };
        assert!(!taps.key(true, true, CTRL, 10, false));
        assert!(!taps.key(false, true, b'S' as u32, 20, false));
        assert!(!taps.key(true, false, CTRL, 30, false));
        assert!(!taps.key(true, true, CTRL, 60, false));
        assert!(!taps.key(true, false, CTRL, 90, false));
        assert!(!taps.key(true, true, CTRL, 100, true));
        assert!(!taps.key(true, false, CTRL, 130, true));
        assert!(!taps.key(true, true, CTRL, 200, false));
        assert!(!taps.key(true, true, CTRL, 500, false));
        assert!(!taps.key(true, false, CTRL, 560, false));
    }
}

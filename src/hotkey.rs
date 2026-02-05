use std::str::FromStr;
use std::sync::mpsc::{self, Receiver};
use std::thread;

use eframe::egui;
use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState, hotkey::HotKey};

use crate::models::AppMessage;

pub const DEFAULT_HOTKEY: &str = "super+Space";

pub struct HotKeyRegistration {
    _manager: GlobalHotKeyManager,
    _hotkey: HotKey,
}

impl Drop for HotKeyRegistration {
    fn drop(&mut self) {
        // Best-effort unregister to avoid leaving a dangling global shortcut.
        let _ = self._manager.unregister(self._hotkey);
    }
}

pub fn setup_hotkey_listener(
    ctx: &egui::Context,
) -> (Receiver<AppMessage>, Option<HotKeyRegistration>) {
    setup_hotkey_listener_with(ctx, DEFAULT_HOTKEY)
}

pub fn setup_hotkey_listener_with(
    ctx: &egui::Context,
    hotkey_str: &str,
) -> (Receiver<AppMessage>, Option<HotKeyRegistration>) {
    let (tx, rx) = mpsc::channel();

    let manager = match GlobalHotKeyManager::new() {
        Ok(manager) => manager,
        Err(err) => {
            eprintln!("Global hotkey manager init failed: {err}");
            return (rx, None);
        }
    };

    let hotkey = match HotKey::from_str(hotkey_str) {
        Ok(hotkey) => hotkey,
        Err(err) => {
            eprintln!("Invalid hotkey '{}': {err}", hotkey_str);
            return (rx, None);
        }
    };

    if let Err(err) = manager.register(hotkey) {
        eprintln!(
            "Registering global hotkey '{hotkey_str}' failed: {err}. It may already be in use."
        );
        return (rx, None);
    }

    let hotkey_id = hotkey.id();
    let ctx_clone = ctx.clone();
    thread::spawn(move || {
        let event_receiver = GlobalHotKeyEvent::receiver();
        let mut key_is_down = false;
        while let Ok(event) = event_receiver.recv() {
            if event.id != hotkey_id {
                continue;
            }

            match event.state {
                HotKeyState::Pressed => {
                    // Ignore key-repeat while the shortcut is physically held down.
                    if !key_is_down {
                        key_is_down = true;
                        let _ = tx.send(AppMessage::ToggleLauncher);
                        ctx_clone.request_repaint();
                    }
                }
                HotKeyState::Released => {
                    key_is_down = false;
                }
            }
        }
    });

    (
        rx,
        Some(HotKeyRegistration {
            _manager: manager,
            _hotkey: hotkey,
        }),
    )
}

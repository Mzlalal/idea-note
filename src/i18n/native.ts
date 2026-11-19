import { invoke, isTauri } from "@tauri-apps/api/core";
import { emit, listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { isMac, isWindows } from "../lib/platform";
import { applyLanguage, isAppLanguage, LANGUAGE_EVENT, readLanguage, subscribeLanguage, tr } from "./core";

/** Tauri events cover webviews where localStorage storage events are not delivered. */
export async function initializeNativeLanguage(): Promise<void> {
  if (!isTauri()) return;
  await listen<unknown>(LANGUAGE_EVENT, ({ payload }) => {
    if (isAppLanguage(payload)) applyLanguage(payload);
  });
  applyLanguage(readLanguage());
  window.addEventListener(LANGUAGE_EVENT, (event) => {
    const language = (event as CustomEvent).detail;
    if (isAppLanguage(language)) void emit(LANGUAGE_EVENT, language).catch(console.error);
  });
  const updateNativeLabels = () => {
    const win = getCurrentWindow();
    if (win.label === "settings") void win.setTitle(tr("设置")).catch(console.error);
    if (win.label === "main" && (isWindows || isMac)) {
      void invoke("set_tray_labels", { open: tr("打开 Lite Note"), quit: tr("退出 Lite Note") }).catch(console.error);
    }
  };
  subscribeLanguage(updateNativeLabels);
  updateNativeLabels();
}

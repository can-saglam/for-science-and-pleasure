import { useSyncExternalStore } from "react";

export type ThemePref = "light" | "dark" | "system";

const KEY = "cwg-theme";
const listeners = new Set<() => void>();
const media = window.matchMedia("(prefers-color-scheme: dark)");

export function getThemePref(): ThemePref {
  const v = localStorage.getItem(KEY);
  return v === "light" || v === "dark" ? v : "system";
}

function apply() {
  const pref = getThemePref();
  const dark = pref === "dark" || (pref === "system" && media.matches);
  document.documentElement.classList.toggle("dark", dark);
  // Keeps the iOS status bar / browser chrome in step with the app.
  document
    .querySelector('meta[name="theme-color"]')
    ?.setAttribute("content", dark ? "#0a0a0a" : "#ffffff");
  for (const l of listeners) l();
}

export function setThemePref(pref: ThemePref) {
  localStorage.setItem(KEY, pref);
  apply();
}

/** Call once at startup; the pre-paint script in index.html has already set
 *  the class, this syncs the meta tag and starts tracking system changes. */
export function initTheme() {
  apply();
  media.addEventListener("change", () => {
    if (getThemePref() === "system") apply();
  });
}

/** Re-renders subscribers when dark mode flips (settings or system). */
export function useIsDark(): boolean {
  return useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    () => document.documentElement.classList.contains("dark"),
  );
}

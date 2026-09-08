import { applyAppearance, VIBE_APPEARANCE } from './appearance';

/** Apply the default Vibe chat appearance to :root once at app boot. */
export function applyRootTheme(): void {
  if (typeof document === 'undefined') return;
  applyAppearance(document.documentElement, VIBE_APPEARANCE);
  // Keep body background in sync for overscroll / PWA chrome
  document.body.style.backgroundColor = VIBE_APPEARANCE.bgPrimary;
}

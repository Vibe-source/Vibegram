/**
 * Chat appearance tokens — ported from iOS ChatListViewAppearance.fallback
 * and AppThemePlate "glacier" (Aurora) dark variant.
 *
 * Single source of truth for wallpaper, pattern ink, and bubble gradients.
 * Do not invent alternate palettes here without updating iOS in lockstep.
 */

export type ChatAppearance = {
  id: string;
  backgroundMode: 'gradient' | 'transparent';
  wallpaperGradient: string[];
  wallpaperOpacity: number;
  wallpaperPatternGradient: string[];
  wallpaperPatternLocations: number[];
  wallpaperPatternOpacity: number;
  wallpaperMaskKey: string;
  bubbleMeGradient: string[];
  bubbleThemGradient: string[];
  bubbleThemColor: string;
  textColorMe: string;
  textColorThem: string;
  timeColorMe: string;
  timeColorThem: string;
  messageCornerRadius: number;
  messageTailCurvature: number;
  accent: string;
  bgPrimary: string;
  bgCard: string;
  bgInput: string;
  textPrimary: string;
  textSecondary: string;
};

/** iOS ChatListAppearance.fallback / glacier dark */
export const VIBE_APPEARANCE: ChatAppearance = {
  id: 'glacier-dark',
  backgroundMode: 'gradient',
  wallpaperGradient: ['#05050B', '#05050B'],
  wallpaperOpacity: 1,
  wallpaperPatternGradient: ['#7F5AF0', '#1DB8A6', '#D16F58'],
  wallpaperPatternLocations: [0, 0.5, 1],
  wallpaperPatternOpacity: 0.17,
  wallpaperMaskKey: 'doodles',
  bubbleMeGradient: ['#8B7CFF', '#08C6B4'],
  bubbleThemGradient: ['#252936', '#1A202C'],
  bubbleThemColor: '#252936',
  textColorMe: '#FFFFFF',
  textColorThem: '#F0F0F0',
  timeColorMe: 'rgba(255,255,255,0.68)',
  timeColorThem: 'rgba(255,255,255,0.52)',
  messageCornerRadius: 18,
  messageTailCurvature: 1,
  accent: '#12B8A7',
  bgPrimary: '#05050B',
  bgCard: '#12121A',
  bgInput: '#1A1A24',
  textPrimary: '#E8E6F0',
  textSecondary: '#9896A8',
};

/** Deterministic avatar gradient from a seed (friend id / name) — matches mobile feel */
const AVATAR_PALETTES: [string, string][] = [
  ['#8B7CFF', '#08C6B4'],
  ['#7F5AF0', '#1E90FF'],
  ['#F0516A', '#D16F58'],
  ['#12B8A7', '#2EB872'],
  ['#9C62F0', '#4B9BFF'],
  ['#E89A89', '#7F5AF0'],
  ['#1DB8A6', '#8B7CFF'],
  ['#2F80ED', '#F0516A'],
];

function hashSeed(seed: string): number {
  let h = 0;
  const s = (seed || '?').toUpperCase();
  for (let i = 0; i < s.length; i++) {
    h = (h * 31 + s.charCodeAt(i)) | 0;
  }
  return Math.abs(h);
}

export function avatarGradientFor(seed: string): [string, string] {
  const idx = hashSeed(seed) % AVATAR_PALETTES.length;
  return AVATAR_PALETTES[idx];
}

export function avatarGradientCss(seed: string): string {
  const [a, b] = avatarGradientFor(seed);
  return `linear-gradient(135deg, ${a} 0%, ${b} 100%)`;
}

/** Initials like iOS ChatHomeCardCell.getFallbackInitials */
export function avatarInitials(name: string): string {
  const clean = (name || '').trim();
  if (!clean) return '?';
  const parts = clean.split(/\s+/).filter(Boolean);
  if (parts.length >= 2) {
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
  return clean.slice(0, 2).toUpperCase();
}

export function cssVarsFromAppearance(a: ChatAppearance = VIBE_APPEARANCE): Record<string, string> {
  const meGrad = `linear-gradient(135deg, ${a.bubbleMeGradient[0]} 0%, ${a.bubbleMeGradient[1]} 100%)`;
  const themGrad = `linear-gradient(135deg, ${a.bubbleThemGradient[0]} 0%, ${a.bubbleThemGradient[1]} 100%)`;
  const wallGrad =
    a.wallpaperGradient.length > 1
      ? `linear-gradient(180deg, ${a.wallpaperGradient[0]} 0%, ${a.wallpaperGradient[a.wallpaperGradient.length - 1]} 100%)`
      : a.wallpaperGradient[0];

  return {
    '--bg-primary': a.bgPrimary,
    '--bg-card': a.bgCard,
    '--bg-input': a.bgInput,
    '--text-primary': a.textPrimary,
    '--text-secondary': a.textSecondary,
    '--accent': a.accent,
    '--accent-rgb': '18, 184, 167',
    '--accent-muted': 'rgba(18, 184, 167, 0.85)',
    '--bubble-me': a.bubbleMeGradient[1],
    '--bubble-me-solid': a.bubbleMeGradient[0],
    '--bubble-me-gradient': meGrad,
    '--bubble-me-text': a.textColorMe,
    '--bubble-them': a.bubbleThemColor,
    '--bubble-them-gradient': themGrad,
    '--bubble-me-dark-start': a.bubbleMeGradient[0],
    '--bubble-me-dark-end': a.bubbleMeGradient[1],
    '--bubble-me-light-start': a.bubbleMeGradient[0],
    '--bubble-me-light-end': a.bubbleMeGradient[1],
    '--wallpaper-gradient': wallGrad,
    '--wallpaper-pattern-a': a.wallpaperPatternGradient[0],
    '--wallpaper-pattern-b': a.wallpaperPatternGradient[1],
    '--wallpaper-pattern-c': a.wallpaperPatternGradient[2] || a.wallpaperPatternGradient[1],
    '--wallpaper-pattern-opacity': String(a.wallpaperPatternOpacity),
    '--time-color-me': a.timeColorMe,
    '--time-color-them': a.timeColorThem,
    '--message-corner-radius': `${a.messageCornerRadius}px`,
  };
}

/** Apply appearance CSS variables onto an element (usually document.documentElement or .app-container). */
export function applyAppearance(
  el: HTMLElement | null | undefined,
  appearance: ChatAppearance = VIBE_APPEARANCE
): void {
  if (!el) return;
  const vars = cssVarsFromAppearance(appearance);
  for (const [k, v] of Object.entries(vars)) {
    el.style.setProperty(k, v);
  }
}

/** Home-list last-message preview (matches mobile row content). */
export function chatPreviewText(
  chat: {
    previewLastMessage?: string;
    lastMessage?: { type?: string; plaintext?: string; fromId?: string };
    messages: Array<{ type?: string; plaintext?: string; fromId?: string; timestamp?: number }>;
  },
  userId: string
): string {
  if (chat.previewLastMessage && chat.previewLastMessage.trim()) {
    return chat.previewLastMessage;
  }
  const last =
    chat.lastMessage ||
    (chat.messages.length ? chat.messages[chat.messages.length - 1] : undefined);
  if (!last) return 'No messages yet';

  const isMe = (last.fromId || '').toLowerCase() === (userId || '').toLowerCase();
  let body = '';
  switch (last.type) {
    case 'image':
      body = 'Photo';
      break;
    case 'voice':
      body = 'Voice message';
      break;
    case 'gif':
      body = 'GIF';
      break;
    case 'call':
      body = 'Call';
      break;
    default:
      body = (last.plaintext || '').trim() || 'Message';
      break;
  }
  // Truncate long previews
  if (body.length > 80) body = body.slice(0, 77) + '…';
  return isMe ? `You: ${body}` : body;
}

export function chatLastTimestamp(chat: {
  lastMessage?: { timestamp?: number };
  messages: Array<{ timestamp?: number }>;
}): number {
  return (
    chat.lastMessage?.timestamp ||
    (chat.messages.length ? chat.messages[chat.messages.length - 1]?.timestamp : 0) ||
    0
  );
}

/** Compact list time like mobile: time today, weekday, or short date */
export function formatChatListTime(ts: number | string | undefined): string {
  if (!ts) return '';
  const d = new Date(ts);
  if (isNaN(d.getTime())) return '';
  const now = new Date();
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const startOfMsg = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const dayDiff = Math.round((startOfToday - startOfMsg) / 86400000);

  if (dayDiff === 0) {
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }
  if (dayDiff === 1) return 'Yesterday';
  if (dayDiff < 7) {
    return d.toLocaleDateString([], { weekday: 'short' });
  }
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
}

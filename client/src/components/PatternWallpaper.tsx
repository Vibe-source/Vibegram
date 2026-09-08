import { useMemo } from 'react';
import { VIBE_APPEARANCE } from '../theme/appearance';

interface Props {
  colors?: string[];
  patternOpacity?: number;
  maskKey?: string;
}

/**
 * Chat wallpaper — ports iOS ChatListAppearance pattern mask:
 * solid/gradient base + multi-stop pattern ink masked by doodle PNG.
 */
export default function PatternWallpaper({
  colors,
  patternOpacity,
  maskKey = VIBE_APPEARANCE.wallpaperMaskKey,
}: Props) {
  const wall = useMemo(() => {
    if (colors && colors.length > 0) {
      return colors.length > 1
        ? `linear-gradient(135deg, ${colors[0]}, ${colors[1]})`
        : colors[0];
    }
    const g = VIBE_APPEARANCE.wallpaperGradient;
    return g.length > 1
      ? `linear-gradient(180deg, ${g[0]} 0%, ${g[g.length - 1]} 100%)`
      : g[0];
  }, [colors]);

  const patternStops = VIBE_APPEARANCE.wallpaperPatternGradient;
  const opacity =
    patternOpacity ?? VIBE_APPEARANCE.wallpaperPatternOpacity;

  // Map mask keys to public assets (copied from iOS ChatModule/Resources)
  const maskSrc =
    maskKey === 'music'
      ? '/music_transparent.png'
      : maskKey === 'music2'
        ? '/music2_transparent.png'
        : maskKey === 'food'
          ? '/food_transparent.png'
          : maskKey === 'animals'
            ? '/animals_transparent.png'
            : '/doodle_transparent.png';

  return (
    <div
      className="pattern-wallpaper"
      aria-hidden="true"
      style={{
        position: 'absolute',
        inset: 0,
        zIndex: 0,
        overflow: 'hidden',
        pointerEvents: 'none',
        background: wall,
      }}
    >
      {/* Multi-hue pattern ink, clipped by the doodle mask (iOS CALayer mask) */}
      <div
        className="pattern-wallpaper-mask"
        style={{
          position: 'absolute',
          inset: 0,
          opacity,
          background: `linear-gradient(
            135deg,
            ${patternStops[0]} 0%,
            ${patternStops[1]} 50%,
            ${patternStops[2] || patternStops[1]} 100%
          )`,
          WebkitMaskImage: `url(${maskSrc})`,
          maskImage: `url(${maskSrc})`,
          WebkitMaskSize: 'cover',
          maskSize: 'cover',
          WebkitMaskPosition: 'center',
          maskPosition: 'center',
          WebkitMaskRepeat: 'no-repeat',
          maskRepeat: 'no-repeat',
        }}
      />
      {/* Soft vignette so chrome / bubbles stay legible */}
      <div
        style={{
          position: 'absolute',
          inset: 0,
          background:
            'radial-gradient(120% 80% at 50% 40%, transparent 0%, rgba(5,5,11,0.35) 100%)',
        }}
      />
    </div>
  );
}

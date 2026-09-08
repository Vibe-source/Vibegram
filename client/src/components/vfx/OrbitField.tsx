/**
 * SectionWash — soft ambient color field for landing sections.
 *
 * Pure CSS radial washes (no canvas, no runtime blur). Tone shifts the
 * palette toward teal (security), violet (agents), or a blend (join).
 * ContourField remains the living WebGL substrate site-wide; this is the
 * section-local accent layer that sits under copy and demos.
 */

export type SectionWashTone = 'teal' | 'violet' | 'blend';

interface SectionWashProps {
  tone?: SectionWashTone;
  className?: string;
}

export const SectionWash = ({ tone = 'teal', className }: SectionWashProps) => (
  <div
    className={['vl-section-wash', `vl-section-wash--${tone}`, className]
      .filter(Boolean)
      .join(' ')}
    aria-hidden="true"
  />
);

export default SectionWash;

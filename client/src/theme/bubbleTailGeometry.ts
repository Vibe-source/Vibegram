/** Radius-18 message-tail geometry mirrored from iOS TelegramReferenceTailGeometry. */
export type BubbleTailPoint = readonly [x: number, y: number];

export type BubbleTailGeometry = {
  outerStart: BubbleTailPoint;
  outerControl1: BubbleTailPoint;
  outerControl2: BubbleTailPoint;
  tip: BubbleTailPoint;
  innerControl1: BubbleTailPoint;
  innerControl2: BubbleTailPoint;
  notch: BubbleTailPoint;
  cornerControl1: BubbleTailPoint;
  cornerControl2: BubbleTailPoint;
  bottomJoin: BubbleTailPoint;
};

const COMPACT_SCALE = 0.58;

const REFERENCE: BubbleTailGeometry = {
  outerStart: [0.0967, -7.9401],
  outerControl1: [0.0967, -4.6557],
  outerControl2: [4.4885, -2.5490],
  tip: [5.3793, 0.0061],
  innerControl1: [0.6122, 0.6143],
  innerControl2: [-3.9233, -0.5402],
  notch: [-7.0522, -3.8821],
  cornerControl1: [-9.0308, -1.5103],
  cornerControl2: [-12.1883, 0.0061],
  bottomJoin: [-14.77, 0.0061],
};

export const BUBBLE_TAIL_VIEW_BOX = {
  x: -15.77,
  y: -8.9401,
  width: 22.1493,
  height: 10.4401,
} as const;

export const BUBBLE_TAIL_BODY_ORIGIN = {
  outgoingX: 15.77,
  incomingX: 6.3793,
  y: 8.9401,
} as const;

function compact(point: BubbleTailPoint): BubbleTailPoint {
  return [point[0] * COMPACT_SCALE, point[1] * COMPACT_SCALE];
}

function chord(start: BubbleTailPoint, end: BubbleTailPoint, fraction: number): BubbleTailPoint {
  return [
    start[0] + (end[0] - start[0]) * fraction,
    start[1] + (end[1] - start[1]) * fraction,
  ];
}

function adjustable(
  straight: BubbleTailPoint,
  reference: BubbleTailPoint,
  curvature: number,
): BubbleTailPoint {
  if (curvature >= 0.999999) return reference;
  return [
    straight[0] + (reference[0] - straight[0]) * curvature,
    straight[1] + (reference[1] - straight[1]) * curvature,
  ];
}

export function resolveBubbleTailGeometry(curvature = 1): BubbleTailGeometry {
  const t = Math.max(0, Math.min(1, curvature));
  const straightOuterStart = compact(REFERENCE.outerStart);
  const straightTip = compact(REFERENCE.tip);
  const straightNotch = compact(REFERENCE.notch);
  const straightBottomJoin = compact(REFERENCE.bottomJoin);
  return {
    outerStart: adjustable(straightOuterStart, REFERENCE.outerStart, t),
    outerControl1: adjustable(
      chord(straightOuterStart, straightTip, 1 / 3), REFERENCE.outerControl1, t),
    outerControl2: adjustable(
      chord(straightOuterStart, straightTip, 2 / 3), REFERENCE.outerControl2, t),
    tip: adjustable(straightTip, REFERENCE.tip, t),
    innerControl1: adjustable(
      chord(straightTip, straightNotch, 1 / 3), REFERENCE.innerControl1, t),
    innerControl2: adjustable(
      chord(straightTip, straightNotch, 2 / 3), REFERENCE.innerControl2, t),
    notch: adjustable(straightNotch, REFERENCE.notch, t),
    cornerControl1: adjustable(
      chord(straightNotch, straightBottomJoin, 1 / 3), REFERENCE.cornerControl1, t),
    cornerControl2: adjustable(
      chord(straightNotch, straightBottomJoin, 2 / 3), REFERENCE.cornerControl2, t),
    bottomJoin: adjustable(straightBottomJoin, REFERENCE.bottomJoin, t),
  };
}

function point(point: BubbleTailPoint): string {
  return `${point[0]} ${point[1]}`;
}

export function bubbleTailPathData(curvature = 1): string {
  const geometry = resolveBubbleTailGeometry(curvature);
  return [
    `M ${point(geometry.outerStart)}`,
    `C ${point(geometry.outerControl1)} ${point(geometry.outerControl2)} ${point(geometry.tip)}`,
    `C ${point(geometry.innerControl1)} ${point(geometry.innerControl2)} ${point(geometry.notch)}`,
    `C ${point(geometry.cornerControl1)} ${point(geometry.cornerControl2)} ${point(geometry.bottomJoin)}`,
    'Z',
  ].join(' ');
}

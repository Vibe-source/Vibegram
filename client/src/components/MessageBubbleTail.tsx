import { BUBBLE_TAIL_BODY_ORIGIN, BUBBLE_TAIL_VIEW_BOX, bubbleTailPathData } from '../theme/bubbleTailGeometry';

type MessageBubbleTailProps = {
  isMe: boolean;
  cornerRadius?: number;
  curvature?: number;
};

export default function MessageBubbleTail({
  isMe,
  cornerRadius = 18,
  curvature = 1,
}: MessageBubbleTailProps) {
  const scale = Math.max(0, cornerRadius) / 18;
  const outside = BUBBLE_TAIL_VIEW_BOX.width - BUBBLE_TAIL_BODY_ORIGIN.outgoingX;
  const below = BUBBLE_TAIL_VIEW_BOX.height - BUBBLE_TAIL_BODY_ORIGIN.y;
  return (
    <svg
      aria-hidden="true"
      className={`message-bubble-tail ${isMe ? 'message-bubble-tail--sent' : 'message-bubble-tail--received'}`}
      focusable="false"
      viewBox={`${BUBBLE_TAIL_VIEW_BOX.x} ${BUBBLE_TAIL_VIEW_BOX.y} ${BUBBLE_TAIL_VIEW_BOX.width} ${BUBBLE_TAIL_VIEW_BOX.height}`}
      style={{
        width: BUBBLE_TAIL_VIEW_BOX.width * scale,
        height: BUBBLE_TAIL_VIEW_BOX.height * scale,
        bottom: -below * scale,
        ...(isMe ? { right: -outside * scale } : { left: -outside * scale }),
      }}
    >
      <path d={bubbleTailPathData(curvature)} fill="currentColor" />
    </svg>
  );
}

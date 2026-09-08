package com.mohammadshayani.vibe.chat

import com.mohammadshayani.vibe.R

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.SystemClock
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.view.animation.AccelerateDecelerateInterpolator
import android.view.animation.LinearInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

internal class NativeRowViewHolder(
  val container: FrameLayout,
  val bubbleContainer: FrameLayout,
  val tailView: BubbleTailView,
  val selectionCircleView: MessageSelectionCircleView,
  val replyPreviewView: FrameLayout,
  val replyPreviewTitleView: TextView,
  val replyPreviewTextView: TextView,
  val textView: TextView,
  val inlineAttachmentView: FrameLayout,
  val mediaPreviewView: FrameLayout,
  val mediaImageView: ImageView,
  val mediaPlayBadgeView: TextView,
  val mediaDurationBadgeView: TextView,
  val mediaTransferOverlayView: FrameLayout,
  val mediaTransferRingView: BubbleUploadProgressView,
  val mediaTransferSizeView: TextView,
  val inlineAttachmentTitleView: TextView,
  val inlineAttachmentSubtitleView: TextView,
  val voiceContainer: FrameLayout,
  val voiceButton: VoicePlayProgressView,
  val voiceWaveView: VoiceWaveformView,
  val voiceUploadProgressView: VoiceUploadProgressView,
  val voiceDurationView: TextView,
  val timeView: TextView,
  val statusView: BubbleStatusIndicatorView,
  val retryButtonView: BubbleRetryButtonView,
  val dayLabel: TextView,
  val agentSenderLabel: TextView,
) : RecyclerView.ViewHolder(container)

internal class MessageSelectionCircleView(context: Context) : View(context) {
  private var checked = false
  private var accentColor = Color.argb(255, 106, 79, 207)
  private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeWidth = dpF(2f)
    strokeCap = Paint.Cap.ROUND
  }
  private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
  }
  private val checkPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeWidth = dpF(2.1f)
    strokeCap = Paint.Cap.ROUND
    strokeJoin = Paint.Join.ROUND
    color = Color.WHITE
  }
  private val checkPath = Path()

  init {
    isClickable = true
    isFocusable = true
  }

  fun bind(selected: Boolean, appearance: ChatListAppearance) {
    checked = selected
    accentColor = appearance.bubbleMeGradient.firstOrNull() ?: accentColor
    invalidate()
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val size = min(width, height).toFloat().coerceAtLeast(1f)
    val radius = (size * 0.5f) - dpF(2f)
    val cx = width * 0.5f
    val cy = height * 0.5f
    if (checked) {
      fillPaint.color = accentColor
      canvas.drawCircle(cx, cy, radius, fillPaint)
      checkPath.reset()
      checkPath.moveTo(cx - radius * 0.42f, cy + radius * 0.02f)
      checkPath.lineTo(cx - radius * 0.12f, cy + radius * 0.32f)
      checkPath.lineTo(cx + radius * 0.45f, cy - radius * 0.30f)
      canvas.drawPath(checkPath, checkPaint)
    } else {
      ringPaint.color = Color.argb(180, 142, 150, 165)
      canvas.drawCircle(cx, cy, radius, ringPaint)
    }
  }

  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )
}

internal data class BubbleTailPoint(val x: Float, val y: Float)

internal data class BubbleTailGeometry(
  val outerStart: BubbleTailPoint,
  val outerControl1: BubbleTailPoint,
  val outerControl2: BubbleTailPoint,
  val tip: BubbleTailPoint,
  val innerControl1: BubbleTailPoint,
  val innerControl2: BubbleTailPoint,
  val notch: BubbleTailPoint,
  val cornerControl1: BubbleTailPoint,
  val cornerControl2: BubbleTailPoint,
  val bottomJoin: BubbleTailPoint,
)

/** Exact radius-18 geometry from iOS TelegramReferenceTailGeometry. */
internal object BubbleTailGeometrySource {
  private const val COMPACT_SCALE = 0.58f
  private const val REFERENCE_INSIDE_EXTENT = 14.7700f
  private const val REFERENCE_OUTSIDE_EXTENT = 5.3793f
  private const val REFERENCE_TOP_EXTENT = 7.9401f
  private const val REFERENCE_BOTTOM_RESERVE = 0.5f
  private const val FRAME_PADDING = 1f

  private val referenceOuterStart = BubbleTailPoint(0.0967f, -7.9401f)
  private val referenceOuterControl1 = BubbleTailPoint(0.0967f, -4.6557f)
  private val referenceOuterControl2 = BubbleTailPoint(4.4885f, -2.5490f)
  private val referenceTip = BubbleTailPoint(5.3793f, 0.0061f)
  private val referenceInnerControl1 = BubbleTailPoint(0.6122f, 0.6143f)
  private val referenceInnerControl2 = BubbleTailPoint(-3.9233f, -0.5402f)
  private val referenceNotch = BubbleTailPoint(-7.0522f, -3.8821f)
  private val referenceCornerControl1 = BubbleTailPoint(-9.0308f, -1.5103f)
  private val referenceCornerControl2 = BubbleTailPoint(-12.1883f, 0.0061f)
  private val referenceBottomJoin = BubbleTailPoint(-14.7700f, 0.0061f)

  fun resolve(curvature: Float): BubbleTailGeometry {
    val t = curvature.coerceIn(0f, 1f)
    val straightOuterStart = compact(referenceOuterStart)
    val straightTip = compact(referenceTip)
    val straightNotch = compact(referenceNotch)
    val straightBottomJoin = compact(referenceBottomJoin)
    return BubbleTailGeometry(
      outerStart = adjustable(straightOuterStart, referenceOuterStart, t),
      outerControl1 = adjustable(chord(straightOuterStart, straightTip, 1f / 3f), referenceOuterControl1, t),
      outerControl2 = adjustable(chord(straightOuterStart, straightTip, 2f / 3f), referenceOuterControl2, t),
      tip = adjustable(straightTip, referenceTip, t),
      innerControl1 = adjustable(chord(straightTip, straightNotch, 1f / 3f), referenceInnerControl1, t),
      innerControl2 = adjustable(chord(straightTip, straightNotch, 2f / 3f), referenceInnerControl2, t),
      notch = adjustable(straightNotch, referenceNotch, t),
      cornerControl1 = adjustable(
        chord(straightNotch, straightBottomJoin, 1f / 3f),
        referenceCornerControl1,
        t,
      ),
      cornerControl2 = adjustable(
        chord(straightNotch, straightBottomJoin, 2f / 3f),
        referenceCornerControl2,
        t,
      ),
      bottomJoin = adjustable(straightBottomJoin, referenceBottomJoin, t),
    )
  }

  fun frameWidthDp(radiusDp: Float): Float =
    (REFERENCE_INSIDE_EXTENT + REFERENCE_OUTSIDE_EXTENT) * scale(radiusDp) + (FRAME_PADDING * 2f)

  fun frameHeightDp(radiusDp: Float): Float =
    (REFERENCE_TOP_EXTENT + REFERENCE_BOTTOM_RESERVE) * scale(radiusDp) + (FRAME_PADDING * 2f)

  fun bodyCornerFromLeftDp(radiusDp: Float, isMe: Boolean): Float =
    (if (isMe) REFERENCE_INSIDE_EXTENT else REFERENCE_OUTSIDE_EXTENT) * scale(radiusDp) + FRAME_PADDING

  fun bodyCornerFromTopDp(radiusDp: Float): Float =
    REFERENCE_TOP_EXTENT * scale(radiusDp) + FRAME_PADDING

  fun outsideOverhangDp(radiusDp: Float): Float =
    REFERENCE_OUTSIDE_EXTENT * scale(radiusDp) + FRAME_PADDING

  fun bottomOverhangDp(radiusDp: Float): Float =
    REFERENCE_BOTTOM_RESERVE * scale(radiusDp) + FRAME_PADDING

  private fun scale(radiusDp: Float): Float = radiusDp.coerceAtLeast(0f) / 18f

  private fun compact(point: BubbleTailPoint): BubbleTailPoint =
    BubbleTailPoint(point.x * COMPACT_SCALE, point.y * COMPACT_SCALE)

  private fun chord(start: BubbleTailPoint, end: BubbleTailPoint, fraction: Float): BubbleTailPoint =
    BubbleTailPoint(
      start.x + (end.x - start.x) * fraction,
      start.y + (end.y - start.y) * fraction,
    )

  private fun adjustable(
    straight: BubbleTailPoint,
    reference: BubbleTailPoint,
    curvature: Float,
  ): BubbleTailPoint {
    if (curvature >= 0.999999f) return reference
    return BubbleTailPoint(
      straight.x + (reference.x - straight.x) * curvature,
      straight.y + (reference.y - straight.y) * curvature,
    )
  }
}

internal class BubbleTailView(context: Context) : View(context) {

  private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(255, 106, 79, 207)
  }
  private val path = Path()
  private var isMe = true
  private var cornerRadiusDp = 18f
  private var curvature = 1f

  fun configure(
    isMe: Boolean,
    color: Int,
    visible: Boolean,
    cornerRadiusDp: Float = 18f,
    curvature: Float = 1f,
  ) {
    this.isMe = isMe
    this.cornerRadiusDp = cornerRadiusDp.coerceAtLeast(0f)
    this.curvature = curvature.coerceIn(0f, 1f)
    paint.color = color
    rotation = 0f
    scaleX = 1f
    visibility = if (visible) View.VISIBLE else View.GONE
    invalidate()
  }

  override fun onDraw(canvas: Canvas) {
    if (visibility != View.VISIBLE) return
    val geometry = BubbleTailGeometrySource.resolve(curvature)
    val density = resources.displayMetrics.density
    val pointScale = density * (cornerRadiusDp / 18f)
    val originX = density * BubbleTailGeometrySource.bodyCornerFromLeftDp(cornerRadiusDp, isMe)
    val originY = density * BubbleTailGeometrySource.bodyCornerFromTopDp(cornerRadiusDp)
    val direction = if (isMe) 1f else -1f
    fun x(point: BubbleTailPoint): Float = originX + direction * point.x * pointScale
    fun y(point: BubbleTailPoint): Float = originY + point.y * pointScale

    path.reset()
    path.moveTo(x(geometry.outerStart), y(geometry.outerStart))
    path.cubicTo(
      x(geometry.outerControl1), y(geometry.outerControl1),
      x(geometry.outerControl2), y(geometry.outerControl2),
      x(geometry.tip), y(geometry.tip),
    )
    path.cubicTo(
      x(geometry.innerControl1), y(geometry.innerControl1),
      x(geometry.innerControl2), y(geometry.innerControl2),
      x(geometry.notch), y(geometry.notch),
    )
    path.cubicTo(
      x(geometry.cornerControl1), y(geometry.cornerControl1),
      x(geometry.cornerControl2), y(geometry.cornerControl2),
      x(geometry.bottomJoin), y(geometry.bottomJoin),
    )
    path.close()
    canvas.drawPath(path, paint)
  }
}

internal class BubbleStatusIndicatorView(context: Context) : View(context) {
  private var status: String? = null
  private var baseColor: Int = Color.WHITE
  private var rotationDegrees = 0f
  private var glyphAlpha = 1f
  private var glyphScale = 1f
  private var pendingAnimator: ValueAnimator? = null
  private var transitionAnimator: ValueAnimator? = null
  private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeCap = Paint.Cap.ROUND
  }
  private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
  }
  private val arcRect = RectF()
  private val path = Path()

  fun bind(rawStatus: String?, color: Int) {
    val normalized = rawStatus?.trim()?.lowercase()
    if (status == normalized && baseColor == color) return
    val statusChanged = status != normalized
    status = normalized
    baseColor = color
    if (normalized == "pending" || normalized == "sending") {
      startPendingAnimator()
    } else {
      stopPendingAnimator()
    }
    if (statusChanged && normalized != null) {
      startTransitionAnimator()
    }
    requestLayout()
    invalidate()
  }

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val w = resolveSize(dp(20), widthMeasureSpec)
    val h = resolveSize(dp(14), heightMeasureSpec)
    setMeasuredDimension(w, h)
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val normalized = status ?: return
    if (width <= 0 || height <= 0) return
    val tintColor =
      when (normalized) {
        "read" -> Color.argb(255, 0, 163, 255)
        "error" -> Color.argb(255, 255, 122, 122)
        else -> baseColor
      }
    strokePaint.color = tintColor
    fillPaint.color = tintColor
    strokePaint.strokeWidth =
      dpF(
        when (normalized) {
          "error" -> 1.8f
          "delivered", "read" -> 1.25f
          else -> 1.35f
        },
      )
    strokePaint.alpha = (255f * glyphAlpha).roundToInt().coerceIn(0, 255)
    fillPaint.alpha = (255f * glyphAlpha).roundToInt().coerceIn(0, 255)

    val cx = width - dpF(9.8f)
    val cy = height * 0.5f
    canvas.save()
    canvas.scale(glyphScale, glyphScale, cx, cy)

    when (normalized) {
      "pending", "sending" -> drawPending(canvas)
      "sent" -> drawCheck(canvas, second = false)
      "delivered", "read" -> drawCheck(canvas, second = true)
      "error" -> drawError(canvas)
    }
    canvas.restore()
    strokePaint.alpha = 255
    fillPaint.alpha = 255
  }

  override fun onDetachedFromWindow() {
    stopPendingAnimator()
    transitionAnimator?.cancel()
    transitionAnimator = null
    super.onDetachedFromWindow()
  }

  private fun drawPending(canvas: Canvas) {
    val side = min(width.toFloat(), height.toFloat()) - dpF(4f)
    if (side <= 0f) return
    val cx = width - dpF(9.8f)
    val cy = height * 0.5f
    val radius = side * 0.46f
    arcRect.set(cx - radius, cy - radius, cx + radius, cy + radius)
    strokePaint.alpha = 148
    canvas.drawOval(arcRect, strokePaint)
    strokePaint.alpha = (255f * glyphAlpha).roundToInt().coerceIn(0, 255)
    canvas.drawLine(cx, cy, cx + radius * 0.32f, cy, strokePaint)
    canvas.save()
    canvas.rotate(rotationDegrees, cx, cy)
    canvas.drawLine(cx, cy, cx, cy - radius * 0.58f, strokePaint)
    canvas.restore()
  }

  private fun drawCheck(canvas: Canvas, second: Boolean) {
    val scale = dpF(0.63f)
    val baseX = width - (24f * scale) - dpF(1.0f)
    val baseY = (height - (24f * scale)) * 0.5f
    if (second) {
      path.reset()
      path.moveTo(baseX + 4f * scale, baseY + 12.9f * scale)
      path.lineTo(baseX + 7.14286f * scale, baseY + 16.5f * scale)
      path.lineTo(baseX + 15f * scale, baseY + 7.5f * scale)
      canvas.drawPath(path, strokePaint)
      path.reset()
      path.moveTo(baseX + 20f * scale, baseY + 7.5625f * scale)
      path.lineTo(baseX + 11.4283f * scale, baseY + 16.5625f * scale)
      path.lineTo(baseX + 11f * scale, baseY + 16f * scale)
      canvas.drawPath(path, strokePaint)
    } else {
      path.reset()
      path.moveTo(baseX + 4f * scale, baseY + 12f * scale)
      path.lineTo(baseX + 8.94975f * scale, baseY + 16.9497f * scale)
      path.lineTo(baseX + 19.5572f * scale, baseY + 6.34326f * scale)
      canvas.drawPath(path, strokePaint)
    }
  }

  private fun drawError(canvas: Canvas) {
    val cx = width - dpF(7.5f)
    val top = dpF(2.8f)
    val bottom = height - dpF(5f)
    canvas.drawLine(cx, top, cx, bottom, strokePaint)
    canvas.drawCircle(cx, height - dpF(2.3f), dpF(1.25f), fillPaint)
  }

  private fun startPendingAnimator() {
    if (pendingAnimator != null) return
    pendingAnimator =
      ValueAnimator.ofFloat(0f, 360f).apply {
        duration = 1050L
        repeatCount = ValueAnimator.INFINITE
        interpolator = LinearInterpolator()
        addUpdateListener {
          rotationDegrees = it.animatedValue as Float
          invalidate()
        }
        start()
      }
  }

  private fun startTransitionAnimator() {
    transitionAnimator?.cancel()
    transitionAnimator =
      ValueAnimator.ofFloat(0f, 1f).apply {
        duration = 150L
        interpolator = AccelerateDecelerateInterpolator()
        addUpdateListener {
          val t = it.animatedValue as Float
          glyphAlpha = 0.58f + (0.42f * t)
          glyphScale = 0.88f + (0.12f * t)
          invalidate()
        }
        start()
      }
  }

  private fun stopPendingAnimator() {
    pendingAnimator?.cancel()
    pendingAnimator = null
    rotationDegrees = 0f
  }

  private fun dp(value: Int): Int =
    android.util.TypedValue.applyDimension(
      android.util.TypedValue.COMPLEX_UNIT_DIP,
      value.toFloat(),
      context.resources.displayMetrics,
    ).toInt()

  private fun dpF(value: Float): Float =
    android.util.TypedValue.applyDimension(
      android.util.TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )
}

internal class BubbleRetryButtonView(context: Context) : View(context) {
  private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(34, 255, 122, 122)
  }
  private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeCap = Paint.Cap.ROUND
    strokeJoin = Paint.Join.ROUND
    strokeWidth = dpF(1.8f)
    color = Color.argb(255, 255, 122, 122)
  }
  private val arcRect = RectF()
  private val arrowPath = Path()

  init {
    isClickable = true
    isFocusable = true
  }

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val size = dp(28)
    setMeasuredDimension(resolveSize(size, widthMeasureSpec), resolveSize(size, heightMeasureSpec))
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val cx = width * 0.5f
    val cy = height * 0.5f
    val radius = min(width, height) * 0.5f - dpF(1f)
    canvas.drawCircle(cx, cy, radius, ringPaint)

    val iconRadius = radius - dpF(7f)
    arcRect.set(cx - iconRadius, cy - iconRadius, cx + iconRadius, cy + iconRadius)
    canvas.drawArc(arcRect, 35f, 280f, false, iconPaint)

    val angle = Math.toRadians(35.0)
    val tipX = cx + kotlin.math.cos(angle).toFloat() * iconRadius
    val tipY = cy + kotlin.math.sin(angle).toFloat() * iconRadius
    arrowPath.reset()
    arrowPath.moveTo(tipX, tipY)
    arrowPath.lineTo(tipX - dpF(4.2f), tipY - dpF(0.5f))
    arrowPath.moveTo(tipX, tipY)
    arrowPath.lineTo(tipX - dpF(0.4f), tipY + dpF(4.2f))
    canvas.drawPath(arrowPath, iconPaint)
  }

  private fun dp(value: Int): Int =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value.toFloat(),
      context.resources.displayMetrics,
    ).toInt()

  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )
}

internal class VoicePlayProgressView(context: Context) : View(context) {
  companion object {
    private const val BUTTON_SIZE_DP = 44f
    private const val PLAYBACK_ICON_SIZE_DP = 16f
    private const val DOWNLOAD_ICON_SIZE_DP = 16f
    private const val UPLOAD_ICON_SIZE_DP = 14f
    private const val MINIMUM_UPLOAD_PROGRESS = 0.027f
    private const val UPLOAD_PROGRESS_DURATION_MS = 200L
    private const val UPLOAD_ROTATION_DURATION_MS = 1570L
  }

  private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(245, 255, 255, 255)
  }
  private val ringProgressPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeCap = Paint.Cap.ROUND
    strokeWidth = dpF(2.4f)
    color = Color.WHITE
  }
  private val fluidPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(64, 255, 255, 255)
  }
  private var iconTintColor: Int = Color.BLUE
  private var fluidColor: Int = Color.argb(64, 255, 255, 255)
  private val playDrawable = context.getDrawable(R.drawable.ic_voice_play)?.mutate()
  private val pauseDrawable = context.getDrawable(R.drawable.ic_voice_pause)?.mutate()
  private val cancelDrawable = context.getDrawable(R.drawable.ic_voice_cancel)?.mutate()
  private val downloadDrawable = context.getDrawable(R.drawable.ic_voice_download)?.mutate()
  private val arcRect = RectF()
  private var isPlaying = false
  private var isUploading = false
  private var needsDownload = false
  private var isDownloading = false
  private var uploadProgress: Float? = null
  private var lastResolvedUploadProgress: Float? = null
  private var downloadProgress: Float? = null
  private var lastResolvedDownloadProgress: Float? = null
  private var displayedUploadProgress = 0f
  private var uploadRotationDegrees = 0f
  private var playbackLevel = 0f
  private var playbackStartedAtMs = 0L
  private var progressAnimator: ValueAnimator? = null
  private var rotationAnimator: ValueAnimator? = null

  init {
    isClickable = true
    isFocusable = true
  }

  fun applyStyle(fillColor: Int, iconTint: Int, ringTint: Int) {
    fillPaint.color = fillColor
    iconTintColor = iconTint
    ringProgressPaint.color = ringTint
    fluidColor = withAlpha(ringTint, 0.35f)
    invalidate()
  }

  fun setPlaybackState(isPlaying: Boolean, progress: Float, level: Float = 0f) {
    if (isUploading || isDownloading || needsDownload) return
    val normalizedLevel = level.coerceIn(0f, 1f)
    val levelChanged = kotlin.math.abs(playbackLevel - normalizedLevel) > 0.01f
    if (this.isPlaying == isPlaying && !levelChanged) return
    if (isPlaying && !this.isPlaying) {
      playbackStartedAtMs = SystemClock.uptimeMillis()
    } else if (!isPlaying) {
      playbackStartedAtMs = 0L
    }
    this.isPlaying = isPlaying
    playbackLevel = if (isPlaying) normalizedLevel else 0f
    invalidate()
  }

  fun setUploadState(isUploading: Boolean, progress: Float?) {
    if (isUploading) {
      needsDownload = false
      isDownloading = false
      downloadProgress = null
      lastResolvedDownloadProgress = null
    }
    val resolvedProgress =
      if (isUploading) {
        when {
          progress != null && progress.isFinite() -> {
            progress.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f).also { lastResolvedUploadProgress = it }
          }
          lastResolvedUploadProgress != null -> lastResolvedUploadProgress
          else -> MINIMUM_UPLOAD_PROGRESS.also { lastResolvedUploadProgress = it }
        }
      } else {
        lastResolvedUploadProgress = null
        null
      }

    if (this.isUploading == isUploading && uploadProgress == resolvedProgress) return
    this.isUploading = isUploading
    uploadProgress = resolvedProgress
    updateUploadVisualState()
  }

  fun setDownloadState(needsDownload: Boolean, isDownloading: Boolean, progress: Float?) {
    if (isUploading) return

    val resolvedProgress =
      if (isDownloading) {
        when {
          progress != null && progress.isFinite() -> {
            progress.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f).also { lastResolvedDownloadProgress = it }
          }
          lastResolvedDownloadProgress != null -> lastResolvedDownloadProgress
          else -> MINIMUM_UPLOAD_PROGRESS.also { lastResolvedDownloadProgress = it }
        }
      } else {
        lastResolvedDownloadProgress = null
        null
      }

    if (
      this.needsDownload == needsDownload &&
        this.isDownloading == isDownloading &&
        downloadProgress == resolvedProgress
    ) {
      return
    }

    this.needsDownload = needsDownload
    this.isDownloading = isDownloading
    downloadProgress = resolvedProgress
    if (!needsDownload && !isDownloading) {
      stopUploadAnimations(resetProgress = true)
      invalidate()
      return
    }
    if (isDownloading) {
      updateUploadVisualState()
    } else {
      stopUploadAnimations(resetProgress = true)
      invalidate()
    }
  }

  fun preferredButtonSizePx(): Int = dpF(BUTTON_SIZE_DP).roundToInt()

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val desiredSize = preferredButtonSizePx()
    val resolvedWidth = resolveSize(desiredSize, widthMeasureSpec)
    val resolvedHeight = resolveSize(desiredSize, heightMeasureSpec)
    setMeasuredDimension(resolvedWidth, resolvedHeight)
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    if (width <= 0 || height <= 0) return
    val cx = width * 0.5f
    val cy = height * 0.5f
    val outerRadius = kotlin.math.min(cx, cy)
    val fillInset = dpF(3f)
    val fillRadius = (outerRadius - fillInset).coerceAtLeast(kotlin.math.min(dpF(14f), outerRadius))

    if (!isUploading && !isDownloading && !needsDownload && (isPlaying || playbackLevel > 0.01f)) {
      drawFluidVisualizer(canvas, cx, cy, outerRadius)
      postInvalidateOnAnimation()
    }

    canvas.drawCircle(cx, cy, fillRadius, fillPaint)

    if (isUploading || isDownloading) {
      val ringRadius = kotlin.math.max(dpF(4f), fillRadius + dpF(1.8f))
      arcRect.set(cx - ringRadius, cy - ringRadius, cx + ringRadius, cy + ringRadius)
      canvas.save()
      canvas.rotate(uploadRotationDegrees, cx, cy)
      canvas.drawArc(
        arcRect,
        -90f,
        displayedUploadProgress.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f) * 360f,
        false,
        ringProgressPaint,
      )
      canvas.restore()
    }

    val icon =
      when {
        isUploading || isDownloading -> cancelDrawable
        needsDownload -> downloadDrawable
        isPlaying -> pauseDrawable
        else -> playDrawable
      }
    if (icon != null) {
      val iconSize =
        kotlin.math.min(
          (fillRadius * 2f) - dpF(9f),
          when {
            isUploading || isDownloading -> dpF(UPLOAD_ICON_SIZE_DP)
            needsDownload -> dpF(DOWNLOAD_ICON_SIZE_DP)
            else -> dpF(PLAYBACK_ICON_SIZE_DP)
          },
        )
      val left = ((width - iconSize) * 0.5f).roundToInt()
      val top = ((height - iconSize) * 0.5f).roundToInt()
      val right = (left + iconSize).roundToInt()
      val bottom = (top + iconSize).roundToInt()
      icon.setBounds(left, top, right, bottom)
      icon.setTint(iconTintColor)
      icon.draw(canvas)
    }
  }

  override fun onDetachedFromWindow() {
    stopUploadAnimations(resetProgress = true)
    super.onDetachedFromWindow()
  }

  private fun updateUploadVisualState() {
    if (!isUploading && !isDownloading) {
      stopUploadAnimations(resetProgress = true)
      invalidate()
      return
    }
    ensureRotationAnimator()
    animateUploadProgressTo(
      when {
        isUploading -> uploadProgress ?: MINIMUM_UPLOAD_PROGRESS
        else -> downloadProgress ?: MINIMUM_UPLOAD_PROGRESS
      },
    )
  }

  private fun animateUploadProgressTo(target: Float) {
    val clampedTarget = target.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f)
    progressAnimator?.cancel()
    val start = displayedUploadProgress.takeIf { it > 0f } ?: clampedTarget
    progressAnimator =
      ValueAnimator.ofFloat(start, clampedTarget).apply {
        duration = UPLOAD_PROGRESS_DURATION_MS
        interpolator = AccelerateDecelerateInterpolator()
        addUpdateListener { animator ->
          displayedUploadProgress = (animator.animatedValue as Float).coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f)
          invalidate()
        }
        start()
      }
  }

  private fun ensureRotationAnimator() {
    if (rotationAnimator?.isRunning == true) return
    rotationAnimator =
      ValueAnimator.ofFloat(0f, 360f).apply {
        duration = UPLOAD_ROTATION_DURATION_MS
        repeatCount = ValueAnimator.INFINITE
        interpolator = LinearInterpolator()
        addUpdateListener { animator ->
          uploadRotationDegrees = animator.animatedValue as Float
          invalidate()
        }
        start()
      }
  }

  private fun stopUploadAnimations(resetProgress: Boolean) {
    progressAnimator?.cancel()
    progressAnimator = null
    rotationAnimator?.cancel()
    rotationAnimator = null
    uploadRotationDegrees = 0f
    playbackLevel = 0f
    playbackStartedAtMs = 0L
    if (resetProgress) {
      displayedUploadProgress = 0f
    }
  }

  private fun drawFluidVisualizer(canvas: Canvas, cx: Float, cy: Float, baseRadius: Float) {
    val elapsedSeconds =
      if (playbackStartedAtMs > 0L) {
        (SystemClock.uptimeMillis() - playbackStartedAtMs) / 1000f
      } else {
        0f
      }

    for (index in 0 until 3) {
      val layerIndex = (index + 1).toFloat()
      val idlePulse = (kotlin.math.sin((elapsedSeconds * 2f) + (index * 2f)) * 0.04f).toFloat()
      val activePush = playbackLevel * 0.4f * layerIndex
      val scale = (1f + idlePulse + activePush).coerceAtLeast(0.92f)
      val opacity = ((1f - ((scale - 1f) * 1.5f)).coerceIn(0f, 1f)) * 0.6f
      fluidPaint.color = withMultipliedAlpha(fluidColor, opacity)
      canvas.drawCircle(cx, cy, baseRadius * scale, fluidPaint)
    }
  }

  private fun withMultipliedAlpha(color: Int, factor: Float): Int {
    val alpha = (Color.alpha(color) * factor.coerceIn(0f, 1f)).roundToInt().coerceIn(0, 255)
    return Color.argb(alpha, Color.red(color), Color.green(color), Color.blue(color))
  }

  private fun withAlpha(color: Int, alpha: Float): Int {
    val resolvedAlpha = (alpha.coerceIn(0f, 1f) * 255f).roundToInt().coerceIn(0, 255)
    return Color.argb(resolvedAlpha, Color.red(color), Color.green(color), Color.blue(color))
  }

  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )
}

internal class BubbleUploadProgressView(context: Context) : View(context) {
  companion object {
    private const val MINIMUM_UPLOAD_PROGRESS = 0.027f
    private const val PROGRESS_DURATION_MS = 200L
    private const val ROTATION_DURATION_MS = 1570L
  }

  private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(148, 0, 0, 0)
  }
  private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeCap = Paint.Cap.ROUND
    strokeWidth = dpF(3f)
    color = Color.argb(72, 255, 255, 255)
  }
  private val progressPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeCap = Paint.Cap.ROUND
    strokeWidth = dpF(3f)
    color = Color.WHITE
  }
  private val cancelDrawable = context.getDrawable(R.drawable.ic_voice_cancel)?.mutate()
  private val arcRect = RectF()
  private var isUploading = false
  private var needsDownload = false
  private var isDownloading = false
  private var uploadProgress: Float? = null
  private var lastResolvedUploadProgress: Float? = null
  private var downloadProgress: Float? = null
  private var lastResolvedDownloadProgress: Float? = null
  private var displayedProgress = 0f
  private var rotationDegrees = 0f
  private var progressAnimator: ValueAnimator? = null
  private var rotationAnimator: ValueAnimator? = null

  fun setUploadState(isUploading: Boolean, progress: Float?) {
    if (isUploading) {
      needsDownload = false
      isDownloading = false
      downloadProgress = null
      lastResolvedDownloadProgress = null
    }
    val resolvedProgress =
      if (isUploading) {
        when {
          progress != null && progress.isFinite() -> {
            progress.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f).also { lastResolvedUploadProgress = it }
          }
          lastResolvedUploadProgress != null -> lastResolvedUploadProgress
          else -> MINIMUM_UPLOAD_PROGRESS.also { lastResolvedUploadProgress = it }
        }
      } else {
        lastResolvedUploadProgress = null
        null
      }
    if (this.isUploading == isUploading && uploadProgress == resolvedProgress) return
    this.isUploading = isUploading
    uploadProgress = resolvedProgress
    updateVisualState()
  }

  fun setDownloadState(needsDownload: Boolean, isDownloading: Boolean, progress: Float?) {
    if (isUploading) return
    val resolvedProgress =
      if (isDownloading) {
        when {
          progress != null && progress.isFinite() -> {
            progress.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f).also { lastResolvedDownloadProgress = it }
          }
          lastResolvedDownloadProgress != null -> lastResolvedDownloadProgress
          else -> MINIMUM_UPLOAD_PROGRESS.also { lastResolvedDownloadProgress = it }
        }
      } else {
        lastResolvedDownloadProgress = null
        null
      }
    if (
      this.needsDownload == needsDownload &&
        this.isDownloading == isDownloading &&
        downloadProgress == resolvedProgress
    ) {
      return
    }
    this.needsDownload = needsDownload
    this.isDownloading = isDownloading
    downloadProgress = resolvedProgress
    updateVisualState()
  }

  override fun onDetachedFromWindow() {
    stopAnimations(resetProgress = true)
    super.onDetachedFromWindow()
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    val shouldDrawDownload = needsDownload && isDownloading
    if ((!isUploading && !shouldDrawDownload) || width <= 0 || height <= 0) return

    val cx = width * 0.5f
    val cy = height * 0.5f
    val outerRadius = kotlin.math.min(cx, cy)
    val fillRadius = (outerRadius - dpF(5f)).coerceAtLeast(dpF(8f))
    canvas.drawCircle(cx, cy, fillRadius, fillPaint)

    val ringRadius = kotlin.math.max(dpF(6f), fillRadius + dpF(2f))
    arcRect.set(cx - ringRadius, cy - ringRadius, cx + ringRadius, cy + ringRadius)
    canvas.drawArc(arcRect, 0f, 360f, false, trackPaint)
    canvas.save()
    canvas.rotate(rotationDegrees, cx, cy)
    canvas.drawArc(
      arcRect,
      -90f,
      displayedProgress.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f) * 360f,
      false,
      progressPaint,
    )
    canvas.restore()

    if (isUploading) {
      val icon = cancelDrawable ?: return
      val iconSize = kotlin.math.min(dpF(16f), fillRadius * 1.2f)
      val left = ((width - iconSize) * 0.5f).roundToInt()
      val top = ((height - iconSize) * 0.5f).roundToInt()
      icon.setBounds(left, top, (left + iconSize).roundToInt(), (top + iconSize).roundToInt())
      icon.setTint(Color.WHITE)
      icon.draw(canvas)
    }
  }

  private fun updateVisualState() {
    val shouldAnimate = isUploading || (needsDownload && isDownloading)
    if (!shouldAnimate) {
      stopAnimations(resetProgress = true)
      invalidate()
      return
    }
    ensureRotationAnimator()
    animateProgressTo(
      when {
        isUploading -> uploadProgress ?: MINIMUM_UPLOAD_PROGRESS
        else -> downloadProgress ?: MINIMUM_UPLOAD_PROGRESS
      },
    )
  }

  private fun animateProgressTo(target: Float) {
    val clampedTarget = target.coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f)
    progressAnimator?.cancel()
    val start = displayedProgress.takeIf { it > 0f } ?: clampedTarget
    progressAnimator =
      ValueAnimator.ofFloat(start, clampedTarget).apply {
        duration = PROGRESS_DURATION_MS
        interpolator = AccelerateDecelerateInterpolator()
        addUpdateListener { animator ->
          displayedProgress = (animator.animatedValue as Float).coerceIn(MINIMUM_UPLOAD_PROGRESS, 1f)
          invalidate()
        }
        start()
      }
  }

  private fun ensureRotationAnimator() {
    if (rotationAnimator?.isRunning == true) return
    rotationAnimator =
      ValueAnimator.ofFloat(0f, 360f).apply {
        duration = ROTATION_DURATION_MS
        repeatCount = ValueAnimator.INFINITE
        interpolator = LinearInterpolator()
        addUpdateListener { animator ->
          rotationDegrees = animator.animatedValue as Float
          invalidate()
        }
        start()
      }
  }

  private fun stopAnimations(resetProgress: Boolean) {
    progressAnimator?.cancel()
    progressAnimator = null
    rotationAnimator?.cancel()
    rotationAnimator = null
    rotationDegrees = 0f
    if (resetProgress) {
      displayedProgress = 0f
    }
  }

  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )
}

internal class VoiceUploadProgressView(context: Context) : View(context) {
  private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.STROKE
    strokeWidth = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 2.5f, context.resources.displayMetrics)
    strokeCap = Paint.Cap.ROUND
    color = Color.WHITE
  }
  private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(85, 0, 0, 0)
  }
  private val rect = RectF()
  var progress: Float = 0f
    set(value) {
      val clamped = value.coerceIn(0f, 1f)
      if (field != clamped) {
        field = clamped
        invalidate()
      }
    }

  override fun onDraw(canvas: Canvas) {
    if (progress <= 0f || progress >= 1f) return
    val cx = width / 2f
    val cy = height / 2f
    val radius = kotlin.math.min(cx, cy)
    canvas.drawCircle(cx, cy, radius, bgPaint)
    val pad = paint.strokeWidth / 2f + TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 2f, context.resources.displayMetrics)
    rect.set(pad, pad, width - pad, height - pad)
    val sweep = progress * 360f
    canvas.drawArc(rect, -90f, sweep, false, paint)
  }
}

internal class VoiceWaveformView(context: Context) : View(context) {
  companion object {
    private const val BAR_WIDTH_DP = 2f
    private const val BAR_SPACING_DP = 2f
    private const val WAVE_HEIGHT_DP = 20f
  }

  private val activePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.WHITE
  }
  private val inactivePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
    color = Color.argb(74, 255, 255, 255)
  }
  private val blendedPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
    style = Paint.Style.FILL
  }
  private var barCount = 40
  private var barEnvelope: FloatArray = makeDefaultEnvelope(barCount)
  private var rawSamples: List<Float>? = null
  private var playbackProgress = 0f

  override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
    val desiredHeight = dpF(WAVE_HEIGHT_DP).roundToInt()
    val desiredWidth = preferredContentWidth()
    val resolvedWidth = resolveSize(desiredWidth, widthMeasureSpec)
    val resolvedHeight = resolveSize(desiredHeight, heightMeasureSpec)
    setMeasuredDimension(resolvedWidth, resolvedHeight)
  }

  fun updatePlayback(progress: Float, level: Float, isPlaying: Boolean) {
    playbackProgress = progress.coerceIn(0f, 1f)
    invalidate()
  }

  fun setWaveform(samples: List<Float>?, duration: Double? = null) {
    rawSamples =
      samples
        ?.filter { it.isFinite() }
        ?.map { it.coerceIn(0f, 1f) }
        ?.takeIf { it.isNotEmpty() }
    rebuildEnvelope()
    invalidate()
    requestLayout()
  }

  fun preferredContentWidth(maxWidthPx: Int? = null): Int {
    if (maxWidthPx != null) return maxWidthPx.coerceAtLeast(1)
    val desired =
      ((barCount * dpF(BAR_WIDTH_DP)) + ((barCount - 1).coerceAtLeast(0) * dpF(BAR_SPACING_DP)))
        .roundToInt()
    return desired.coerceAtLeast(1)
  }

  fun preferredContentHeightPx(): Int = dpF(WAVE_HEIGHT_DP).roundToInt()

  fun setColors(activeColor: Int, inactiveColor: Int) {
    if (activePaint.color == activeColor && inactivePaint.color == inactiveColor) return
    activePaint.color = activeColor
    inactivePaint.color = inactiveColor
    invalidate()
  }

  override fun onDraw(canvas: Canvas) {
    super.onDraw(canvas)
    if (width <= 0 || height <= 0) return
    val expectedBarWidth = dpF(BAR_WIDTH_DP)
    val expectedSpacing = dpF(BAR_SPACING_DP)
    val newCount =
      kotlin.math.max(1, (width.toFloat() / (expectedBarWidth + expectedSpacing)).toInt())
    if (newCount != barCount) {
      barCount = newCount
      rebuildEnvelope()
    }

    val barWidth = expectedBarWidth
    val spacing = expectedSpacing
    val minHeight = dpF(2f)
    val peakHeight = kotlin.math.max(minHeight, kotlin.math.min(height.toFloat(), dpF(18f)))
    val progressX = playbackProgress.coerceIn(0f, 1f) * width.toFloat()
    var x = 0f
    for (index in 0 until barCount) {
      val amplitude = barEnvelope.getOrElse(index) { 0f }.coerceIn(0f, 1f)
      val barHeight = kotlin.math.max(minHeight, peakHeight * amplitude)
      val barStart = x
      val barEnd = x + barWidth
      val fillFraction =
        ((progressX - barStart) / kotlin.math.max(1f, barEnd - barStart)).coerceIn(0f, 1f)
      val renderedHeight = kotlin.math.max(1f, kotlin.math.floor(barHeight))
      val y = kotlin.math.floor(height - renderedHeight)
      val paint =
        when {
          fillFraction <= 0f -> inactivePaint
          fillFraction >= 1f -> activePaint
          else -> blendedPaint.apply {
            color = blend(inactivePaint.color, activePaint.color, fillFraction)
          }
        }
      canvas.drawRoundRect(
        x,
        y,
        x + barWidth,
        y + renderedHeight,
        barWidth * 0.5f,
        barWidth * 0.5f,
        paint,
      )
      x += barWidth + spacing
    }
  }

  private fun rebuildEnvelope() {
    if (barCount <= 0) return
    val normalized = rawSamples.orEmpty()
    if (normalized.isEmpty()) {
      barEnvelope = makeDefaultEnvelope(barCount)
      return
    }

    val resampled = FloatArray(barCount)
    for (index in normalized.indices) {
      val bucketIndex = kotlin.math.min(barCount - 1, (index * barCount) / kotlin.math.max(1, normalized.size))
      resampled[bucketIndex] = kotlin.math.max(resampled[bucketIndex], normalized[index])
    }

    val maxSample = resampled.maxOrNull() ?: 0f
    if (maxSample <= 0.0001f) {
      barEnvelope = FloatArray(barCount)
      return
    }

    for (index in resampled.indices) {
      resampled[index] = (resampled[index] / maxSample).coerceIn(0f, 1f)
    }

    if (resampled.all { it <= 0.001f }) {
      barEnvelope = FloatArray(barCount)
      return
    }

    barEnvelope = resampled
  }

  private fun makeDefaultEnvelope(count: Int): FloatArray {
    if (count <= 0) return floatArrayOf()
    val template = floatArrayOf(0.64f, 0.49f, 0.73f, 0.56f, 0.42f, 0.78f, 0.58f, 0.28f, 0.33f, 0.67f)
    val out = FloatArray(count)
    for (i in 0 until count) {
      out[i] = template[i % template.size]
    }
    return out
  }

  private fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )

  private fun blend(from: Int, to: Int, amount: Float): Int {
    val t = amount.coerceIn(0f, 1f)
    val inv = 1f - t
    return Color.argb(
      (Color.alpha(from) * inv + Color.alpha(to) * t).toInt(),
      (Color.red(from) * inv + Color.red(to) * t).toInt(),
      (Color.green(from) * inv + Color.green(to) * t).toInt(),
      (Color.blue(from) * inv + Color.blue(to) * t).toInt(),
    )
  }
}

internal fun createNativeMessageRowViewHolder(context: Context): NativeRowViewHolder {
  fun dp(value: Int): Int =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value.toFloat(),
      context.resources.displayMetrics,
    ).toInt()

  fun dpF(value: Float): Float =
    TypedValue.applyDimension(
      TypedValue.COMPLEX_UNIT_DIP,
      value,
      context.resources.displayMetrics,
    )

  val root = FrameLayout(context).apply {
    layoutParams = RecyclerView.LayoutParams(
      RecyclerView.LayoutParams.MATCH_PARENT,
      RecyclerView.LayoutParams.WRAP_CONTENT,
    )
    clipChildren = false
    clipToPadding = false
    setPadding(dp(8), dp(1), dp(8), dp(1))
  }

  val bubble = FrameLayout(context).apply {
    layoutParams = FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    )
    clipChildren = false
    clipToPadding = false
    setPadding(dp(10), dp(7), dp(10), dp(7))
    minimumWidth = dp(26)
    alpha = 1f
  }

  val tail = BubbleTailView(context).apply {
    visibility = View.GONE
  }
  val selectionCircle = MessageSelectionCircleView(context).apply {
    visibility = View.GONE
  }

  val agentSender = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
    setTextColor(Color.argb(255, 125, 92, 225))
    setTypeface(Typeface.DEFAULT_BOLD)
    includeFontPadding = false
    visibility = View.GONE
    maxLines = 1
  }

  val replyPreview = FrameLayout(context).apply {
    visibility = View.GONE
    setPadding(dp(10), dp(6), dp(10), dp(6))
  }
  val replyAccent = View(context).apply {
    background = GradientDrawable().apply {
      cornerRadius = dpF(1.5f)
      setColor(Color.argb(210, 255, 255, 255))
    }
  }
  val replyTitle = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
    setTypeface(Typeface.DEFAULT_BOLD)
    includeFontPadding = false
    maxLines = 1
  }
  val replyText = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
    includeFontPadding = false
    maxLines = 1
    ellipsize = android.text.TextUtils.TruncateAt.END
  }

  val text = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
    setTextColor(Color.WHITE)
    setLineSpacing(0f, 1.1f)
    includeFontPadding = false
    maxWidth = (context.resources.displayMetrics.widthPixels * 0.85f).toInt()
  }

  val inlineAttachment = FrameLayout(context).apply {
    visibility = View.GONE
    background = GradientDrawable().apply {
      cornerRadius = dpF(12f)
      setColor(Color.argb(52, 0, 0, 0))
    }
    setPadding(dp(12), dp(8), dp(12), dp(8))
    minimumWidth = dp(170)
    isClickable = true
    isFocusable = true
  }
  val mediaPreview = FrameLayout(context).apply {
    visibility = View.GONE
    clipChildren = true
    clipToPadding = true
    background = GradientDrawable().apply {
      cornerRadius = dpF(12f)
      setColor(Color.argb(32, 0, 0, 0))
    }
    outlineProvider = ViewOutlineProvider.BACKGROUND
    clipToOutline = true
  }
  val mediaImage = ImageView(context).apply {
    scaleType = ImageView.ScaleType.CENTER_CROP
    adjustViewBounds = false
    setBackgroundColor(Color.argb(42, 0, 0, 0))
  }
  val mediaPlayBadge = TextView(context).apply {
    this.text = "\u25B6"
    setTextColor(Color.WHITE)
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
    gravity = Gravity.CENTER
    background = GradientDrawable().apply {
      shape = GradientDrawable.OVAL
      setColor(Color.argb(71, 0, 0, 0))
    }
    visibility = View.GONE
  }
  val mediaDurationBadge = TextView(context).apply {
    setTextColor(Color.WHITE)
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
    setTypeface(Typeface.MONOSPACE, Typeface.BOLD)
    includeFontPadding = false
    gravity = Gravity.CENTER
    setPadding(dp(8), dp(4), dp(8), dp(4))
    background = GradientDrawable().apply {
      cornerRadius = dpF(11f)
      setColor(Color.argb(143, 0, 0, 0))
    }
    visibility = View.GONE
  }
  val mediaTransferOverlay = FrameLayout(context).apply {
    visibility = View.GONE
    clipChildren = false
    clipToPadding = false
    setBackgroundColor(Color.TRANSPARENT)
    isClickable = true
    isFocusable = true
  }
  val mediaTransferRing = BubbleUploadProgressView(context)
  val mediaTransferSize = TextView(context).apply {
    setTextColor(Color.WHITE)
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
    setTypeface(Typeface.MONOSPACE, Typeface.BOLD)
    includeFontPadding = false
    gravity = Gravity.CENTER
    setPadding(dp(8), dp(4), dp(8), dp(4))
    background = GradientDrawable().apply {
      cornerRadius = dpF(10f)
      setColor(Color.argb(124, 10, 14, 20))
    }
    visibility = View.GONE
  }
  val inlineAttachmentIcon = TextView(context).apply {
    setText("\uD83D\uDCC4")
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
    includeFontPadding = false
  }
  val inlineAttachmentTitle = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
    setTypeface(Typeface.DEFAULT_BOLD)
    includeFontPadding = false
    maxLines = 1
  }
  val inlineAttachmentSubtitle = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
    includeFontPadding = false
    setText("Tap to open")
    maxLines = 1
  }
  inlineAttachment.addView(
    mediaPreview,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      FrameLayout.LayoutParams.MATCH_PARENT,
    ),
  )
  mediaPreview.addView(
    mediaImage,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      FrameLayout.LayoutParams.MATCH_PARENT,
    ),
  )
  mediaPreview.addView(
    mediaPlayBadge,
    FrameLayout.LayoutParams(dp(44), dp(44), Gravity.CENTER),
  )
  mediaPreview.addView(
    mediaDurationBadge,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.TOP or Gravity.START,
    ).apply {
      leftMargin = dp(8)
      topMargin = dp(8)
    },
  )
  mediaPreview.addView(
    mediaTransferOverlay,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      FrameLayout.LayoutParams.MATCH_PARENT,
    ),
  )
  mediaTransferOverlay.addView(
    mediaTransferRing,
    FrameLayout.LayoutParams(dp(44), dp(44), Gravity.CENTER),
  )
  mediaTransferOverlay.addView(
    mediaTransferSize,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM,
    ).apply {
      bottomMargin = dp(12)
    },
  )
  inlineAttachment.addView(
    inlineAttachmentIcon,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.START or Gravity.CENTER_VERTICAL,
    ),
  )
  inlineAttachment.addView(
    inlineAttachmentTitle,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.START or Gravity.TOP,
    ).apply {
      leftMargin = dp(24)
    },
  )
  inlineAttachment.addView(
    inlineAttachmentSubtitle,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.START or Gravity.BOTTOM,
    ).apply {
      leftMargin = dp(24)
    },
  )

  val voiceContainer = FrameLayout(context).apply {
    visibility = View.GONE
    alpha = 1f
  }

  val voiceButton = VoicePlayProgressView(context).apply {
    applyStyle(
      fillColor = Color.argb(245, 255, 255, 255),
      iconTint = Color.WHITE,
      ringTint = Color.argb(186, 255, 255, 255),
    )
  }

  val voiceWave = VoiceWaveformView(context)
  val voiceUploadProgress = VoiceUploadProgressView(context)

  val voiceDuration = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
    setTextColor(Color.argb(200, 255, 255, 255))
    gravity = Gravity.END or Gravity.CENTER_VERTICAL
    includeFontPadding = false
  }

  val time = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
    setTextColor(Color.argb(184, 255, 255, 255))
    gravity = Gravity.END
    includeFontPadding = false
  }

  val status = BubbleStatusIndicatorView(context).apply {
    visibility = View.GONE
  }
  val retryButton = BubbleRetryButtonView(context).apply {
    visibility = View.GONE
  }

  val day = TextView(context).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
    setTextColor(Color.argb(210, 236, 239, 255))
    gravity = Gravity.CENTER
    setPadding(dp(11), dp(4), dp(11), dp(4))
    visibility = View.GONE
  }

  bubble.addView(
    agentSender,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    ),
  )
  replyPreview.addView(
    replyAccent,
    FrameLayout.LayoutParams(dp(3), FrameLayout.LayoutParams.MATCH_PARENT, Gravity.START),
  )
  replyPreview.addView(
    replyTitle,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.START or Gravity.TOP,
    ).apply {
      leftMargin = dp(11)
    },
  )
  replyPreview.addView(
    replyText,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.MATCH_PARENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.START or Gravity.BOTTOM,
    ).apply {
      leftMargin = dp(11)
      topMargin = dp(16)
    },
  )
  bubble.addView(
    replyPreview,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      dp(42),
      Gravity.START or Gravity.TOP,
    ),
  )
  bubble.addView(
    text,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    ),
  )
  bubble.addView(
    inlineAttachment,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      dp(48),
    ).apply {
      gravity = Gravity.START or Gravity.TOP
    },
  )
  voiceContainer.addView(
    voiceButton,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
      gravity = Gravity.START or Gravity.CENTER_VERTICAL
    },
  )
  voiceContainer.addView(
    voiceUploadProgress,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
      gravity = Gravity.START or Gravity.CENTER_VERTICAL
    },
  )
  voiceContainer.addView(
    voiceWave,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
      gravity = Gravity.START or Gravity.TOP
    },
  )
  voiceContainer.addView(
    voiceDuration,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
      gravity = Gravity.START or Gravity.TOP
    },
  )
  bubble.addView(
    voiceContainer,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
      gravity = Gravity.START
    },
  )
  bubble.addView(
    time,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.END or Gravity.BOTTOM,
    ).apply {
      rightMargin = dp(0)
      bottomMargin = dp(0)
    },
  )
  bubble.addView(
    status,
    FrameLayout.LayoutParams(dp(16), dp(14), Gravity.END or Gravity.BOTTOM).apply {
      rightMargin = 0
      bottomMargin = 0
    },
  )
  root.addView(
    tail,
    FrameLayout.LayoutParams(
      dpF(BubbleTailGeometrySource.frameWidthDp(18f)).roundToInt(),
      dpF(BubbleTailGeometrySource.frameHeightDp(18f)).roundToInt(),
    ),
  )
  root.addView(bubble)
  root.addView(
    selectionCircle,
    FrameLayout.LayoutParams(dp(26), dp(26), Gravity.START or Gravity.CENTER_VERTICAL).apply {
      leftMargin = dp(6)
    },
  )
  root.addView(
    retryButton,
    FrameLayout.LayoutParams(dp(28), dp(28), Gravity.END or Gravity.BOTTOM).apply {
      rightMargin = dp(34)
      bottomMargin = dp(6)
    },
  )
  root.addView(
    day,
    FrameLayout.LayoutParams(
      FrameLayout.LayoutParams.WRAP_CONTENT,
      FrameLayout.LayoutParams.WRAP_CONTENT,
      Gravity.CENTER_HORIZONTAL,
    ),
  )

  return NativeRowViewHolder(
    root,
    bubble,
    tail,
    selectionCircle,
    replyPreview,
    replyTitle,
    replyText,
    text,
    inlineAttachment,
    mediaPreview,
    mediaImage,
    mediaPlayBadge,
    mediaDurationBadge,
    mediaTransferOverlay,
    mediaTransferRing,
    mediaTransferSize,
    inlineAttachmentTitle,
    inlineAttachmentSubtitle,
    voiceContainer,
    voiceButton,
    voiceWaveView = voiceWave,
    voiceUploadProgressView = voiceUploadProgress,
    voiceDurationView = voiceDuration,
    time,
    status,
    retryButton,
    day,
    agentSender,
  )
}

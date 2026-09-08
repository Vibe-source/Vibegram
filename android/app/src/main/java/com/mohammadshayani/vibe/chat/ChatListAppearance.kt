package com.mohammadshayani.vibe.chat

import android.graphics.Color
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

data class ChatListAppearance(
  val backgroundMode: String = "transparent",
  val wallpaperGradient: IntArray = intArrayOf(
    Color.argb(255, 26, 26, 46),
    Color.argb(255, 18, 18, 42),
  ),
  val wallpaperOpacity: Float = 1f,
  val wallpaperPatternGradient: IntArray = intArrayOf(),
  val wallpaperPatternLocations: FloatArray? = null,
  val wallpaperPatternOpacity: Float = 0f,
  val wallpaperMaskKey: String? = null,
  val bubbleMeGradient: IntArray = intArrayOf(
    Color.argb(255, 124, 92, 224),
    Color.argb(255, 106, 79, 207),
  ),
  val bubbleThemColor: Int = Color.argb(255, 43, 43, 74),
  val textColorMe: Int = Color.WHITE,
  val textColorThem: Int = Color.argb(255, 221, 221, 221),
  val timeColorMe: Int = Color.argb(184, 255, 255, 255),
  val timeColorThem: Int = Color.argb(128, 255, 255, 255),
  val dayTextColor: Int = Color.argb(210, 236, 239, 255),
  val dayBackgroundColor: Int = Color.argb(107, 20, 20, 34),
  val dayBorderColor: Int = Color.argb(41, 255, 255, 255),
  val messageTailCurvature: Float = 1f,
) {
  fun visualEquals(other: ChatListAppearance): Boolean {
    return backgroundMode == other.backgroundMode &&
      wallpaperGradient.contentEquals(other.wallpaperGradient) &&
      wallpaperOpacity == other.wallpaperOpacity &&
      wallpaperPatternGradient.contentEquals(other.wallpaperPatternGradient) &&
      floatArrayContentEquals(wallpaperPatternLocations, other.wallpaperPatternLocations) &&
      wallpaperPatternOpacity == other.wallpaperPatternOpacity &&
      wallpaperMaskKey == other.wallpaperMaskKey &&
      bubbleMeGradient.contentEquals(other.bubbleMeGradient) &&
      bubbleThemColor == other.bubbleThemColor &&
      textColorMe == other.textColorMe &&
      textColorThem == other.textColorThem &&
      timeColorMe == other.timeColorMe &&
      timeColorThem == other.timeColorThem &&
      dayTextColor == other.dayTextColor &&
      dayBackgroundColor == other.dayBackgroundColor &&
      dayBorderColor == other.dayBorderColor &&
      messageTailCurvature == other.messageTailCurvature
  }

  companion object {
    private val fallback = ChatListAppearance()

    fun from(raw: Map<String, Any?>?): ChatListAppearance {
      if (raw == null) return fallback

      nativePresetAppearance(raw, fallback)?.let { return it }

      val backgroundMode = raw["backgroundMode"] as? String ?: fallback.backgroundMode
      val wallpaperGradient = parseGradient(raw["wallpaperGradient"] as? List<*>, fallback.wallpaperGradient)
      val wallpaperPatternGradient =
        parseGradient(raw["wallpaperPatternGradient"] as? List<*>, fallback.wallpaperPatternGradient)
      val bubbleMeGradientRaw = parseGradient(raw["bubbleMeGradient"] as? List<*>, fallback.bubbleMeGradient)

      val isDarkApprox = isDarkColor(wallpaperGradient.firstOrNull() ?: fallback.wallpaperGradient.firstOrNull() ?: Color.BLACK)
      val softenedPalette = softenedBubblePalette(
        bubbleMeGradient = bubbleMeGradientRaw,
        bubbleThemColor = parseColor(raw["bubbleThemColor"] as? String) ?: fallback.bubbleThemColor,
        wallpaperGradient = wallpaperGradient,
        isDark = isDarkApprox
      )

      return ChatListAppearance(
        backgroundMode = backgroundMode,
        wallpaperGradient = wallpaperGradient,
        wallpaperOpacity = ((raw["wallpaperOpacity"] as? Number)?.toFloat() ?: 1f).coerceIn(0f, 1f),
        wallpaperPatternGradient = wallpaperPatternGradient,
        wallpaperPatternLocations = parseFloatList(raw["wallpaperPatternLocations"]),
        wallpaperPatternOpacity = ((raw["wallpaperPatternOpacity"] as? Number)?.toFloat() ?: 0f).coerceIn(0f, 1f),
        wallpaperMaskKey = normalizedString(raw["wallpaperMaskKey"]),
        bubbleMeGradient = softenedPalette.first,
        bubbleThemColor = softenedPalette.second,
        textColorMe = parseColor(raw["textColorMe"] as? String) ?: fallback.textColorMe,
        textColorThem = parseColor(raw["textColorThem"] as? String) ?: fallback.textColorThem,
        timeColorMe = parseColor(raw["timeColorMe"] as? String) ?: fallback.timeColorMe,
        timeColorThem = parseColor(raw["timeColorThem"] as? String) ?: fallback.timeColorThem,
        dayTextColor = parseColor(raw["dayTextColor"] as? String) ?: fallback.dayTextColor,
        dayBackgroundColor = parseColor(raw["dayBackgroundColor"] as? String) ?: fallback.dayBackgroundColor,
        dayBorderColor = parseColor(raw["dayBorderColor"] as? String) ?: fallback.dayBorderColor,
        messageTailCurvature =
          ((raw["messageTailCurvature"] as? Number)?.toFloat()
            ?: fallback.messageTailCurvature).coerceIn(0f, 1f),
      )
    }
  }
}

private data class NativeThemeVariant(
  val backgroundGradient: List<String>,
  val bubbleMe: String,
  val bubbleMeGradient: List<String>,
  val bubbleThem: String,
  val bubbleThemGradient: List<String>,
  val patternGradientColors: List<String>,
  val patternGradientLocations: List<Float>,
  val patternOpacity: Float,
  val textColorMe: String,
  val textColorThem: String,
)

private data class NativeThemePreset(
  val id: String,
  val maskedImage: String?,
  val light: NativeThemeVariant,
  val dark: NativeThemeVariant,
)

private fun nativePresetAppearance(
  raw: Map<String, Any?>,
  fallback: ChatListAppearance,
): ChatListAppearance? {
  val themeId = normalizedString(raw["nativeThemeId"]) ?: return null
  val preset = nativePreset(themeId) ?: return null
  val isDark = parseBool(raw["nativeThemeIsDark"]) ?: true
  val variant = if (isDark) preset.dark else preset.light

  val resolvedBackgroundGradient: List<String>
  val resolvedPatternGradientColors: List<String>
  val resolvedPatternOpacity: Float

  if (isDark) {
    resolvedBackgroundGradient = variant.backgroundGradient
    resolvedPatternGradientColors = variant.patternGradientColors
    resolvedPatternOpacity = variant.patternOpacity
  } else {
    // Matches iOS and JS resolveThemeVariant() light override path.
    resolvedBackgroundGradient = listOf("#F9F3EA", "#EFE6D9")
    resolvedPatternGradientColors = listOf("#5A8A66", "#5A6675", "#8A75A3")
    resolvedPatternOpacity = 0.04f
  }

  val wallpaperGradient = parseGradientStrings(resolvedBackgroundGradient, fallback.wallpaperGradient)
  val patternGradient = parseGradientStrings(resolvedPatternGradientColors, intArrayOf())
  val bubbleMeGradientUnsoftened = parseGradientStrings(variant.bubbleMeGradient, fallback.bubbleMeGradient)
  val rawBubbleThemColor =
    parseColor(variant.bubbleThemGradient.firstOrNull()) ?: parseColor(variant.bubbleThem) ?: fallback.bubbleThemColor
  val textColorMe = parseColor(variant.textColorMe) ?: fallback.textColorMe
  val textColorThem = parseColor(variant.textColorThem) ?: fallback.textColorThem
  val dayBackgroundBase = wallpaperGradient.firstOrNull() ?: fallback.wallpaperGradient.firstOrNull() ?: Color.BLACK

  val softenedPalette = softenedBubblePalette(
    bubbleMeGradient = bubbleMeGradientUnsoftened,
    bubbleThemColor = rawBubbleThemColor,
    wallpaperGradient = wallpaperGradient,
    isDark = isDark
  )

  return ChatListAppearance(
    backgroundMode = (raw["backgroundMode"] as? String) ?: fallback.backgroundMode,
    wallpaperGradient = wallpaperGradient,
    wallpaperOpacity = ((raw["wallpaperOpacity"] as? Number)?.toFloat() ?: 1f).coerceIn(0f, 1f),
    wallpaperPatternGradient = patternGradient,
    wallpaperPatternLocations = variant.patternGradientLocations.toFloatArray(),
    wallpaperPatternOpacity = resolvedPatternOpacity.coerceIn(0f, 1f),
    wallpaperMaskKey = preset.maskedImage,
    bubbleMeGradient = softenedPalette.first,
    bubbleThemColor = softenedPalette.second,
    textColorMe = textColorMe,
    textColorThem = textColorThem,
    timeColorMe = withAlpha(textColorMe, 0.72f),
    timeColorThem = withAlpha(textColorThem, 0.5f),
    dayTextColor = withAlpha(textColorThem, 0.82f),
    dayBackgroundColor = withAlpha(dayBackgroundBase, 0.42f),
    dayBorderColor = withAlpha(Color.WHITE, 0.16f),
    messageTailCurvature =
      ((raw["messageTailCurvature"] as? Number)?.toFloat()
        ?: fallback.messageTailCurvature).coerceIn(0f, 1f),
  )
}

private fun nativePreset(id: String): NativeThemePreset? {
  return when (id) {
    "glacier" ->
      NativeThemePreset(
        id = id,
        maskedImage = "doodles",
        light =
          NativeThemeVariant(
            backgroundGradient = listOf("#FFFFFF", "#FFFFFF"),
            bubbleMe = "#00838F",
            bubbleMeGradient = listOf("#00ACC1", "#00838F"),
            bubbleThem = "#FFFFFF",
            bubbleThemGradient = listOf("#FFFFFF", "#FFFFFF"),
            patternGradientColors = listOf("#B2EBF2", "#80DEEA", "#4DD0E1"),
            patternGradientLocations = listOf(0f, 0.5f, 1f),
            patternOpacity = 0.12f,
            textColorMe = "#FFFFFF",
            textColorThem = "#000000",
          ),
        dark =
          NativeThemeVariant(
            backgroundGradient = listOf("#000000", "#050507"),
            bubbleMe = "#2A8585",
            bubbleMeGradient = listOf("#3A9595", "#1A7575"),
            bubbleThem = "#24242C",
            bubbleThemGradient = listOf("#2F3338", "#20242A"),
            patternGradientColors = listOf("#115E59", "#0891B2", "#0284C7"),
            patternGradientLocations = listOf(0f, 0.5f, 1f),
            patternOpacity = 0.12f,
            textColorMe = "#F0FCFC",
            textColorThem = "#FFFFFF",
          ),
      )

    "zen" ->
      NativeThemePreset(
        id = id,
        maskedImage = "doodles",
        light =
          NativeThemeVariant(
            backgroundGradient = listOf("#FFFFFF", "#FFFFFF"),
            bubbleMe = "#3F51B5",
            bubbleMeGradient = listOf("#5C6BC0", "#3949AB"),
            bubbleThem = "#F3F4FB",
            bubbleThemGradient = listOf("#FFFFFF", "#FFFFFF"),
            patternGradientColors = listOf("#C5CAE9", "#9FA8DA", "#7986CB"),
            patternGradientLocations = listOf(0f, 0.5f, 1f),
            patternOpacity = 0.12f,
            textColorMe = "#FFFFFF",
            textColorThem = "#000000",
          ),
        dark =
          NativeThemeVariant(
            backgroundGradient = listOf("#000000", "#050507"),
            bubbleMe = "#7C3AED",
            bubbleMeGradient = listOf("#8B5CF6", "#6D28D9"),
            bubbleThem = "#24242C",
            bubbleThemGradient = listOf("#312B3B", "#231E2C"),
            patternGradientColors = listOf("#2563EB", "#4F46E5", "#7C3AED", "#C026D3", "#DB2777"),
            patternGradientLocations = listOf(0f, 0.25f, 0.5f, 0.75f, 1f),
            patternOpacity = 0.12f,
            textColorMe = "#F4F6F7",
            textColorThem = "#FFFFFF",
          ),
      )

    "ocean" ->
      NativeThemePreset(
        id = id,
        maskedImage = "doodles",
        light =
          NativeThemeVariant(
            backgroundGradient = listOf("#FFFFFF", "#FFFFFF"),
            bubbleMe = "#0277BD",
            bubbleMeGradient = listOf("#039BE5", "#0277BD"),
            bubbleThem = "#FFFFFF",
            bubbleThemGradient = listOf("#FFFFFF", "#FFFFFF"),
            patternGradientColors = listOf("#B3E5FC", "#81D4FA", "#4FC3F7"),
            patternGradientLocations = listOf(0f, 0.5f, 1f),
            patternOpacity = 0.12f,
            textColorMe = "#FFFFFF",
            textColorThem = "#000000",
          ),
        dark =
          NativeThemeVariant(
            backgroundGradient = listOf("#000000", "#050507"),
            bubbleMe = "#3A7DA8",
            bubbleMeGradient = listOf("#4A8DB8", "#2A6D98"),
            bubbleThem = "#24242C",
            bubbleThemGradient = listOf("#2A313A", "#1B232C"),
            patternGradientColors = listOf("#1E3A8A", "#0F766E", "#06B6D4", "#22D3EE"),
            patternGradientLocations = listOf(0f, 0.4f, 0.8f, 1f),
            patternOpacity = 0.15f,
            textColorMe = "#F4F8FC",
            textColorThem = "#FFFFFF",
          ),
      )

    "obsidian" ->
      NativeThemePreset(
        id = id,
        maskedImage = "doodles",
        light =
          NativeThemeVariant(
            backgroundGradient = listOf("#FFFFFF", "#FFFFFF"),
            bubbleMe = "#1565C0",
            bubbleMeGradient = listOf("#1E88E5", "#1565C0"),
            bubbleThem = "#FFFFFF",
            bubbleThemGradient = listOf("#FFFFFF", "#FFFFFF"),
            patternGradientColors = listOf("#BBDEFB", "#90CAF9", "#64B5F6"),
            patternGradientLocations = listOf(0f, 0.5f, 1f),
            patternOpacity = 0.12f,
            textColorMe = "#FFFFFF",
            textColorThem = "#000000",
          ),
        dark =
          NativeThemeVariant(
            backgroundGradient = listOf("#000000", "#050507"),
            bubbleMe = "#4A7DC4",
            bubbleMeGradient = listOf("#5A8FD4", "#3A6AB8"),
            bubbleThem = "#24242C",
            bubbleThemGradient = listOf("#2D313C", "#1F2430"),
            patternGradientColors = listOf("#312E81", "#4338CA", "#4F46E5", "#818CF8"),
            patternGradientLocations = listOf(0f, 0.3f, 0.7f, 1f),
            patternOpacity = 0.18f,
            textColorMe = "#F4F6F8",
            textColorThem = "#FFFFFF",
          ),
      )

    "music" ->
      NativeThemePreset(
        id = id,
        maskedImage = "music",
        light =
          NativeThemeVariant(
            backgroundGradient = listOf("#FFFFFF", "#FFFFFF"),
            bubbleMe = "#7B1FA2",
            bubbleMeGradient = listOf("#9C27B0", "#7B1FA2"),
            bubbleThem = "#FFFFFF",
            bubbleThemGradient = listOf("#FFFFFF", "#FFFFFF"),
            patternGradientColors = listOf("#E1BEE7", "#CE93D8", "#BA68C8"),
            patternGradientLocations = listOf(0f, 0.5f, 1f),
            patternOpacity = 0.14f,
            textColorMe = "#FFFFFF",
            textColorThem = "#000000",
          ),
        dark =
          NativeThemeVariant(
            backgroundGradient = listOf("#000000", "#050507"),
            bubbleMe = "#8B5CF6",
            bubbleMeGradient = listOf("#A78BFA", "#7C3AED"),
            bubbleThem = "#24242C",
            bubbleThemGradient = listOf("#332A3E", "#251F30"),
            patternGradientColors = listOf("#22D3EE", "#E879F9", "#8B5CF6"),
            patternGradientLocations = listOf(0f, 0.5f, 1f),
            patternOpacity = 0.15f,
            textColorMe = "#F8F6FC",
            textColorThem = "#FFFFFF",
          ),
      )

    "terracotta" ->
      NativeThemePreset(
        id = id,
        maskedImage = "doodles",
        light =
          NativeThemeVariant(
            backgroundGradient = listOf("#FFFFFF", "#FFFFFF"),
            bubbleMe = "#E65100",
            bubbleMeGradient = listOf("#F57C00", "#E65100"),
            bubbleThem = "#FFFFFF",
            bubbleThemGradient = listOf("#FFFFFF", "#FFFFFF"),
            patternGradientColors = listOf("#FFE0B2", "#FFCC80", "#FFB74D"),
            patternGradientLocations = listOf(0f, 0.5f, 1f),
            patternOpacity = 0.14f,
            textColorMe = "#FFFFFF",
            textColorThem = "#000000",
          ),
        dark =
          NativeThemeVariant(
            backgroundGradient = listOf("#000000", "#050507"),
            bubbleMe = "#B87050",
            bubbleMeGradient = listOf("#C88060", "#A86040"),
            bubbleThem = "#24242C",
            bubbleThemGradient = listOf("#3B2F2A", "#2B221F"),
            patternGradientColors = listOf("#DC2626", "#EA580C", "#B45309"),
            patternGradientLocations = listOf(0f, 0.5f, 1f),
            patternOpacity = 0.12f,
            textColorMe = "#FAF0E8",
            textColorThem = "#FFFFFF",
          ),
      )

    else -> null
  }
}

private fun parseGradient(values: List<*>?, fallback: IntArray): IntArray {
  if (values == null) return fallback
  val parsed = values.mapNotNull { parseColor(it as? String) }
  return if (parsed.size >= 2) parsed.toIntArray() else fallback
}

private fun parseGradientStrings(values: List<String>, fallback: IntArray): IntArray {
  val parsed = values.mapNotNull(::parseColor)
  return if (parsed.size >= 2) parsed.toIntArray() else fallback
}

private fun parseFloatList(raw: Any?): FloatArray? {
  val list = raw as? List<*> ?: return null
  val parsed =
    list.mapNotNull {
      when (it) {
        is Number -> it.toFloat()
        is String -> it.toFloatOrNull()
        else -> null
      }
    }
  return if (parsed.size == list.size) parsed.toFloatArray() else null
}

private fun normalizedString(raw: Any?): String? {
  val value = raw as? String ?: return null
  val trimmed = value.trim()
  return trimmed.takeIf { it.isNotEmpty() }
}

private fun parseBool(raw: Any?): Boolean? {
  return when (raw) {
    is Boolean -> raw
    is Number -> raw.toInt() != 0
    is String -> {
      when (raw.trim().lowercase()) {
        "1", "true", "yes" -> true
        "0", "false", "no" -> false
        else -> null
      }
    }
    else -> null
  }
}

private fun floatArrayContentEquals(lhs: FloatArray?, rhs: FloatArray?): Boolean {
  if (lhs === rhs) return true
  if (lhs == null || rhs == null) return false
  return lhs.contentEquals(rhs)
}

private fun withAlpha(color: Int, alpha: Float): Int {
  val a = (alpha.coerceIn(0f, 1f) * 255f).toInt()
  return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
}

private fun parseColor(value: String?): Int? {
  if (value.isNullOrBlank()) return null
  val v = value.trim().lowercase()
  return try {
    when {
      v.startsWith("#") -> parseHexColor(v)
      v.startsWith("rgba(") -> parseRgba(v)
      v.startsWith("rgb(") -> parseRgb(v)
      else -> null
    }
  } catch (_: Throwable) {
    null
  }
}

private fun parseHexColor(value: String): Int? {
  // JS often sends #RRGGBBAA while Android Color.parseColor expects #AARRGGBB.
  if (value.length == 9 && value.startsWith("#")) {
    val rrggbbaa = value.substring(1)
    val aarrggbb = rrggbbaa.substring(6, 8) + rrggbbaa.substring(0, 6)
    return Color.parseColor("#$aarrggbb")
  }
  if (value.length == 5 && value.startsWith("#")) {
    // Convert #RGBA -> #AARRGGBB
    val rgba = value.substring(1)
    val r = "${rgba[0]}${rgba[0]}"
    val g = "${rgba[1]}${rgba[1]}"
    val b = "${rgba[2]}${rgba[2]}"
    val a = "${rgba[3]}${rgba[3]}"
    return Color.parseColor("#$a$r$g$b")
  }
  if (value.length == 4 && value.startsWith("#")) {
    val rgb = value.substring(1)
    val r = "${rgb[0]}${rgb[0]}"
    val g = "${rgb[1]}${rgb[1]}"
    val b = "${rgb[2]}${rgb[2]}"
    return Color.parseColor("#ff$r$g$b")
  }
  return Color.parseColor(value)
}

private fun parseRgb(value: String): Int? {
  val body = value.substringAfter("(", "").substringBeforeLast(")")
  val args = body.split(",").map { it.trim() }
  if (args.size != 3) return null
  val r = args[0].toFloatOrNull() ?: return null
  val g = args[1].toFloatOrNull() ?: return null
  val b = args[2].toFloatOrNull() ?: return null
  return Color.argb(
    255,
    min(255f, max(0f, r)).toInt(),
    min(255f, max(0f, g)).toInt(),
    min(255f, max(0f, b)).toInt(),
  )
}

private fun parseRgba(value: String): Int? {
  val body = value.substringAfter("(", "").substringBeforeLast(")")
  val args = body.split(",").map { it.trim() }
  if (args.size != 4) return null
  val r = args[0].toFloatOrNull() ?: return null
  val g = args[1].toFloatOrNull() ?: return null
  val b = args[2].toFloatOrNull() ?: return null
  val a = args[3].toFloatOrNull() ?: return null
  return Color.argb(
    (min(1f, max(0f, a)) * 255f).toInt(),
    min(255f, max(0f, r)).toInt(),
    min(255f, max(0f, g)).toInt(),
    min(255f, max(0f, b)).toInt(),
  )
}

private fun softenedBubblePalette(
  bubbleMeGradient: IntArray,
  bubbleThemColor: Int,
  wallpaperGradient: IntArray,
  isDark: Boolean
): Pair<IntArray, Int> {
  val wallFirst = wallpaperGradient.firstOrNull() ?: if (isDark) Color.BLACK else Color.WHITE
  val wallLast = wallpaperGradient.lastOrNull() ?: wallFirst
  val wallpaperAnchor = blendColor(wallFirst, wallLast, 0.36f)

  val softenedMe = bubbleMeGradient.map { color ->
    val contrast = contrastRatio(color, wallpaperAnchor)
    val extra = max(0.0, min(0.12, (contrast - (if (isDark) 4.2 else 3.8)) * 0.05))
    val mix = (if (isDark) 0.12 else 0.04) + extra
    val base = blendColor(color, wallpaperAnchor, mix.toFloat())
    withAlpha(base, 0.96f)
  }.toIntArray()

  val themContrast = contrastRatio(bubbleThemColor, wallpaperAnchor)
  val themExtra = max(0.0, min(0.14, (themContrast - (if (isDark) 2.6 else 2.2)) * 0.07))
  val themMix = (if (isDark) 0.12 else 0.03) + themExtra
  var softenedThem = blendColor(bubbleThemColor, wallpaperAnchor, themMix.toFloat())
  softenedThem = withAlpha(softenedThem, if (isDark) 0.94f else 0.96f)

  // Force white bubble for incoming messages in light theme
  if (!isDark) {
    softenedThem = Color.WHITE
  }

  return Pair(softenedMe, softenedThem)
}

private fun blendColor(from: Int, to: Int, amount: Float): Int {
  val t = amount.coerceIn(0f, 1f)
  val inv = 1f - t
  val r = (Color.red(from) * inv + Color.red(to) * t).toInt()
  val g = (Color.green(from) * inv + Color.green(to) * t).toInt()
  val b = (Color.blue(from) * inv + Color.blue(to) * t).toInt()
  val a = (Color.alpha(from) * inv + Color.alpha(to) * t).toInt()
  return Color.argb(a, r, g, b)
}

private fun isDarkColor(color: Int): Boolean {
  val r = Color.red(color) / 255f
  val g = Color.green(color) / 255f
  val b = Color.blue(color) / 255f
  val luminance = 0.299 * r + 0.587 * g + 0.114 * b
  return luminance < 0.5
}

private fun contrastRatio(c1: Int, c2: Int): Double {
  val l1 = relativeLuminance(c1)
  val l2 = relativeLuminance(c2)
  val hi = max(l1, l2)
  val lo = min(l1, l2)
  return (hi + 0.05) / (lo + 0.05)
}

private fun relativeLuminance(color: Int): Double {
  val r = Color.red(color) / 255.0
  val g = Color.green(color) / 255.0
  val b = Color.blue(color) / 255.0

  fun linear(value: Double): Double {
    return if (value <= 0.03928) value / 12.92 else ((value + 0.055) / 1.055).pow(2.4)
  }

  return (0.2126 * linear(r)) + (0.7152 * linear(g)) + (0.0722 * linear(b))
}

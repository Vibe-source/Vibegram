#!/usr/bin/env python3
"""Measure Vibe/Telegram bubble silhouettes and render a vector comparison.

The segmentation thresholds are intentionally specific to the two supplied screenshots.
The generated SVG is standalone (the source crops are embedded as data URIs), while the
PNG is drawn from the same sampled vector geometry for quick visual inspection.
"""

from __future__ import annotations

import argparse
import base64
import io
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.optimize import least_squares
from scipy.spatial import cKDTree


# The tail path is three connected cubics represented as:
# outerStart, outerC1, outerC2, tip, innerC1, innerC2, notch,
# cornerC1, cornerC2, bottomJoin. Coordinates are normalized to an 18pt radius.
IOS_CURRENT_TAIL = (
    (0.0967, -7.9401),
    (0.0967, -4.6557),
    (4.4885, -2.5490),
    (5.3793, 0.0061),
    (0.6122, 0.6143),
    (-3.9233, -0.5402),
    (-7.0522, -3.8821),
    (-9.0308, -1.5103),
    (-12.1883, 0.0061),
    (-14.7700, 0.0061),
)

# Cubics fitted against the second Telegram screenshot after aligning the two body
# rectangles at their bottom-right corner. Symmetric contour error is < 0.5px.
TELEGRAM_FITTED_TAIL = (
    (0.0000, -7.7280),
    (0.4310, -5.4310),
    (1.9830, -2.2870),
    (4.6380, 0.0000),
    (0.9830, -0.4090),
    (-4.4190, -0.6970),
    (-7.7280, -3.4780),
    (-10.5260, -1.6100),
    (-13.7070, -0.6630),
    (-17.0020, 0.0000),
)


@dataclass(frozen=True)
class BubbleSample:
    name: str
    path: Path
    threshold: Callable[[np.ndarray], np.ndarray]


@dataclass
class BubbleMeasurement:
    sample: BubbleSample
    image: Image.Image
    mask: np.ndarray
    contour: np.ndarray
    bounds: tuple[int, int, int, int]
    top_left_radius_px: float
    fit_error_px: float


def largest_component(mask: np.ndarray) -> np.ndarray:
    count, labels, stats, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), 8)
    if count < 2:
        raise RuntimeError("No bubble-colored component found")
    label = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    component = (labels == label).astype(np.uint8)
    contours, _ = cv2.findContours(component, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    filled = np.zeros_like(component)
    cv2.drawContours(filled, [max(contours, key=cv2.contourArea)], -1, 1, cv2.FILLED)
    return filled.astype(bool)


def fit_top_left_radius(mask: np.ndarray) -> tuple[float, float]:
    ys = np.flatnonzero(mask.any(axis=1))
    top = int(ys[0])
    left = np.min(np.where(mask, np.indices(mask.shape)[1], 1_000_000), axis=1)
    x_min = int(left[ys].min())
    fit_y = np.arange(top, min(mask.shape[0], top + 75))
    fit_x = left[fit_y]

    def residual(params: np.ndarray) -> np.ndarray:
        edge_x, edge_y, radius = params
        dy = fit_y - (edge_y + radius)
        # Once the quarter-circle reaches its center, the silhouette continues as the
        # straight left edge. Including that vertical run stabilizes the fit, but it must
        # not be evaluated as a second half-circle.
        predicted = np.where(
            dy < 0.0,
            edge_x + radius - np.sqrt(np.maximum(0.0, radius * radius - dy * dy)),
            edge_x,
        )
        return predicted - fit_x

    result = least_squares(
        residual,
        [x_min, top, 50.0],
        bounds=([x_min - 3.0, top - 3.0, 20.0], [x_min + 3.0, top + 3.0, 80.0]),
    )
    return float(result.x[2]), float(np.mean(np.abs(residual(result.x))))


def measure(sample: BubbleSample) -> BubbleMeasurement:
    image = Image.open(sample.path).convert("RGB")
    rgb = np.asarray(image, dtype=np.int16)
    mask = largest_component(sample.threshold(rgb))
    contours, _ = cv2.findContours(mask.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    contour = max(contours, key=cv2.contourArea)[:, 0, :]
    ys, xs = np.where(mask)
    radius, error = fit_top_left_radius(mask)
    return BubbleMeasurement(
        sample=sample,
        image=image,
        mask=mask,
        contour=contour,
        bounds=(int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())),
        top_left_radius_px=radius,
        fit_error_px=error,
    )


def cubic(p0, p1, p2, p3, steps=18):
    result = []
    for index in range(1, steps + 1):
        t = index / steps
        mt = 1.0 - t
        result.append(
            (
                mt**3 * p0[0] + 3 * mt**2 * t * p1[0] + 3 * mt * t**2 * p2[0] + t**3 * p3[0],
                mt**3 * p0[1] + 3 * mt**2 * t * p1[1] + 3 * mt * t**2 * p2[1] + t**3 * p3[1],
            )
        )
    return result


def arc(center, radius, start, end, steps=18):
    return [
        (
            center[0] + radius * math.cos(start + (end - start) * index / steps),
            center[1] + radius * math.sin(start + (end - start) * index / steps),
        )
        for index in range(1, steps + 1)
    ]


def outgoing_bubble_points(
    width: float,
    height: float,
    radius: float,
    tail_reference=IOS_CURRENT_TAIL,
):
    """Sample the same body arc + default three-cubic tail used by iOS."""
    points = [(radius, 0.0), (width - radius, 0.0)]
    points += arc((width - radius, radius), radius, -math.pi / 2, 0)

    scale = radius / 18.0
    transform = lambda p: (width + p[0] * scale, height + p[1] * scale)
    (
        outer_start,
        outer_c1,
        outer_c2,
        tip,
        inner_c1,
        inner_c2,
        notch,
        corner_c1,
        corner_c2,
        bottom_join,
    ) = map(transform, tail_reference)
    points.append(outer_start)
    points += cubic(outer_start, outer_c1, outer_c2, tip)
    points += cubic(tip, inner_c1, inner_c2, notch)
    points += cubic(notch, corner_c1, corner_c2, bottom_join)
    points.append((radius, height))
    points += arc((radius, height - radius), radius, math.pi / 2, math.pi)
    points.append((0.0, radius))
    points += arc((radius, radius), radius, math.pi, math.pi * 1.5)
    return points


def svg_path(points):
    return "M " + " L ".join(f"{x:.2f},{y:.2f}" for x, y in points) + " Z"


def crop_data_uri(measurement: BubbleMeasurement, pad=12):
    x0, y0, x1, y1 = measurement.bounds
    crop = measurement.image.crop(
        (max(0, x0 - pad), max(0, y0 - pad), min(measurement.image.width, x1 + pad + 1), min(measurement.image.height, y1 + pad + 1))
    )
    buffer = io.BytesIO()
    crop.save(buffer, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode("ascii"), crop.size


def aligned_corner_polyline(measurement: BubbleMeasurement, extent=72):
    x0, y0, _, _ = measurement.bounds
    rows = []
    for y in range(y0, min(measurement.mask.shape[0], y0 + extent + 1)):
        xs = np.flatnonzero(measurement.mask[y])
        if len(xs):
            rows.append((float(xs[0] - x0), float(y - y0)))
    return rows


def bubble_body_frame(measurement: BubbleMeasurement):
    """Return left/top/right/bottom for the rounded body, excluding tail overhang."""
    left, top, _, bottom = measurement.bounds
    body_height = max(1, bottom - top)
    column_counts = measurement.mask.sum(axis=0)
    candidates = np.flatnonzero(column_counts >= body_height * 0.5)
    if len(candidates) == 0:
        raise RuntimeError(f"Could not resolve body edge for {measurement.sample.name}")
    return float(left), float(top), float(candidates[-1]), float(bottom)


def sampled_tail_curve(tail_reference, screen_scale):
    transformed = [(x * screen_scale, y * screen_scale) for x, y in tail_reference]
    return (
        [transformed[0]]
        + cubic(*transformed[0:4], steps=64)
        + cubic(*transformed[3:7], steps=64)
        + cubic(transformed[6], transformed[7], transformed[8], transformed[9], steps=64)
    )


def tail_comparison_data(vibe, telegram, target_radius_px):
    _, vibe_top, vibe_right, vibe_bottom = bubble_body_frame(vibe)
    _, telegram_top, telegram_right, telegram_bottom = bubble_body_frame(telegram)
    body_scale = (telegram_bottom - telegram_top) / max(1.0, vibe_bottom - vibe_top)

    def aligned_vibe(point):
        return (
            (float(point[0]) - vibe_right) * body_scale,
            (float(point[1]) - vibe_bottom) * body_scale,
        )

    def local_telegram(point):
        return (
            float(point[0]) - telegram_right,
            float(point[1]) - telegram_bottom,
        )

    vibe_tail = [
        aligned_vibe(point)
        for point in vibe.contour
        if (float(point[0]) - vibe_right) > -68.0
        and (float(point[1]) - vibe_bottom) > -42.0
    ]
    telegram_tail = [
        local_telegram(point)
        for point in telegram.contour
        if (float(point[0]) - telegram_right) > -68.0
        and (float(point[1]) - telegram_bottom) > -42.0
    ]
    screen_scale = target_radius_px / 18.0 * body_scale
    current_curve = sampled_tail_curve(IOS_CURRENT_TAIL, screen_scale)
    candidate_curve = sampled_tail_curve(TELEGRAM_FITTED_TAIL, screen_scale)

    candidate_array = np.asarray(candidate_curve)
    target_array = np.asarray(
        [
            point
            for point in telegram_tail
            if point[0] >= float(candidate_array[:, 0].min()) - 1.0
            and point[1] >= float(candidate_array[:, 1].min()) - 1.0
        ]
    )
    candidate_to_target = cKDTree(target_array).query(candidate_array)[0]
    target_to_candidate = cKDTree(candidate_array).query(target_array)[0]
    symmetric_error = (candidate_to_target.mean() + target_to_candidate.mean()) * 0.5
    return {
        "vibe": vibe_tail,
        "telegram": telegram_tail,
        "current": current_curve,
        "candidate": candidate_curve,
        "body_scale": body_scale,
        "screen_scale": screen_scale,
        "symmetric_error": float(symmetric_error),
        "max_error": float(max(candidate_to_target.max(), target_to_candidate.max())),
    }


def make_tail_svg(vibe, telegram, output_path: Path, target_radius_px: float):
    data = tail_comparison_data(vibe, telegram, target_radius_px)
    vibe_uri, vibe_crop = crop_data_uri(vibe)
    telegram_uri, telegram_crop = crop_data_uri(telegram)

    def polyline(points):
        return " ".join(f"{x:.2f},{y:.2f}" for x, y in points)

    current = outgoing_bubble_points(302.0, 102.0, target_radius_px, IOS_CURRENT_TAIL)
    corrected = outgoing_bubble_points(302.0, 102.0, target_radius_px, TELEGRAM_FITTED_TAIL)
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1440" height="760" viewBox="0 0 1440 760">
<rect width="1440" height="760" fill="#0b0d14"/>
<style>
  .title {{ fill:#f5f7ff; font:700 28px -apple-system,BlinkMacSystemFont,sans-serif }}
  .head {{ fill:#f5f7ff; font:650 19px -apple-system,BlinkMacSystemFont,sans-serif }}
  .body {{ fill:#adb4c6; font:15px -apple-system,BlinkMacSystemFont,sans-serif }}
  .mono {{ fill:#d9def0; font:14px ui-monospace,SFMono-Regular,monospace }}
</style>
<text x="34" y="42" class="title">Outgoing tail geometry — body-aligned screenshot fit</text>
<g transform="translate(34 76)">
  <text x="0" y="0" class="head">Vibe source</text>
  <image x="0" y="18" width="{vibe_crop[0]}" height="{vibe_crop[1]}" href="{vibe_uri}"/>
</g>
<g transform="translate(405 76)">
  <text x="0" y="0" class="head">Telegram source</text>
  <image x="0" y="18" width="{telegram_crop[0]}" height="{telegram_crop[1]}" href="{telegram_uri}"/>
</g>
<g transform="translate(850 76)">
  <text x="0" y="0" class="head">Tail contours aligned at body bottom-right (4×)</text>
  <g transform="translate(265 180) scale(4)">
    <path d="M -68,-42 H 24 V 4 H -68 Z" fill="#151925" stroke="#242b3c" stroke-width="0.25"/>
    <polyline points="{polyline(data['vibe'])}" fill="none" stroke="#ff5f6d" stroke-width="0.8"/>
    <polyline points="{polyline(data['telegram'])}" fill="none" stroke="#7ea6ff" stroke-width="0.8"/>
    <polyline points="{polyline(data['candidate'])}" fill="none" stroke="#45e0a8" stroke-width="0.9"/>
  </g>
  <text x="0" y="260" class="body" fill="#ff5f6d">red — current Vibe screenshot</text>
  <text x="0" y="288" class="body" fill="#7ea6ff">blue — Telegram screenshot</text>
  <text x="0" y="316" class="body" fill="#45e0a8">green — fitted three-cubic candidate</text>
  <text x="0" y="354" class="mono">symmetric contour error: {data['symmetric_error']:.2f}px</text>
</g>
<g transform="translate(80 430)">
  <text x="0" y="0" class="head">Current 16pt body + old tail</text>
  <g transform="translate(8 24)"><path d="{svg_path(current)}" fill="#238cf0"/><path d="{svg_path(current)}" fill="none" stroke="#ff5f6d" stroke-width="2"/></g>
</g>
<g transform="translate(530 430)">
  <text x="0" y="0" class="head">Corrected 16pt body + fitted tail</text>
  <g transform="translate(8 24)"><path d="{svg_path(corrected)}" fill="#5d73b6"/><path d="{svg_path(corrected)}" fill="none" stroke="#45e0a8" stroke-width="2"/></g>
</g>
<g transform="translate(990 450)">
  <text x="0" y="0" class="head">Geometry changes</text>
  <text x="0" y="36" class="body">• tip overhang 5.38 → 4.64</text>
  <text x="0" y="64" class="body">• notch moves inward and upward</text>
  <text x="0" y="92" class="body">• bottom join extends 14.77 → 17.00</text>
  <text x="0" y="120" class="body">• inner control no longer dips below baseline</text>
</g>
</svg>'''
    output_path.write_text(svg, encoding="utf-8")


def make_tail_png(vibe, telegram, output_path: Path, target_radius_px: float):
    data = tail_comparison_data(vibe, telegram, target_radius_px)
    canvas = Image.new("RGB", (1440, 760), "#0b0d14")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default()
    draw.text((34, 24), "Outgoing tail geometry - body-aligned screenshot fit", fill="#f5f7ff", font=font)

    for index, measurement in enumerate((vibe, telegram)):
        x0, y0, x1, y1 = measurement.bounds
        crop = measurement.image.crop(
            (max(0, x0 - 12), max(0, y0 - 12), min(measurement.image.width, x1 + 13), min(measurement.image.height, y1 + 13))
        )
        panel_x = 34 + index * 390
        canvas.paste(crop, (panel_x, 76))
        draw.text((panel_x, 58), measurement.sample.name, fill="#f5f7ff", font=font)

    origin = (1120, 260)
    zoom = 4.0
    draw.rectangle(
        (origin[0] - 68 * zoom, origin[1] - 42 * zoom, origin[0] + 24 * zoom, origin[1] + 4 * zoom),
        fill="#151925",
        outline="#242b3c",
    )
    for points, color, width in (
        (data["vibe"], "#ff5f6d", 3),
        (data["telegram"], "#7ea6ff", 3),
        (data["candidate"], "#45e0a8", 4),
    ):
        draw.line(
            [(origin[0] + x * zoom, origin[1] + y * zoom) for x, y in points],
            fill=color,
            width=width,
        )
    draw.text((830, 58), "Tail contours aligned at body bottom-right (4x)", fill="#f5f7ff", font=font)
    draw.text((830, 290), "red: current Vibe", fill="#ff5f6d", font=font)
    draw.text((830, 312), "blue: Telegram", fill="#7ea6ff", font=font)
    draw.text((830, 334), "green: fitted candidate", fill="#45e0a8", font=font)
    draw.text((830, 370), f"symmetric error {data['symmetric_error']:.2f}px", fill="#d9def0", font=font)

    for index, (label, reference, color) in enumerate(
        (
            ("Current 16pt body + old tail", IOS_CURRENT_TAIL, "#238cf0"),
            ("Corrected 16pt body + fitted tail", TELEGRAM_FITTED_TAIL, "#5d73b6"),
        )
    ):
        ox = 80 + index * 500
        oy = 520
        points = [
            (ox + x, oy + y)
            for x, y in outgoing_bubble_points(302.0, 102.0, target_radius_px, reference)
        ]
        draw.polygon(points, fill=color)
        draw.line(points + [points[0]], fill="#f5f7ff", width=1)
        draw.text((ox, oy - 24), label, fill="#f5f7ff", font=font)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output_path)


def make_svg(vibe, telegram, output_path: Path, target_radius_px: float):
    vibe_uri, vibe_crop = crop_data_uri(vibe)
    telegram_uri, telegram_crop = crop_data_uri(telegram)
    current_radius = 54.0
    current = outgoing_bubble_points(198.0, 153.0, current_radius)
    corrected = outgoing_bubble_points(198.0, 153.0, target_radius_px)
    vibe_corner = aligned_corner_polyline(vibe)
    telegram_corner = aligned_corner_polyline(telegram)
    candidate_corner = [
        (
            target_radius_px - math.sqrt(max(0.0, target_radius_px**2 - (y - target_radius_px) ** 2)),
            y,
        )
        for y in np.linspace(0.0, target_radius_px, 64)
    ]

    def polyline(points):
        return " ".join(f"{x:.2f},{y:.2f}" for x, y in points)

    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1440" height="760" viewBox="0 0 1440 760">
<rect width="1440" height="760" fill="#0b0d14"/>
<style>
  .title {{ fill:#f5f7ff; font:700 28px -apple-system,BlinkMacSystemFont,sans-serif }}
  .head {{ fill:#f5f7ff; font:650 19px -apple-system,BlinkMacSystemFont,sans-serif }}
  .body {{ fill:#adb4c6; font:15px -apple-system,BlinkMacSystemFont,sans-serif }}
  .mono {{ fill:#d9def0; font:14px ui-monospace,SFMono-Regular,monospace }}
</style>
<text x="34" y="42" class="title">Outgoing bubble geometry — screenshot measurement → iOS candidate</text>
<g transform="translate(34 76)">
  <text x="0" y="0" class="head">Vibe source</text>
  <image x="0" y="18" width="{vibe_crop[0]}" height="{vibe_crop[1]}" href="{vibe_uri}"/>
  <text x="0" y="{vibe_crop[1]+48}" class="mono">top-left fit: {vibe.top_left_radius_px:.1f}px · error {vibe.fit_error_px:.2f}px</text>
</g>
<g transform="translate(300 76)">
  <text x="0" y="0" class="head">Telegram source</text>
  <image x="0" y="18" width="{telegram_crop[0]}" height="{telegram_crop[1]}" href="{telegram_uri}"/>
  <text x="0" y="{telegram_crop[1]+48}" class="mono">top-left fit: {telegram.top_left_radius_px:.1f}px · error {telegram.fit_error_px:.2f}px</text>
</g>
<g transform="translate(610 76)">
  <text x="0" y="0" class="head">Corners aligned at their top-left origin (4×)</text>
  <g transform="translate(20 30) scale(4)">
    <path d="M 0,0 H 72 V 72 H 0 Z" fill="#151925" stroke="#242b3c" stroke-width="0.25"/>
    <polyline points="{polyline(vibe_corner)}" fill="none" stroke="#ff5f6d" stroke-width="0.8"/>
    <polyline points="{polyline(telegram_corner)}" fill="none" stroke="#7ea6ff" stroke-width="0.8"/>
    <polyline points="{polyline(candidate_corner)}" fill="none" stroke="#45e0a8" stroke-width="0.8" stroke-dasharray="2 1"/>
  </g>
  <text x="330" y="60" class="body" fill="#ff5f6d">red — Vibe measured ({vibe.top_left_radius_px:.1f}px)</text>
  <text x="330" y="88" class="body" fill="#7ea6ff">blue — Telegram measured ({telegram.top_left_radius_px:.1f}px)</text>
  <text x="330" y="116" class="body" fill="#45e0a8">green — candidate ({target_radius_px:.0f}px / 16pt @3×)</text>
  <text x="330" y="160" class="body">The candidate overlaps Telegram's fitted corner.</text>
</g>
<g transform="translate(50 420)">
  <text x="0" y="0" class="head">Current iOS vector — 18pt (54px @3×)</text>
  <g transform="translate(8 24)"><path d="{svg_path(current)}" fill="#238cf0"/><path d="{svg_path(current)}" fill="none" stroke="#ff5f6d" stroke-width="2"/></g>
</g>
<g transform="translate(430 420)">
  <text x="0" y="0" class="head">Corrected vector — 16pt (48px @3×)</text>
  <g transform="translate(8 24)"><path d="{svg_path(corrected)}" fill="#5874b8"/><path d="{svg_path(corrected)}" fill="none" stroke="#45e0a8" stroke-width="2"/></g>
</g>
<g transform="translate(810 420)">
  <text x="0" y="0" class="head">Current vs corrected overlay</text>
  <g transform="translate(8 24)">
    <path d="{svg_path(current)}" fill="#ff5f6d" fill-opacity="0.30" stroke="#ff5f6d" stroke-width="2"/>
    <path d="{svg_path(corrected)}" fill="#45e0a8" fill-opacity="0.30" stroke="#45e0a8" stroke-width="2"/>
  </g>
  <text x="0" y="220" class="body">Only the primary radius changes; tail math stays coupled to it.</text>
  <text x="0" y="246" class="body">Measured reduction: {vibe.top_left_radius_px-telegram.top_left_radius_px:.1f}px ({(1-telegram.top_left_radius_px/vibe.top_left_radius_px)*100:.1f}%).</text>
</g>
</svg>'''
    output_path.write_text(svg, encoding="utf-8")


def make_png(vibe, telegram, output_path: Path, target_radius_px: float):
    canvas = Image.new("RGB", (1440, 760), "#0b0d14")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default()
    draw.text((34, 24), "Outgoing bubble geometry - measured screenshots and corrected vector", fill="#f5f7ff", font=font)

    for index, measurement in enumerate((vibe, telegram)):
        x0, y0, x1, y1 = measurement.bounds
        crop = measurement.image.crop((max(0, x0 - 12), max(0, y0 - 12), min(measurement.image.width, x1 + 13), min(measurement.image.height, y1 + 13)))
        panel_x = 34 + index * 280
        canvas.paste(crop, (panel_x, 76))
        draw.text((panel_x, 58), measurement.sample.name, fill="#f5f7ff", font=font)
        draw.text((panel_x, 76 + crop.height + 8), f"radius {measurement.top_left_radius_px:.1f}px", fill="#d9def0", font=font)

    origin = (660, 90)
    scale = 4.0
    draw.rectangle((origin[0], origin[1], origin[0] + 72 * scale, origin[1] + 72 * scale), fill="#151925", outline="#242b3c")
    for measurement, color in ((vibe, "#ff5f6d"), (telegram, "#7ea6ff")):
        points = [(origin[0] + x * scale, origin[1] + y * scale) for x, y in aligned_corner_polyline(measurement)]
        draw.line(points, fill=color, width=3)
    candidate = [
        (
            origin[0] + (target_radius_px - math.sqrt(max(0.0, target_radius_px**2 - (y - target_radius_px) ** 2))) * scale,
            origin[1] + y * scale,
        )
        for y in np.linspace(0.0, target_radius_px, 80)
    ]
    draw.line(candidate, fill="#45e0a8", width=3)
    draw.text((origin[0], origin[1] - 22), "Aligned top-left contours (4x)", fill="#f5f7ff", font=font)
    draw.text((1000, 100), "red: Vibe", fill="#ff5f6d", font=font)
    draw.text((1000, 122), "blue: Telegram", fill="#7ea6ff", font=font)
    draw.text((1000, 144), "green: 16pt candidate", fill="#45e0a8", font=font)

    for index, (label, radius, color) in enumerate((
        ("Current 18pt", 54.0, "#ff5f6d"),
        ("Corrected 16pt", target_radius_px, "#45e0a8"),
    )):
        ox = 110 + index * 430
        oy = 470
        points = [(ox + x, oy + y) for x, y in outgoing_bubble_points(198.0, 153.0, radius)]
        draw.polygon(points, fill="#238cf0" if index == 0 else "#5874b8")
        draw.line(points + [points[0]], fill=color, width=2)
        draw.text((ox, oy - 24), label, fill="#f5f7ff", font=font)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output_path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--vibe", type=Path, required=True)
    parser.add_argument("--telegram", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, default=Path("/tmp/vibe-bubble-geometry"))
    parser.add_argument("--focus", choices=("corner", "tail"), default="corner")
    args = parser.parse_args()

    samples = (
        BubbleSample(
            "Vibe",
            args.vibe,
            lambda rgb: (rgb[:, :, 2] > 150) & (rgb[:, :, 1] > 80) & (rgb[:, :, 2] - rgb[:, :, 0] > 80) & (rgb[:, :, 1] - rgb[:, :, 0] > 35),
        ),
        BubbleSample(
            "Telegram",
            args.telegram,
            lambda rgb: (rgb[:, :, 2] > 120) & (rgb[:, :, 1] > 70) & (rgb[:, :, 0] > 40) & (rgb[:, :, 2] - rgb[:, :, 0] > 35) & (rgb[:, :, 2] - rgb[:, :, 1] > 25),
        ),
    )
    vibe, telegram = (measure(sample) for sample in samples)
    target_radius_px = 48.0
    args.output_dir.mkdir(parents=True, exist_ok=True)
    if args.focus == "tail":
        make_tail_svg(vibe, telegram, args.output_dir / "tail-geometry-comparison.svg", target_radius_px)
        make_tail_png(vibe, telegram, args.output_dir / "tail-geometry-comparison.png", target_radius_px)
    else:
        make_svg(vibe, telegram, args.output_dir / "bubble-geometry-comparison.svg", target_radius_px)
        make_png(vibe, telegram, args.output_dir / "bubble-geometry-comparison.png", target_radius_px)
    report = (
        f"Vibe radius: {vibe.top_left_radius_px:.2f}px (MAE {vibe.fit_error_px:.2f}px)\n"
        f"Telegram radius: {telegram.top_left_radius_px:.2f}px (MAE {telegram.fit_error_px:.2f}px)\n"
        f"Measured delta: {vibe.top_left_radius_px-telegram.top_left_radius_px:.2f}px\n"
        f"Selected iOS radius: {target_radius_px/3:.1f}pt ({target_radius_px:.0f}px @3x)\n"
    )
    (args.output_dir / "measurements.txt").write_text(report, encoding="utf-8")
    print(report, end="")
    output_stem = "tail-geometry-comparison" if args.focus == "tail" else "bubble-geometry-comparison"
    print(args.output_dir / f"{output_stem}.svg")
    print(args.output_dir / f"{output_stem}.png")


if __name__ == "__main__":
    main()

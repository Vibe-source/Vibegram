#!/usr/bin/env python3
"""Extract and compare the Telegram outgoing-bubble silhouette from a screenshot.

The reference mask uses a 50% chroma threshold.  This makes the contour gate
repeatable despite the source PNG's antialiasing and vertical blue gradient.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import cv2
import numpy as np
from PIL import Image
from scipy import ndimage


CIRCLE_CUBIC = 0.5522847498307936
CONTOUR_OUTSET = 0.72


def extract_blue_bubble(image: np.ndarray) -> np.ndarray:
    rgb = image[..., :3].astype(np.float32)
    chroma = rgb[..., 2] - rgb[..., 0]
    row_peak = np.maximum(chroma.max(axis=1), 1.0)
    threshold = np.maximum(24.0, row_peak * 0.50)[:, None]
    candidate = chroma >= threshold

    labels, count = ndimage.label(candidate)
    if count == 0:
        raise RuntimeError("No blue bubble component found")
    sizes = np.bincount(labels.ravel())
    sizes[0] = 0
    bubble = labels == int(sizes.argmax())
    return ndimage.binary_fill_holes(bubble)


def row_runs(row: np.ndarray) -> list[tuple[int, int]]:
    xs = np.flatnonzero(row)
    if xs.size == 0:
        return []
    breaks = np.flatnonzero(np.diff(xs) > 1)
    starts = np.r_[0, breaks + 1]
    ends = np.r_[breaks, xs.size - 1]
    return [(int(xs[start]), int(xs[end])) for start, end in zip(starts, ends)]


def analyze(mask: np.ndarray) -> dict[str, object]:
    ys, xs = np.nonzero(mask)
    left, top, max_x, bottom = int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())

    # The tail is the only part extending past the body's long vertical edge.
    row_right = np.full(mask.shape[0], np.nan)
    row_left = np.full(mask.shape[0], np.nan)
    for y in range(top, bottom + 1):
        filled = np.flatnonzero(mask[y])
        if filled.size:
            row_left[y] = filled.min()
            row_right[y] = filled.max()
    interior = row_right[top + 60 : max(top + 61, bottom - 60)]
    body_right = int(round(float(np.nanmedian(interior))))

    col_bottom = np.full(mask.shape[1], np.nan)
    col_top = np.full(mask.shape[1], np.nan)
    for x in range(left, body_right + 1):
        filled = np.flatnonzero(mask[:, x])
        if filled.size:
            col_top[x] = filled.min()
            col_bottom[x] = filled.max()
    body_bottom = int(
        round(float(np.nanmedian(col_bottom[left + 60 : max(left + 61, body_right - 60)])))
    )
    body_top = int(
        round(float(np.nanmedian(col_top[left + 60 : max(left + 61, body_right - 60)])))
    )

    contour_list, _ = cv2.findContours(
        mask.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE
    )
    contour = max(contour_list, key=cv2.contourArea)[:, 0, :]
    tail_points = contour[
        (contour[:, 0] >= body_right - 36) & (contour[:, 1] >= body_bottom - 48)
    ]

    return {
        "mask_bbox": [left, top, max_x, bottom],
        "body": {
            "left": left,
            "right": body_right,
            "top": body_top,
            "bottom": body_bottom,
            "width": body_right - left + 1,
            "height": body_bottom - body_top + 1,
        },
        "tail_tip": [max_x, bottom],
        "tail_points": tail_points.tolist(),
        "bottom_rows": {
            str(y): row_runs(mask[y])
            for y in range(max(top, body_bottom - 40), min(mask.shape[0], bottom + 2))
        },
    }


def cubic_point(
    p0: np.ndarray, c1: np.ndarray, c2: np.ndarray, p3: np.ndarray, t: np.ndarray
) -> np.ndarray:
    t = t[:, None]
    one_minus_t = 1.0 - t
    return (
        one_minus_t**3 * p0
        + 3.0 * one_minus_t**2 * t * c1
        + 3.0 * one_minus_t * t**2 * c2
        + t**3 * p3
    )


def fit_cubic(points: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    points = points.astype(np.float64)
    p0, p3 = points[0], points[-1]
    distances = np.linalg.norm(np.diff(points, axis=0), axis=1)
    cumulative = np.r_[0.0, np.cumsum(distances)]
    if cumulative[-1] <= 0.0:
        return p0, p0, p3, p3
    t = cumulative / cumulative[-1]
    a1 = 3.0 * (1.0 - t) ** 2 * t
    a2 = 3.0 * (1.0 - t) * t**2
    remainder = points - ((1.0 - t) ** 3)[:, None] * p0 - (t**3)[:, None] * p3
    matrix = np.column_stack([a1, a2])
    controls = np.linalg.lstsq(matrix, remainder, rcond=None)[0]
    return p0, controls[0], controls[1], p3


def ordered_tail_segments(
    mask: np.ndarray, report: dict[str, object]
) -> list[tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]]:
    body = report["body"]
    assert isinstance(body, dict)
    left = int(body["left"])
    right = int(body["right"])
    bottom = int(body["bottom"])

    contours, _ = cv2.findContours(
        mask.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE
    )
    contour = max(contours, key=cv2.contourArea)[:, 0, :].astype(np.float64)

    runs = row_runs(mask[bottom])
    if not runs:
        raise RuntimeError("Reference has no filled pixels on its body-bottom row")
    body_run = runs[0]
    bottom_join = np.array([body_run[1], bottom], dtype=np.float64)
    matching = np.flatnonzero(np.all(contour == bottom_join, axis=1))
    if matching.size == 0:
        raise RuntimeError("Could not locate bottom/tail join on contour")

    def walk(start: int, step: int, limit: int = 160) -> np.ndarray:
        return np.array(
            [contour[(start + step * offset) % len(contour)] for offset in range(limit)]
        )

    forward = walk(int(matching[0]), 1)
    backward = walk(int(matching[0]), -1)
    chain = forward if forward[:20, 0].max() > backward[:20, 0].max() else backward

    max_x = float(chain[:, 0].max())
    tip_candidates = np.flatnonzero(chain[:, 0] == max_x)
    tip_index = int(round(float(tip_candidates.mean())))

    outer_index = None
    for index in range(tip_index + 1, len(chain) - 6):
        if np.all(chain[index : index + 6, 0] == right):
            outer_index = index
            break
    if outer_index is None:
        raise RuntimeError("Could not locate tail/right-edge join on contour")

    inner_index = int(np.argmin(chain[: tip_index + 1, 1]))
    # OpenCV returns the centres of the last filled pixels. Move the ordered
    # bottom→right contour by a fitted subpixel outset so the smoothed cubics
    # reproduce the reference's 50% antialias silhouette.
    tangents = np.gradient(chain, axis=0)
    outward = np.column_stack([-tangents[:, 1], tangents[:, 0]])
    lengths = np.linalg.norm(outward, axis=1)
    lengths[lengths == 0.0] = 1.0
    chain = chain + CONTOUR_OUTSET * outward / lengths[:, None]
    raw_segments = [
        chain[: inner_index + 1],
        chain[inner_index : tip_index + 1],
        chain[tip_index : outer_index + 1],
    ]
    curves = [
        tuple(np.array(point, copy=True) for point in fit_cubic(segment))
        for segment in raw_segments
    ]

    # The screenshot is a low-resolution antialiased raster, so an unconstrained
    # least-squares fit leaves two tiny tangent kinks that only become obvious when
    # the curve is rendered at Retina scale.  Preserve the fitted silhouette while
    # making the two body joins analytically smooth: the outer tail leaves the body
    # vertically, and the lower curve meets the bubble bottom horizontally.
    corner, _, outer = curves
    outer[2][0] = outer[3][0]
    corner[1][1] = corner[0][1]
    return curves


def sample_cubic(curve: tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]) -> np.ndarray:
    return cubic_point(*curve, np.linspace(0.0, 1.0, 48))


def body_polygon(
    body: dict[str, object],
    primary_radius: float,
    tail_segments: list[tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]],
) -> np.ndarray:
    left = float(body["left"])
    right = float(body["right"]) + 0.5
    top = float(body["top"])
    bottom = float(body["bottom"]) + 0.5
    radius = primary_radius
    k = radius * CIRCLE_CUBIC

    def cubic(p0: tuple[float, float], c1: tuple[float, float], c2: tuple[float, float], p3: tuple[float, float]) -> np.ndarray:
        return cubic_point(
            np.array(p0), np.array(c1), np.array(c2), np.array(p3), np.linspace(0.0, 1.0, 48)
        )

    points: list[np.ndarray] = [np.array([[left + radius, top], [right - radius, top]])]
    points.append(
        cubic(
            (right - radius, top),
            (right - radius + k, top),
            (right, top + radius - k),
            (right, top + radius),
        )
    )

    # SVG/UI path runs down the right side, which is the reverse of the extracted
    # bottom→tail→right contour order.
    outer = tail_segments[2]
    inner = tail_segments[1]
    corner = tail_segments[0]
    points.append(np.vstack([np.array([right, top + radius]), outer[-1]]))
    points.append(sample_cubic(tuple(reversed(outer))))
    points.append(sample_cubic(tuple(reversed(inner))))
    points.append(sample_cubic(tuple(reversed(corner))))
    points.append(np.array([corner[0], [left + radius, bottom]], dtype=np.float64))
    points.append(
        cubic(
            (left + radius, bottom),
            (left + radius - k, bottom),
            (left, bottom - radius + k),
            (left, bottom - radius),
        )
    )
    points.append(np.array([[left, bottom - radius], [left, top + radius]]))
    points.append(
        cubic(
            (left, top + radius),
            (left, top + radius - k),
            (left + radius - k, top),
            (left + radius, top),
        )
    )
    return np.concatenate(points)


def rasterize_polygon(points: np.ndarray, shape: tuple[int, int], scale: int = 8) -> np.ndarray:
    height, width = shape
    canvas = np.zeros((height * scale, width * scale), dtype=np.uint8)
    scaled = np.round(points * scale).astype(np.int32)
    cv2.fillPoly(canvas, [scaled], 255, lineType=cv2.LINE_8)
    reduced = cv2.resize(canvas, (width, height), interpolation=cv2.INTER_AREA)
    return reduced >= 128


def corner_roi_mask(shape: tuple[int, int], body: dict[str, object], size: int = 44) -> np.ndarray:
    height, width = shape
    left, right = int(body["left"]), int(body["right"])
    top, bottom = int(body["top"]), int(body["bottom"])
    roi = np.zeros((height, width), dtype=bool)
    roi[max(0, top - 2) : min(height, top + size), max(0, left - 2) : min(width, left + size)] = True
    roi[max(0, top - 2) : min(height, top + size), max(0, right - size) : min(width, right + 3)] = True
    roi[max(0, bottom - size) : min(height, bottom + 3), max(0, left - 2) : min(width, left + size)] = True
    return roi


def choose_primary_radius(
    reference: np.ndarray,
    body: dict[str, object],
    tail_segments: list[tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]],
) -> float:
    roi = corner_roi_mask(reference.shape, body)
    best_radius = 0.0
    best_error = math.inf
    for radius in np.arange(18.0, 36.01, 0.05):
        candidate = rasterize_polygon(body_polygon(body, float(radius), tail_segments), reference.shape)
        error = int(np.count_nonzero((reference ^ candidate) & roi))
        if error < best_error:
            best_error = error
            best_radius = float(radius)
    return best_radius


def curve_svg(
    curve: tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray], reverse: bool = False
) -> str:
    _, c1, c2, p3 = tuple(reversed(curve)) if reverse else curve
    return f"C {c1[0]:.4f} {c1[1]:.4f} {c2[0]:.4f} {c2[1]:.4f} {p3[0]:.4f} {p3[1]:.4f}"


def svg_document(
    image_shape: tuple[int, int],
    body: dict[str, object],
    radius: float,
    tail_segments: list[tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]],
) -> str:
    height, width = image_shape
    left = float(body["left"])
    right = float(body["right"]) + 0.5
    top = float(body["top"])
    bottom = float(body["bottom"]) + 0.5
    k = radius * CIRCLE_CUBIC
    corner, inner, outer = tail_segments
    path = " ".join(
        [
            f"M {left + radius:.4f} {top:.4f}",
            f"L {right - radius:.4f} {top:.4f}",
            f"C {right - radius + k:.4f} {top:.4f} {right:.4f} {top + radius - k:.4f} {right:.4f} {top + radius:.4f}",
            f"L {outer[-1][0]:.4f} {outer[-1][1]:.4f}",
            curve_svg(outer, reverse=True),
            curve_svg(inner, reverse=True),
            curve_svg(corner, reverse=True),
            f"L {left + radius:.4f} {bottom:.4f}",
            f"C {left + radius - k:.4f} {bottom:.4f} {left:.4f} {bottom - radius + k:.4f} {left:.4f} {bottom - radius:.4f}",
            f"L {left:.4f} {top + radius:.4f}",
            f"C {left:.4f} {top + radius - k:.4f} {left + radius - k:.4f} {top:.4f} {left + radius:.4f} {top:.4f}",
            "Z",
        ]
    )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">\n'
        "  <!-- Cubic-only reference path; coordinates are screenshot pixels. -->\n"
        f'  <path fill="#1688F8" d="{path}"/>\n'
        "</svg>\n"
    )


def comparison_metrics(reference: np.ndarray, candidate: np.ndarray, body: dict[str, object]) -> dict[str, object]:
    intersection = int(np.count_nonzero(reference & candidate))
    union = int(np.count_nonzero(reference | candidate))
    right, bottom = int(body["right"]), int(body["bottom"])
    tail_roi = np.zeros_like(reference)
    tail_roi[max(0, bottom - 44) : bottom + 2, max(0, right - 36) :] = True
    tail_ref = reference & tail_roi
    tail_candidate = candidate & tail_roi
    tail_intersection = int(np.count_nonzero(tail_ref & tail_candidate))
    tail_union = int(np.count_nonzero(tail_ref | tail_candidate))

    ref_edge = reference ^ ndimage.binary_erosion(reference)
    candidate_edge = candidate ^ ndimage.binary_erosion(candidate)
    to_candidate = ndimage.distance_transform_edt(~candidate_edge)[ref_edge & tail_roi]
    to_reference = ndimage.distance_transform_edt(~ref_edge)[candidate_edge & tail_roi]
    distances = np.r_[to_candidate, to_reference]
    return {
        "full_iou": intersection / union,
        "full_mismatch_pixels": int(np.count_nonzero(reference ^ candidate)),
        "tail_iou": tail_intersection / tail_union,
        "tail_mismatch_pixels": int(np.count_nonzero((reference ^ candidate) & tail_roi)),
        "tail_contour_mean_distance_px": float(distances.mean()),
        "tail_contour_p95_distance_px": float(np.percentile(distances, 95)),
        "tail_contour_max_distance_px": float(distances.max()),
    }


def save_comparison(
    image: np.ndarray,
    reference: np.ndarray,
    candidate: np.ndarray,
    body: dict[str, object],
    output_dir: Path,
) -> None:
    overlay = image[..., :3].copy()
    ref_edge = reference ^ ndimage.binary_erosion(reference)
    candidate_edge = candidate ^ ndimage.binary_erosion(candidate)
    overlay[ref_edge] = [40, 220, 80]
    overlay[candidate_edge] = [255, 45, 60]
    overlay[ref_edge & candidate_edge] = [255, 220, 0]
    Image.fromarray(overlay).save(output_dir / "reference-overlay.png")

    diff = np.full((*reference.shape, 3), 255, dtype=np.uint8)
    diff[reference & candidate] = [235, 235, 235]
    diff[reference & ~candidate] = [40, 210, 80]
    diff[candidate & ~reference] = [255, 55, 70]
    Image.fromarray(diff).save(output_dir / "reference-diff.png")

    right, bottom = int(body["right"]), int(body["bottom"])
    y_slice = slice(max(0, bottom - 34), min(reference.shape[0], bottom + 3))
    x_slice = slice(max(0, right - 38), min(reference.shape[1], right + 14))
    Image.fromarray(overlay[y_slice, x_slice]).resize(
        (52 * 8, 37 * 8), Image.Resampling.NEAREST
    ).save(output_dir / "tail-overlay-8x.png")
    Image.fromarray(diff[y_slice, x_slice]).resize(
        (52 * 8, 37 * 8), Image.Resampling.NEAREST
    ).save(output_dir / "tail-diff-8x.png")


def save_mask(mask: np.ndarray, path: Path) -> None:
    Image.fromarray(np.where(mask, 255, 0).astype(np.uint8)).save(path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    image = np.array(Image.open(args.reference).convert("RGBA"))
    mask = extract_blue_bubble(image)
    report = analyze(mask)
    body = report["body"]
    assert isinstance(body, dict)
    tail_segments = ordered_tail_segments(mask, report)
    primary_radius = choose_primary_radius(mask, body, tail_segments)
    polygon = body_polygon(body, primary_radius, tail_segments)
    candidate = rasterize_polygon(polygon, mask.shape)
    metrics = comparison_metrics(mask, candidate, body)

    report["primary_radius_px"] = primary_radius
    report["tail_cubics_px"] = [
        {
            "start": curve[0].tolist(),
            "control1": curve[1].tolist(),
            "control2": curve[2].tolist(),
            "end": curve[3].tolist(),
        }
        for curve in tail_segments
    ]
    origin = np.array([float(body["right"]) + 0.5, float(body["bottom"]) + 0.5])
    base_scale = 18.0 / primary_radius
    ios_curves = [
        tuple((point - origin) * base_scale for point in reversed(curve))
        for curve in reversed(tail_segments)
    ]
    report["ios_tail_path_base18"] = {
        "origin": "bubble body bottom-trailing corner; x points outward, y points down",
        "curves_in_path_order": [
            {
                "start": curve[0].tolist(),
                "control1": curve[1].tolist(),
                "control2": curve[2].tolist(),
                "end": curve[3].tolist(),
            }
            for curve in ios_curves
        ],
        "horizontal_overhang": float(
            max(sample_cubic(curve)[:, 0].max() for curve in ios_curves)
        ),
        "bottom_overhang": float(
            max(sample_cubic(curve)[:, 1].max() for curve in ios_curves)
        ),
    }
    report["metrics"] = metrics
    save_mask(mask, args.output_dir / "reference-mask.png")
    save_mask(candidate, args.output_dir / "candidate-mask.png")
    save_comparison(image, mask, candidate, body, args.output_dir)
    (args.output_dir / "bubble-tail-reference.svg").write_text(
        svg_document(mask.shape, body, primary_radius, tail_segments), encoding="utf-8"
    )
    (args.output_dir / "reference-analysis.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    summary = dict(report)
    summary.pop("tail_points", None)
    summary.pop("bottom_rows", None)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

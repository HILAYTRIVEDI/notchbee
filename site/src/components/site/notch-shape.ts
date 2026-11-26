/**
 * The MacBook notch silhouette, the same geometry the app draws: concave "ears" where it meets the top edge,
 * straight sides and rounded bottom corners. `closed` adds the top edge so it can be filled.
 */
export function notchPath(width: number, height: number, ear = 8, radius = 18, closed = true) {
  const k = 0.5523;
  const e = Math.min(ear, width / 4, height / 2);
  const r = Math.min(radius, (width - 2 * e) / 2, height - e);
  const w = width;
  const h = height;
  const parts = [
    `M 0 0`,
    `C ${k * e} 0 ${e} ${e - k * e} ${e} ${e}`,
    `L ${e} ${h - r}`,
    `C ${e} ${h - r * (1 - k)} ${e + r * (1 - k)} ${h} ${e + r} ${h}`,
    `L ${w - e - r} ${h}`,
    `C ${w - e - r * (1 - k)} ${h} ${w - e} ${h - r * (1 - k)} ${w - e} ${h - r}`,
    `L ${w - e} ${e}`,
    `C ${w - e} ${e - k * e} ${w - k * e} 0 ${w} 0`,
  ];
  if (closed) parts.push("Z");
  return parts.join(" ");
}

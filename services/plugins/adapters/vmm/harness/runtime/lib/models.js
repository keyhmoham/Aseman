/**
 * The `aseman` LLM route's model names: one per context-window class. The
 * node serves each turn's own provider and model whatever the name; the name
 * tells dsh how large the window is (compaction, output reservation).
 */

export const ROUTE = 'aseman'
export const WINDOWS = [16000, 32000, 64000, 128000, 200000, 400000, 1000000]

/** The largest class that fits `window` (unknown: `fallback`). */
export function modelFor(window, fallback) {
  const w = Number(window) > 0 ? Number(window) : fallback
  const fit = [...WINDOWS].reverse().find((x) => x <= w) ?? WINDOWS[0]
  return `aseman-${fit >= 1000000 ? `${fit / 1000000}m` : `${fit / 1000}k`}`
}

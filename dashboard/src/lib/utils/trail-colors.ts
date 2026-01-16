/**
 * Trail color generation utilities for multi-shift visualization
 * Uses HSL color space with golden angle for maximum distinction
 */

import type { ShiftColorMapping } from '@/types/history';

// Golden angle in degrees for maximum color distribution
const GOLDEN_ANGLE = 137.5;

// Base saturation and lightness for trail colors
const SATURATION = 70;
const LIGHTNESS = 50;

// Dimmed versions for non-highlighted trails
const DIMMED_SATURATION = 30;
const DIMMED_LIGHTNESS = 70;

/**
 * Generate a distinct HSL color for a given index
 * Uses the golden angle to maximize visual distinction between colors
 */
export function generateTrailColor(index: number): string {
  const hue = (index * GOLDEN_ANGLE) % 360;
  return `hsl(${hue}, ${SATURATION}%, ${LIGHTNESS}%)`;
}

/**
 * Generate a dimmed version of a trail color
 * Used when another trail is highlighted
 */
export function getDimmedColor(index: number): string {
  const hue = (index * GOLDEN_ANGLE) % 360;
  return `hsl(${hue}, ${DIMMED_SATURATION}%, ${DIMMED_LIGHTNESS}%)`;
}

/**
 * Generate color mappings for a set of shifts
 */
export function generateShiftColorMappings(
  shifts: { id: string; date: string }[]
): ShiftColorMapping[] {
  return shifts.map((shift, index) => ({
    shiftId: shift.id,
    shiftDate: shift.date,
    color: generateTrailColor(index),
  }));
}

/**
 * Get a color for a shift from a mapping array
 */
export function getShiftColor(
  shiftId: string,
  mappings: ShiftColorMapping[]
): string {
  const mapping = mappings.find((m) => m.shiftId === shiftId);
  return mapping?.color ?? generateTrailColor(0);
}

/**
 * Get the color index for a shift
 * Used for consistent dimming when highlighting
 */
export function getShiftColorIndex(
  shiftId: string,
  mappings: ShiftColorMapping[]
): number {
  return mappings.findIndex((m) => m.shiftId === shiftId);
}

/**
 * Predefined color palette for up to 7 shifts
 * Provides more distinguishable colors than pure golden angle
 */
export const TRAIL_COLOR_PALETTE = [
  'hsl(220, 70%, 50%)', // Blue
  'hsl(25, 70%, 50%)',  // Orange
  'hsl(140, 70%, 40%)', // Green
  'hsl(340, 70%, 50%)', // Pink/Red
  'hsl(280, 70%, 50%)', // Purple
  'hsl(180, 70%, 40%)', // Teal
  'hsl(45, 70%, 50%)',  // Yellow-Orange
] as const;

/**
 * Get a color from the predefined palette, with fallback to generated colors
 */
export function getTrailColorFromPalette(index: number): string {
  if (index < TRAIL_COLOR_PALETTE.length) {
    return TRAIL_COLOR_PALETTE[index];
  }
  return generateTrailColor(index);
}

/**
 * Convert HSL string to hex (for export/external use)
 */
export function hslToHex(hslString: string): string {
  const match = hslString.match(/hsl\((\d+),\s*(\d+)%,\s*(\d+)%\)/);
  if (!match) return '#3b82f6'; // Default blue

  const h = parseInt(match[1]) / 360;
  const s = parseInt(match[2]) / 100;
  const l = parseInt(match[3]) / 100;

  let r, g, b;

  if (s === 0) {
    r = g = b = l;
  } else {
    const hue2rgb = (p: number, q: number, t: number) => {
      if (t < 0) t += 1;
      if (t > 1) t -= 1;
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    };

    const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    const p = 2 * l - q;
    r = hue2rgb(p, q, h + 1 / 3);
    g = hue2rgb(p, q, h);
    b = hue2rgb(p, q, h - 1 / 3);
  }

  const toHex = (x: number) => {
    const hex = Math.round(x * 255).toString(16);
    return hex.length === 1 ? '0' + hex : hex;
  };

  return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
}

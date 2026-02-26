'use client';

import { format, parseISO } from 'date-fns';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Eye, EyeOff } from 'lucide-react';
import type { ShiftColorMapping, MultiShiftGpsPoint } from '@/types/history';
import { getTrailColorFromPalette } from '@/lib/utils/trail-colors';

interface ShiftLegendProps {
  colorMappings: ShiftColorMapping[];
  trailsByShift: Map<string, MultiShiftGpsPoint[]>;
  highlightedShiftId?: string | null;
  onShiftHighlight?: (shiftId: string | null) => void;
}

/**
 * Legend component showing shift date-to-color mapping.
 * Allows clicking to highlight individual shifts on the map.
 */
export function ShiftLegend({
  colorMappings,
  trailsByShift,
  highlightedShiftId,
  onShiftHighlight,
}: ShiftLegendProps) {
  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="text-base font-medium flex items-center justify-between">
          <span>Légende des quarts</span>
          {highlightedShiftId && onShiftHighlight && (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => onShiftHighlight(null)}
            >
              <EyeOff className="h-4 w-4 mr-2" />
              Effacer la sélection
            </Button>
          )}
        </CardTitle>
      </CardHeader>
      <CardContent>
        <div className="space-y-2">
          {colorMappings.map((mapping, index) => {
            const trail = trailsByShift.get(mapping.shiftId) ?? [];
            const pointCount = trail.length;
            const isHighlighted = highlightedShiftId === mapping.shiftId;
            const color = getTrailColorFromPalette(index);

            // Parse the date string safely
            let formattedDate = mapping.shiftDate;
            try {
              const date = parseISO(mapping.shiftDate);
              formattedDate = format(date, 'EEEE, MMM d');
            } catch {
              // Keep original string if parsing fails
            }

            return (
              <button
                key={mapping.shiftId}
                onClick={() => onShiftHighlight?.(isHighlighted ? null : mapping.shiftId)}
                className={`w-full flex items-center justify-between p-3 rounded-lg transition-colors ${
                  isHighlighted
                    ? 'bg-slate-100 ring-2 ring-slate-300'
                    : 'hover:bg-slate-50'
                }`}
              >
                <div className="flex items-center gap-3">
                  {/* Color indicator */}
                  <div
                    className="h-4 w-4 rounded-full flex-shrink-0"
                    style={{ backgroundColor: color }}
                  />
                  {/* Date */}
                  <span className="text-sm font-medium text-slate-700">
                    {formattedDate}
                  </span>
                </div>

                <div className="flex items-center gap-2">
                  {/* Point count */}
                  <Badge variant="secondary" className="font-mono text-xs">
                    {pointCount.toLocaleString()} pts
                  </Badge>
                  {/* Highlight indicator */}
                  {isHighlighted && (
                    <Eye className="h-4 w-4 text-slate-500" />
                  )}
                </div>
              </button>
            );
          })}
        </div>

        {colorMappings.length === 0 && (
          <p className="text-sm text-slate-500 text-center py-4">
            Aucun quart sélectionné
          </p>
        )}

        {colorMappings.length > 0 && (
          <p className="text-xs text-slate-500 mt-4 text-center">
            Cliquez sur un quart pour le mettre en surbrillance sur la carte
          </p>
        )}
      </CardContent>
    </Card>
  );
}

'use client';

import { useState, useCallback } from 'react';
import { Download, FileText, Map, Loader2 } from 'lucide-react';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import type { HistoricalGpsPoint, MultiShiftGpsPoint, GpsExportMetadata } from '@/types/history';
import {
  exportToCsv,
  exportToGeoJson,
  exportMultiShiftToCsv,
  exportMultiShiftToGeoJson,
  isLargeExport,
} from '@/lib/utils/export-gps';

type ExportFormat = 'csv' | 'geojson';

interface ExportDialogProps {
  /** Single shift trail for export */
  trail?: HistoricalGpsPoint[];
  /** Multi-shift trails for export */
  trailsByShift?: Map<string, MultiShiftGpsPoint[]>;
  /** Export metadata */
  metadata: GpsExportMetadata;
  /** Trigger button label */
  buttonLabel?: string;
  /** Trigger button variant */
  buttonVariant?: 'default' | 'outline' | 'secondary' | 'ghost';
}

/**
 * Export dialog component with format selection and progress indicator
 */
export function ExportDialog({
  trail,
  trailsByShift,
  metadata,
  buttonLabel = 'Exporter',
  buttonVariant = 'outline',
}: ExportDialogProps) {
  const [isOpen, setIsOpen] = useState(false);
  const [selectedFormat, setSelectedFormat] = useState<ExportFormat>('csv');
  const [isExporting, setIsExporting] = useState(false);
  const [progress, setProgress] = useState(0);

  // Determine if this is a multi-shift export
  const isMultiShift = !!trailsByShift && trailsByShift.size > 0;

  // Get total point count
  const pointCount = trail?.length ?? metadata.totalPoints;

  // Check if large export
  const showProgress = isLargeExport(pointCount);

  // Handle export
  const handleExport = useCallback(() => {
    setIsExporting(true);
    setProgress(0);

    // Use setTimeout to allow UI to update
    setTimeout(() => {
      try {
        const progressCallback = showProgress ? setProgress : undefined;

        if (isMultiShift && trailsByShift) {
          // Multi-shift export
          if (selectedFormat === 'csv') {
            exportMultiShiftToCsv(trailsByShift, metadata, progressCallback);
          } else {
            exportMultiShiftToGeoJson(trailsByShift, metadata, progressCallback);
          }
        } else if (trail) {
          // Single shift export
          if (selectedFormat === 'csv') {
            exportToCsv(trail, metadata, progressCallback);
          } else {
            exportToGeoJson(trail, metadata, progressCallback);
          }
        }

        setIsExporting(false);
        setIsOpen(false);
      } catch (error) {
        console.error('Export failed:', error);
        setIsExporting(false);
      }
    }, 100);
  }, [selectedFormat, trail, trailsByShift, metadata, isMultiShift, showProgress]);

  return (
    <Dialog open={isOpen} onOpenChange={setIsOpen}>
      <DialogTrigger asChild>
        <Button variant={buttonVariant}>
          <Download className="h-4 w-4 mr-2" />
          {buttonLabel}
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-[425px]">
        <DialogHeader>
          <DialogTitle>Exporter les données GPS</DialogTitle>
          <DialogDescription>
            Télécharger les données de tracé GPS dans votre format préféré.
            {isMultiShift && ` Inclut ${trailsByShift?.size} quarts.`}
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-4 py-4">
          {/* Format selection */}
          <div className="space-y-3">
            <Label>Sélectionner le format</Label>

            <div className="grid grid-cols-2 gap-3">
              {/* CSV option */}
              <button
                onClick={() => setSelectedFormat('csv')}
                className={`flex flex-col items-center gap-2 p-4 rounded-lg border-2 transition-colors ${
                  selectedFormat === 'csv'
                    ? 'border-blue-500 bg-blue-50'
                    : 'border-slate-200 hover:border-slate-300'
                }`}
                disabled={isExporting}
              >
                <FileText
                  className={`h-8 w-8 ${
                    selectedFormat === 'csv' ? 'text-blue-600' : 'text-slate-400'
                  }`}
                />
                <span
                  className={`text-sm font-medium ${
                    selectedFormat === 'csv' ? 'text-blue-700' : 'text-slate-600'
                  }`}
                >
                  CSV
                </span>
                <span className="text-xs text-slate-500">Tableur</span>
              </button>

              {/* GeoJSON option */}
              <button
                onClick={() => setSelectedFormat('geojson')}
                className={`flex flex-col items-center gap-2 p-4 rounded-lg border-2 transition-colors ${
                  selectedFormat === 'geojson'
                    ? 'border-blue-500 bg-blue-50'
                    : 'border-slate-200 hover:border-slate-300'
                }`}
                disabled={isExporting}
              >
                <Map
                  className={`h-8 w-8 ${
                    selectedFormat === 'geojson' ? 'text-blue-600' : 'text-slate-400'
                  }`}
                />
                <span
                  className={`text-sm font-medium ${
                    selectedFormat === 'geojson' ? 'text-blue-700' : 'text-slate-600'
                  }`}
                >
                  GeoJSON
                </span>
                <span className="text-xs text-slate-500">Géographique</span>
              </button>
            </div>
          </div>

          {/* Export summary */}
          <div className="text-sm text-slate-500 bg-slate-50 rounded-lg p-3">
            <p>
              <strong>{pointCount.toLocaleString()}</strong> points GPS seront exportés
            </p>
            {showProgress && (
              <p className="text-xs mt-1 text-amber-600">
                Export volumineux - cela peut prendre un moment
              </p>
            )}
          </div>

          {/* Progress indicator for large exports */}
          {isExporting && showProgress && (
            <div className="space-y-2">
              <div className="h-2 bg-slate-100 rounded-full overflow-hidden">
                <div
                  className="h-full bg-blue-500 transition-all duration-300"
                  style={{ width: `${progress}%` }}
                />
              </div>
              <p className="text-xs text-center text-slate-500">
                Exportation... {Math.round(progress)}%
              </p>
            </div>
          )}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => setIsOpen(false)} disabled={isExporting}>
            Annuler
          </Button>
          <Button onClick={handleExport} disabled={isExporting}>
            {isExporting ? (
              <>
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                Exportation...
              </>
            ) : (
              <>
                <Download className="h-4 w-4 mr-2" />
                Télécharger {selectedFormat.toUpperCase()}
              </>
            )}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

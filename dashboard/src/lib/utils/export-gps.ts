/**
 * GPS Data Export Utilities
 * Provides CSV and GeoJSON export functionality for GPS trail data
 */

import type {
  HistoricalGpsPoint,
  MultiShiftGpsPoint,
  GpsExportMetadata,
} from '@/types/history';
import { format } from 'date-fns';

/**
 * Progress callback for large exports
 */
type ProgressCallback = (progress: number) => void;

// Chunk size for processing large exports
const CHUNK_SIZE = 1000;

/**
 * Export GPS trail to CSV format
 * Includes metadata header with shift/employee information
 */
export function exportToCsv(
  points: HistoricalGpsPoint[],
  metadata: GpsExportMetadata,
  onProgress?: ProgressCallback
): void {
  // Build metadata header
  const metadataLines = [
    `# Exportation du tracé GPS`,
    `# Employé : ${metadata.employeeName} (${metadata.employeeId})`,
    `# Période : ${metadata.dateRange}`,
    `# Distance totale : ${metadata.totalDistanceKm.toFixed(2)} km`,
    `# Nombre de points : ${metadata.totalPoints}`,
    `# Généré le : ${metadata.generatedAt}`,
    `#`,
  ];

  // CSV header
  const csvHeader = 'timestamp,latitude,longitude,accuracy_meters';

  // Build data rows
  const rows: string[] = [];

  for (let i = 0; i < points.length; i++) {
    const point = points[i];
    const row = [
      point.capturedAt.toISOString(),
      point.latitude.toFixed(8),
      point.longitude.toFixed(8),
      point.accuracy?.toFixed(2) ?? '',
    ].join(',');
    rows.push(row);

    // Report progress for large exports
    if (onProgress && i % CHUNK_SIZE === 0) {
      onProgress((i / points.length) * 100);
    }
  }

  // Combine all content
  const content = [...metadataLines, csvHeader, ...rows].join('\n');

  // Create and download file
  downloadFile(content, 'text/csv', generateFilename(metadata, 'csv'));

  onProgress?.(100);
}

/**
 * Export GPS trail to GeoJSON format
 * Creates a FeatureCollection with a single LineString feature
 */
export function exportToGeoJson(
  points: HistoricalGpsPoint[],
  metadata: GpsExportMetadata,
  onProgress?: ProgressCallback
): void {
  // Build coordinates array
  const coordinates: [number, number][] = [];
  const timestamps: string[] = [];

  for (let i = 0; i < points.length; i++) {
    const point = points[i];
    // GeoJSON uses [longitude, latitude] order
    coordinates.push([point.longitude, point.latitude]);
    timestamps.push(point.capturedAt.toISOString());

    // Report progress
    if (onProgress && i % CHUNK_SIZE === 0) {
      onProgress((i / points.length) * 80);
    }
  }

  const geojson = {
    type: 'FeatureCollection',
    metadata: {
      employee_name: metadata.employeeName,
      employee_id: metadata.employeeId,
      date_range: metadata.dateRange,
      total_distance_km: metadata.totalDistanceKm,
      total_points: metadata.totalPoints,
      generated_at: metadata.generatedAt,
    },
    features: [
      {
        type: 'Feature',
        geometry: {
          type: 'LineString',
          coordinates,
        },
        properties: {
          timestamps,
          point_count: points.length,
        },
      },
    ],
  };

  const content = JSON.stringify(geojson, null, 2);
  downloadFile(content, 'application/geo+json', generateFilename(metadata, 'geojson'));

  onProgress?.(100);
}

/**
 * Export multiple shift trails to CSV format
 * Groups data by shift ID with shift information
 */
export function exportMultiShiftToCsv(
  trailsByShift: Map<string, MultiShiftGpsPoint[]>,
  metadata: GpsExportMetadata,
  onProgress?: ProgressCallback
): void {
  // Build metadata header
  const metadataLines = [
    `# Exportation du tracé GPS multi-quarts`,
    `# Employé : ${metadata.employeeName} (${metadata.employeeId})`,
    `# Période : ${metadata.dateRange}`,
    `# Nombre de points : ${metadata.totalPoints}`,
    `# Généré le : ${metadata.generatedAt}`,
    `#`,
  ];

  // CSV header
  const csvHeader = 'shift_id,shift_date,timestamp,latitude,longitude,accuracy_meters';

  // Build data rows
  const rows: string[] = [];
  let processedCount = 0;
  const totalPoints = metadata.totalPoints;

  trailsByShift.forEach((points, shiftId) => {
    for (const point of points) {
      const row = [
        shiftId,
        point.shiftDate,
        point.capturedAt.toISOString(),
        point.latitude.toFixed(8),
        point.longitude.toFixed(8),
        point.accuracy?.toFixed(2) ?? '',
      ].join(',');
      rows.push(row);

      processedCount++;
      if (onProgress && processedCount % CHUNK_SIZE === 0) {
        onProgress((processedCount / totalPoints) * 100);
      }
    }
  });

  // Combine all content
  const content = [...metadataLines, csvHeader, ...rows].join('\n');

  downloadFile(content, 'text/csv', generateFilename(metadata, 'csv'));
  onProgress?.(100);
}

/**
 * Export multiple shift trails to GeoJSON format
 * Creates separate LineString features for each shift
 */
export function exportMultiShiftToGeoJson(
  trailsByShift: Map<string, MultiShiftGpsPoint[]>,
  metadata: GpsExportMetadata,
  onProgress?: ProgressCallback
): void {
  const features: object[] = [];
  let processedCount = 0;
  const totalPoints = metadata.totalPoints;

  trailsByShift.forEach((points, shiftId) => {
    if (points.length === 0) return;

    const coordinates: [number, number][] = [];
    const timestamps: string[] = [];

    for (const point of points) {
      coordinates.push([point.longitude, point.latitude]);
      timestamps.push(point.capturedAt.toISOString());

      processedCount++;
      if (onProgress && processedCount % CHUNK_SIZE === 0) {
        onProgress((processedCount / totalPoints) * 80);
      }
    }

    features.push({
      type: 'Feature',
      geometry: {
        type: 'LineString',
        coordinates,
      },
      properties: {
        shift_id: shiftId,
        shift_date: points[0].shiftDate,
        timestamps,
        point_count: points.length,
      },
    });
  });

  const geojson = {
    type: 'FeatureCollection',
    metadata: {
      employee_name: metadata.employeeName,
      employee_id: metadata.employeeId,
      date_range: metadata.dateRange,
      total_points: metadata.totalPoints,
      shift_count: features.length,
      generated_at: metadata.generatedAt,
    },
    features,
  };

  const content = JSON.stringify(geojson, null, 2);
  downloadFile(content, 'application/geo+json', generateFilename(metadata, 'geojson'));

  onProgress?.(100);
}

/**
 * Generate filename for export
 */
function generateFilename(
  metadata: GpsExportMetadata,
  extension: 'csv' | 'geojson'
): string {
  const safeName = metadata.employeeName.replace(/[^a-z0-9]/gi, '_').toLowerCase();
  const date = format(new Date(), 'yyyy-MM-dd');
  return `gps_trail_${safeName}_${date}.${extension}`;
}

/**
 * Trigger file download in browser
 */
function downloadFile(content: string, mimeType: string, filename: string): void {
  const blob = new Blob([content], { type: mimeType });
  const url = URL.createObjectURL(blob);

  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();

  // Cleanup
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
}

/**
 * Check if export is considered "large" (>10,000 points)
 */
export function isLargeExport(pointCount: number): boolean {
  return pointCount > 10000;
}

'use client';

import { useState, useMemo } from 'react';
import { format } from 'date-fns';
import { MapPinOff, ChevronUp, ChevronDown } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import type { HistoricalGpsPoint } from '@/types/history';

interface GpsTrailTableProps {
  trail: HistoricalGpsPoint[];
  title?: string;
  showRetryButton?: boolean;
  onRetry?: () => void;
}

type SortField = 'time' | 'latitude' | 'longitude' | 'accuracy';
type SortDirection = 'asc' | 'desc';

/**
 * Fallback table view for GPS trail data when map fails to load.
 * Provides sortable columns and displays all GPS point details.
 */
export function GpsTrailTable({
  trail,
  title = 'Données du tracé GPS',
  showRetryButton = false,
  onRetry,
}: GpsTrailTableProps) {
  const [sortField, setSortField] = useState<SortField>('time');
  const [sortDirection, setSortDirection] = useState<SortDirection>('asc');

  // Handle sort
  const handleSort = (field: SortField) => {
    if (sortField === field) {
      setSortDirection((d) => (d === 'asc' ? 'desc' : 'asc'));
    } else {
      setSortField(field);
      setSortDirection('asc');
    }
  };

  // Sort trail data
  const sortedTrail = useMemo(() => {
    return [...trail].sort((a, b) => {
      let comparison = 0;

      switch (sortField) {
        case 'time':
          comparison = a.capturedAt.getTime() - b.capturedAt.getTime();
          break;
        case 'latitude':
          comparison = a.latitude - b.latitude;
          break;
        case 'longitude':
          comparison = a.longitude - b.longitude;
          break;
        case 'accuracy':
          comparison = (a.accuracy ?? 0) - (b.accuracy ?? 0);
          break;
      }

      return sortDirection === 'asc' ? comparison : -comparison;
    });
  }, [trail, sortField, sortDirection]);

  const SortIcon = ({ field }: { field: SortField }) => {
    if (sortField !== field) return null;
    return sortDirection === 'asc' ? (
      <ChevronUp className="h-4 w-4 inline ml-1" />
    ) : (
      <ChevronDown className="h-4 w-4 inline ml-1" />
    );
  };

  if (trail.length === 0) {
    return (
      <Card>
        <CardHeader className="pb-2">
          <CardTitle className="text-base font-medium">{title}</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="py-8 text-center text-slate-500">
            <MapPinOff className="h-10 w-10 mx-auto mb-3 text-slate-300" />
            <p className="font-medium">Aucune donnée GPS disponible</p>
          </div>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader className="pb-2">
        <div className="flex items-center justify-between">
          <CardTitle className="text-base font-medium">{title}</CardTitle>
          <div className="flex items-center gap-2">
            <span className="text-sm text-slate-500">
              {trail.length} point{trail.length !== 1 ? 's' : ''}
            </span>
            {showRetryButton && onRetry && (
              <Button variant="outline" size="sm" onClick={onRetry}>
                Réessayer la carte
              </Button>
            )}
          </div>
        </div>
      </CardHeader>
      <CardContent className="p-0">
        <div className="overflow-x-auto max-h-[400px]">
          <Table>
            <TableHeader className="sticky top-0 bg-white">
              <TableRow>
                <TableHead
                  className="cursor-pointer select-none"
                  onClick={() => handleSort('time')}
                >
                  Heure
                  <SortIcon field="time" />
                </TableHead>
                <TableHead
                  className="cursor-pointer select-none"
                  onClick={() => handleSort('latitude')}
                >
                  Latitude
                  <SortIcon field="latitude" />
                </TableHead>
                <TableHead
                  className="cursor-pointer select-none"
                  onClick={() => handleSort('longitude')}
                >
                  Longitude
                  <SortIcon field="longitude" />
                </TableHead>
                <TableHead
                  className="cursor-pointer select-none"
                  onClick={() => handleSort('accuracy')}
                >
                  Précision
                  <SortIcon field="accuracy" />
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {sortedTrail.map((point) => (
                <TableRow key={point.id}>
                  <TableCell className="font-mono text-sm">
                    {format(point.capturedAt, 'h:mm:ss a')}
                  </TableCell>
                  <TableCell className="font-mono text-sm">
                    {point.latitude.toFixed(6)}
                  </TableCell>
                  <TableCell className="font-mono text-sm">
                    {point.longitude.toFixed(6)}
                  </TableCell>
                  <TableCell className="font-mono text-sm">
                    {point.accuracy !== null ? `±${Math.round(point.accuracy)}m` : '—'}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      </CardContent>
    </Card>
  );
}

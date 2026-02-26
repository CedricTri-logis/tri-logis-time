'use client';

import { useState, useEffect, useMemo } from 'react';
import Link from 'next/link';
import { format, subDays } from 'date-fns';
import { ArrowLeft, Download, AlertCircle } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Badge } from '@/components/ui/badge';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Skeleton } from '@/components/ui/skeleton';
import {
  useSupervisedEmployees,
  useShiftHistory,
  useMultiShiftTrails,
} from '@/lib/hooks/use-historical-gps';
import { GoogleMultiShiftMap } from '@/components/history/google-multi-shift-map';
import { ShiftLegend } from '@/components/history/shift-legend';
import { ExportDialog } from '@/components/history/export-dialog';
import { MapErrorBoundary } from '@/components/history/map-error-boundary';
import type { ShiftColorMapping, GpsExportMetadata } from '@/types/history';
import { getTrailColorFromPalette } from '@/lib/utils/trail-colors';

export default function MultiShiftViewPage() {
  // Default date range: last 7 days
  const today = new Date();
  const [startDate, setStartDate] = useState(format(subDays(today, 7), 'yyyy-MM-dd'));
  const [endDate, setEndDate] = useState(format(today, 'yyyy-MM-dd'));
  const [selectedEmployeeId, setSelectedEmployeeId] = useState<string | null>(null);
  const [highlightedShiftId, setHighlightedShiftId] = useState<string | null>(null);

  // Fetch supervised employees
  const { employees, isLoading: employeesLoading } = useSupervisedEmployees();

  // Auto-select first employee
  useEffect(() => {
    if (!selectedEmployeeId && employees.length > 0) {
      setSelectedEmployeeId(employees[0].id);
    }
  }, [employees, selectedEmployeeId]);

  // Fetch shifts for employee
  const { shifts, isLoading: shiftsLoading } = useShiftHistory({
    employeeId: selectedEmployeeId,
    startDate,
    endDate,
  });

  // Get shift IDs (max 10)
  const shiftIds = useMemo(() => {
    return shifts.slice(0, 10).map((s) => s.id);
  }, [shifts]);

  // Fetch GPS trails for all shifts
  const { trailsByShift, isLoading: trailsLoading } = useMultiShiftTrails(shiftIds);

  // Generate color mappings
  const colorMappings: ShiftColorMapping[] = useMemo(() => {
    return shifts.slice(0, 10).map((shift, index) => ({
      shiftId: shift.id,
      shiftDate: format(shift.clockedInAt, 'yyyy-MM-dd'),
      color: getTrailColorFromPalette(index),
    }));
  }, [shifts]);

  // Get current employee name
  const selectedEmployee = employees.find((e) => e.id === selectedEmployeeId);

  const isLoading = employeesLoading || shiftsLoading || trailsLoading;

  // Calculate total points across all trails
  const totalPoints = useMemo(() => {
    let count = 0;
    trailsByShift.forEach((trail) => {
      count += trail.length;
    });
    return count;
  }, [trailsByShift]);

  // Build export metadata
  const exportMetadata: GpsExportMetadata = useMemo(() => {
    return {
      employeeName: selectedEmployee?.fullName ?? 'Inconnu',
      employeeId: selectedEmployeeId ?? '',
      dateRange: `${startDate} au ${endDate}`,
      totalDistanceKm: 0, // Would need calculation
      totalPoints,
      generatedAt: new Date().toISOString(),
    };
  }, [selectedEmployee, selectedEmployeeId, startDate, endDate, totalPoints]);

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-4">
          <Link href="/dashboard/history">
            <Button variant="ghost" size="icon">
              <ArrowLeft className="h-4 w-4" />
            </Button>
          </Link>
          <div>
            <h1 className="text-2xl font-bold text-slate-900">Vue GPS multi-jours</h1>
            <p className="text-sm text-slate-500 mt-1">
              Voir les tracés GPS sur plusieurs quarts
            </p>
          </div>
        </div>

        {/* Export button */}
        {totalPoints > 0 && (
          <ExportDialog
            trailsByShift={trailsByShift}
            metadata={exportMetadata}
            buttonLabel="Tout exporter"
          />
        )}
      </div>

      {/* Filters */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base font-medium">Filtres</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="grid gap-4 md:grid-cols-3">
            {/* Employee selector */}
            <div className="space-y-1.5">
              <label className="text-sm font-medium text-slate-700">Employé</label>
              <Select
                value={selectedEmployeeId ?? ''}
                onValueChange={setSelectedEmployeeId}
                disabled={employeesLoading}
              >
                <SelectTrigger>
                  <SelectValue placeholder="Sélectionner un employé" />
                </SelectTrigger>
                <SelectContent>
                  {employees.map((emp) => (
                    <SelectItem key={emp.id} value={emp.id}>
                      {emp.fullName}
                      {emp.employeeId && (
                        <span className="text-slate-400 ml-1">({emp.employeeId})</span>
                      )}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            {/* Start date */}
            <div className="space-y-1.5">
              <label className="text-sm font-medium text-slate-700">Date de début</label>
              <Input
                type="date"
                value={startDate}
                onChange={(e) => setStartDate(e.target.value)}
                max={endDate}
              />
            </div>

            {/* End date */}
            <div className="space-y-1.5">
              <label className="text-sm font-medium text-slate-700">Date de fin</label>
              <Input
                type="date"
                value={endDate}
                onChange={(e) => setEndDate(e.target.value)}
                min={startDate}
                max={format(new Date(), 'yyyy-MM-dd')}
              />
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Warning for too many shifts */}
      {shifts.length > 10 && (
        <div className="flex items-center gap-3 p-4 bg-amber-50 border border-amber-200 rounded-lg text-sm text-amber-800">
          <AlertCircle className="h-5 w-5 flex-shrink-0" />
          <span>
            Affichage des 10 premiers quarts sur {shifts.length}. Réduisez la plage de dates pour voir
            tous les quarts.
          </span>
        </div>
      )}

      {/* Loading state */}
      {isLoading && (
        <div className="grid gap-6 md:grid-cols-[1fr_300px]">
          <Skeleton className="h-[500px] w-full" />
          <Skeleton className="h-[400px] w-full" />
        </div>
      )}

      {/* Map and Legend */}
      {!isLoading && shifts.length > 0 && (
        <div className="grid gap-6 md:grid-cols-[1fr_300px]">
          <MapErrorBoundary>
            <GoogleMultiShiftMap
              trailsByShift={trailsByShift}
              colorMappings={colorMappings}
              highlightedShiftId={highlightedShiftId}
              onShiftHighlight={setHighlightedShiftId}
            />
          </MapErrorBoundary>
          <ShiftLegend
            colorMappings={colorMappings}
            trailsByShift={trailsByShift}
            highlightedShiftId={highlightedShiftId}
            onShiftHighlight={setHighlightedShiftId}
          />
        </div>
      )}

      {/* Empty state */}
      {!isLoading && shifts.length === 0 && selectedEmployeeId && (
        <Card>
          <CardContent className="py-12 text-center">
            <p className="text-slate-500">
              Aucun quart terminé trouvé pour {selectedEmployee?.fullName} dans cette plage
              de dates.
            </p>
          </CardContent>
        </Card>
      )}

      {/* Summary stats */}
      {!isLoading && shifts.length > 0 && (
        <Card>
          <CardContent className="py-4">
            <div className="flex items-center justify-center gap-8 text-sm">
              <div className="text-center">
                <p className="text-2xl font-bold text-slate-900">{shifts.length}</p>
                <p className="text-slate-500">Quarts</p>
              </div>
              <div className="text-center">
                <p className="text-2xl font-bold text-slate-900">
                  {totalPoints.toLocaleString()}
                </p>
                <p className="text-slate-500">Points GPS</p>
              </div>
              <div className="text-center">
                <p className="text-2xl font-bold text-slate-900">
                  {Math.round(
                    shifts.reduce((sum, s) => sum + s.durationMinutes, 0) / 60
                  )}h
                </p>
                <p className="text-slate-500">Temps total</p>
              </div>
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}

'use client';

import { useState, useMemo } from 'react';
import Link from 'next/link';
import { format, subDays } from 'date-fns';
import { MapPin, Clock, Navigation, ChevronRight, Search } from 'lucide-react';
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
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Skeleton } from '@/components/ui/skeleton';
import type { ShiftHistorySummary, SupervisedEmployee } from '@/types/history';
import { formatDistance } from '@/lib/utils/distance';

interface ShiftHistoryTableProps {
  shifts: ShiftHistorySummary[];
  employees: SupervisedEmployee[];
  selectedEmployeeId: string | null;
  onEmployeeChange: (employeeId: string | null) => void;
  startDate: string;
  endDate: string;
  onStartDateChange: (date: string) => void;
  onEndDateChange: (date: string) => void;
  isLoading?: boolean;
}

export function ShiftHistoryTable({
  shifts,
  employees,
  selectedEmployeeId,
  onEmployeeChange,
  startDate,
  endDate,
  onStartDateChange,
  onEndDateChange,
  isLoading,
}: ShiftHistoryTableProps) {
  const [search, setSearch] = useState('');

  // Filter shifts by search term
  const filteredShifts = useMemo(() => {
    if (!search.trim()) return shifts;
    const term = search.toLowerCase();
    return shifts.filter(
      (shift) =>
        shift.employeeName?.toLowerCase().includes(term) ||
        shift.employeeEmail?.toLowerCase().includes(term) ||
        format(shift.clockedInAt, 'MMM d, yyyy').toLowerCase().includes(term)
    );
  }, [shifts, search]);

  // Format duration as hours and minutes
  const formatDuration = (minutes: number): string => {
    const hours = Math.floor(minutes / 60);
    const mins = minutes % 60;
    if (hours === 0) return `${mins}m`;
    return `${hours}h ${mins}m`;
  };

  return (
    <div className="space-y-4">
      {/* Filters */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base font-medium">Filtres</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="grid gap-4 md:grid-cols-4">
            {/* Employee filter */}
            <div className="space-y-1.5">
              <label className="text-sm font-medium text-slate-700">Employé</label>
              <Select
                value={selectedEmployeeId ?? 'all'}
                onValueChange={(value) =>
                  onEmployeeChange(value === 'all' ? null : value)
                }
              >
                <SelectTrigger>
                  <SelectValue placeholder="Sélectionner un employé" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="all">Tous les employés</SelectItem>
                  {employees.map((emp) => (
                    <SelectItem key={emp.id} value={emp.id}>
                      {emp.fullName || emp.email || 'Inconnu'}
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
                onChange={(e) => onStartDateChange(e.target.value)}
                max={endDate}
              />
            </div>

            {/* End date */}
            <div className="space-y-1.5">
              <label className="text-sm font-medium text-slate-700">Date de fin</label>
              <Input
                type="date"
                value={endDate}
                onChange={(e) => onEndDateChange(e.target.value)}
                min={startDate}
                max={format(new Date(), 'yyyy-MM-dd')}
              />
            </div>

            {/* Search */}
            <div className="space-y-1.5">
              <label className="text-sm font-medium text-slate-700">Rechercher</label>
              <div className="relative">
                <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-slate-400" />
                <Input
                  placeholder="Rechercher des quarts..."
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  className="pl-8"
                />
              </div>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Table */}
      <Card>
        <CardHeader className="pb-3">
          <div className="flex items-center justify-between">
            <CardTitle className="text-base font-medium">Historique des quarts</CardTitle>
            <span className="text-sm text-slate-500">
              {filteredShifts.length} quart{filteredShifts.length !== 1 ? 's' : ''}
            </span>
          </div>
        </CardHeader>
        <CardContent className="p-0">
          {isLoading ? (
            <div className="p-4 space-y-3">
              {[...Array(5)].map((_, i) => (
                <Skeleton key={i} className="h-12 w-full" />
              ))}
            </div>
          ) : filteredShifts.length === 0 ? (
            <div className="p-8 text-center text-slate-500">
              <Navigation className="h-10 w-10 mx-auto mb-3 text-slate-300" />
              <p className="font-medium">Aucun quart trouvé</p>
              <p className="text-sm mt-1">
                Essayez d'ajuster vos filtres ou la plage de dates.
              </p>
            </div>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Employé</TableHead>
                    <TableHead>Courriel</TableHead>
                    <TableHead>Date</TableHead>
                    <TableHead>Heure</TableHead>
                    <TableHead>Durée</TableHead>
                    <TableHead>Points GPS</TableHead>
                    <TableHead className="w-12"></TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {filteredShifts.map((shift) => (
                    <TableRow key={shift.id}>
                      <TableCell>
                        <div className="font-medium">{shift.employeeName}</div>
                      </TableCell>
                      <TableCell>
                        <div className="text-sm text-slate-600">{shift.employeeEmail}</div>
                      </TableCell>
                      <TableCell>
                        {format(shift.clockedInAt, 'MMM d, yyyy')}
                      </TableCell>
                      <TableCell>
                        <div className="text-sm">
                          {format(shift.clockedInAt, 'h:mm a')} -{' '}
                          {format(shift.clockedOutAt, 'h:mm a')}
                        </div>
                      </TableCell>
                      <TableCell>
                        <Badge variant="secondary" className="font-mono">
                          <Clock className="h-3 w-3 mr-1" />
                          {formatDuration(shift.durationMinutes)}
                        </Badge>
                      </TableCell>
                      <TableCell>
                        <Badge
                          variant={shift.gpsPointCount > 0 ? 'default' : 'outline'}
                          className="font-mono"
                        >
                          <MapPin className="h-3 w-3 mr-1" />
                          {shift.gpsPointCount}
                        </Badge>
                      </TableCell>
                      <TableCell>
                        <Link href={`/dashboard/history/${shift.id}`}>
                          <Button variant="ghost" size="icon" className="h-8 w-8">
                            <ChevronRight className="h-4 w-4" />
                          </Button>
                        </Link>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

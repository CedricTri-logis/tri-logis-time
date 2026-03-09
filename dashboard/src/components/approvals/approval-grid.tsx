'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Loader2, ChevronLeft, ChevronRight, CheckCircle2, XCircle, AlertTriangle, Clock, Minus, Car, WifiOff, MapPin, UtensilsCrossed } from 'lucide-react';
import { supabaseClient } from '@/lib/supabase/client';
import type { WeeklyEmployeeRow, DayApprovalStatus } from '@/types/mileage';
import { DayApprovalDetail } from './day-approval-detail';
import { getMonday, toLocalDateString, parseLocalDate, addDays } from '@/lib/utils/date-utils';
import { formatDuration } from '@/lib/utils/activity-display';
import { LOCATION_TYPE_ICON_MAP } from '@/lib/constants/location-icons';
import { LOCATION_TYPE_LABELS } from '@/lib/validations/location';
import type { LocationType } from '@/types/location';

function formatShortDate(dateStr: string): string {
  const d = new Date(dateStr + 'T12:00:00');
  return d.toLocaleDateString('fr-CA', { weekday: 'short', day: 'numeric' });
}

function formatHours(minutes: number): string {
  if (minutes === 0) return '0h';
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m > 0 ? `${h}h${m.toString().padStart(2, '0')}` : `${h}h`;
}

const STATUS_COLORS: Record<DayApprovalStatus, string> = {
  approved: 'bg-green-100 text-green-700 hover:bg-green-200 cursor-pointer',
  pending: 'bg-blue-50 text-blue-700 hover:bg-blue-100 cursor-pointer',
  needs_review: 'bg-yellow-100 text-yellow-700 hover:bg-yellow-200 cursor-pointer',
  active: 'bg-gray-100 text-gray-500',
  no_shift: 'bg-white text-gray-300',
};

const DAY_HEADERS = ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim'];

interface WeeklyBreakdown {
  travel_seconds: number;
  stop_by_type: Record<string, number>;
}

export function ApprovalGrid() {
  const [weekStart, setWeekStart] = useState(() => getMonday());
  const [data, setData] = useState<WeeklyEmployeeRow[]>([]);
  const [breakdown, setBreakdown] = useState<WeeklyBreakdown | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState<string>('all');
  const [search, setSearch] = useState('');

  // Detail panel state
  const [selectedCell, setSelectedCell] = useState<{ employeeId: string; employeeName: string; date: string } | null>(null);

  const fetchData = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const [summaryRes, breakdownRes] = await Promise.all([
        supabaseClient.rpc('get_weekly_approval_summary', { p_week_start: weekStart }),
        supabaseClient.rpc('get_weekly_breakdown_totals', { p_week_start: weekStart }),
      ]);
      if (summaryRes.error) {
        setError(summaryRes.error.message);
        setData([]);
        return;
      }
      setData((summaryRes.data as WeeklyEmployeeRow[]) || []);
      setBreakdown(breakdownRes.data as WeeklyBreakdown | null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Erreur lors du chargement');
      setData([]);
    } finally {
      setIsLoading(false);
    }
  }, [weekStart]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  const navigateWeek = (direction: -1 | 1) => {
    setWeekStart(addDays(weekStart, direction * 7));
  };

  // Filter data
  const filteredData = useMemo(() => {
    let rows = data;

    // Search filter
    if (search) {
      const q = search.toLowerCase();
      rows = rows.filter(r => r.employee_name.toLowerCase().includes(q));
    }

    // Status filter — show only employees who have at least one day matching the filter
    if (statusFilter !== 'all') {
      rows = rows.filter(r =>
        r.days.some(d => d.status === statusFilter)
      );
    }

    return rows;
  }, [data, search, statusFilter]);

  // Week totals per employee
  const getWeekApproved = (row: WeeklyEmployeeRow): number => {
    return row.days.reduce((sum, d) => sum + (d.approved_minutes ?? 0), 0);
  };
  const getWeekRejected = (row: WeeklyEmployeeRow): number => {
    return row.days.reduce((sum, d) => sum + (d.rejected_minutes ?? 0), 0);
  };

  // Global week totals across all employees
  const weekTotals = useMemo(() => {
    const totals = {
      approved: 0,
      rejected: 0,
      needsReview: 0,
      total: 0,
      lunch: 0,
    };
    for (const row of data) {
      for (const day of row.days) {
        totals.approved += day.approved_minutes ?? 0;
        totals.rejected += day.rejected_minutes ?? 0;
        totals.needsReview += day.needs_review_count ?? 0;
        totals.total += day.total_shift_minutes ?? 0;
        totals.lunch += day.lunch_minutes ?? 0;
      }
    }
    return totals;
  }, [data]);

  // Compute gap seconds: total - travel - stops - lunch (remainder = untracked)
  const gapSeconds = useMemo(() => {
    if (!breakdown) return 0;
    const totalSeconds = weekTotals.total * 60;
    const travelSeconds = breakdown.travel_seconds;
    const stopSeconds = Object.values(breakdown.stop_by_type).reduce((s, v) => s + v, 0);
    const lunchSeconds = weekTotals.lunch * 60;
    return Math.max(0, totalSeconds - travelSeconds - stopSeconds - lunchSeconds);
  }, [weekTotals, breakdown]);

  const weekLabel = useMemo(() => {
    const start = parseLocalDate(weekStart);
    const end = parseLocalDate(addDays(weekStart, 6));
    return `${start.toLocaleDateString('fr-CA', { day: 'numeric', month: 'short' })} — ${end.toLocaleDateString('fr-CA', { day: 'numeric', month: 'short', year: 'numeric' })}`;
  }, [weekStart]);

  // Dates for column headers
  const weekDates = useMemo(() => {
    const dates: string[] = [];
    for (let i = 0; i < 7; i++) {
      dates.push(addDays(weekStart, i));
    }
    return dates;
  }, [weekStart]);

  const handleCellClick = (row: WeeklyEmployeeRow, dayIndex: number) => {
    const day = row.days[dayIndex];
    if (!day || day.status === 'no_shift' || day.status === 'active') return;
    setSelectedCell({
      employeeId: row.employee_id,
      employeeName: row.employee_name,
      date: day.date,
    });
  };

  const handleDetailClose = (hasChanges: boolean) => {
    setSelectedCell(null);
    // Only refresh grid data if changes were made in the detail panel
    if (hasChanges) {
      // Background refresh — no loading spinner so the grid stays visible
      const refreshInBackground = async () => {
        try {
          const [summaryRes, breakdownRes] = await Promise.all([
            supabaseClient.rpc('get_weekly_approval_summary', { p_week_start: weekStart }),
            supabaseClient.rpc('get_weekly_breakdown_totals', { p_week_start: weekStart }),
          ]);
          if (!summaryRes.error) {
            setData((summaryRes.data as WeeklyEmployeeRow[]) || []);
          }
          if (!breakdownRes.error) {
            setBreakdown(breakdownRes.data as WeeklyBreakdown | null);
          }
        } catch {
          // Silent fail — grid keeps showing stale data rather than breaking
        }
      };
      refreshInBackground();
    }
  };

  const renderCell = (day: WeeklyEmployeeRow['days'][0]) => {
    if (day.status === 'no_shift') {
      return <Minus className="h-4 w-4 text-gray-300 mx-auto" />;
    }
    if (day.status === 'active') {
      return <Clock className="h-4 w-4 text-gray-400 mx-auto" />;
    }

    const approved = day.approved_minutes ?? 0;
    const rejected = day.rejected_minutes ?? 0;
    const needsReviewMinutes = day.total_shift_minutes - approved - rejected;

    return (
      <div className="flex flex-col items-center gap-0.5">
        <span className="text-xs font-bold">{formatHours(approved)}</span>
        {rejected > 0 && (
          <span className="text-[10px] text-red-600">{formatHours(rejected)} refusé</span>
        )}
        {needsReviewMinutes > 0 && day.needs_review_count > 0 && (
          <Badge variant="secondary" className="bg-yellow-100 text-yellow-700 hover:bg-yellow-100 text-[10px] px-1 py-0">
            {formatHours(needsReviewMinutes)} à vérifier
          </Badge>
        )}
        {(day.lunch_minutes ?? 0) > 0 && (
          <span className="text-[10px] text-orange-600">
            {formatHours(day.lunch_minutes)} dîner
          </span>
        )}
        {day.status === 'approved' && (
          <CheckCircle2 className="h-3 w-3 text-green-600" />
        )}
      </div>
    );
  };

  const hasAnyShifts = weekTotals.total > 0;

  return (
    <div className="space-y-4">
      {/* Week nav + filters */}
      <Card>
        <CardContent className="pt-4 pb-4">
          <div className="flex flex-wrap items-center gap-4">
            {/* Week navigation */}
            <div className="flex items-center gap-2">
              <Button variant="outline" size="icon" onClick={() => navigateWeek(-1)}>
                <ChevronLeft className="h-4 w-4" />
              </Button>
              <span className="text-sm font-medium min-w-[200px] text-center">{weekLabel}</span>
              <Button variant="outline" size="icon" onClick={() => navigateWeek(1)}>
                <ChevronRight className="h-4 w-4" />
              </Button>
            </div>

            {/* Status filter */}
            <Select value={statusFilter} onValueChange={setStatusFilter}>
              <SelectTrigger className="w-[180px]">
                <SelectValue placeholder="Statut" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">Tous</SelectItem>
                <SelectItem value="needs_review">À vérifier</SelectItem>
                <SelectItem value="pending">En attente</SelectItem>
                <SelectItem value="approved">Approuvé</SelectItem>
              </SelectContent>
            </Select>

            {/* Employee search */}
            <Input
              placeholder="Rechercher un employé..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="max-w-[200px]"
            />
          </div>

          {/* Weekly summary — cards + breakdown badges */}
          {!isLoading && hasAnyShifts && (
            <div className="mt-4 pt-4 border-t space-y-3">
              {/* Summary cards */}
              <div className="grid grid-cols-2 sm:grid-cols-5 gap-3">
                <div className="flex flex-col p-3 bg-green-50/50 rounded-xl border border-green-100">
                  <span className="text-[10px] uppercase tracking-wider text-green-700/60 font-bold">Approuvé</span>
                  <span className="text-xl font-black text-green-700 tracking-tight">{formatHours(weekTotals.approved)}</span>
                </div>
                <div className="flex flex-col p-3 bg-red-50/50 rounded-xl border border-red-100">
                  <span className="text-[10px] uppercase tracking-wider text-red-700/60 font-bold">Rejeté</span>
                  <span className="text-xl font-black text-red-700 tracking-tight">{formatHours(weekTotals.rejected)}</span>
                </div>
                <div className={`flex flex-col p-3 rounded-xl border ${weekTotals.needsReview > 0 ? 'bg-amber-50/50 border-amber-100' : 'bg-muted/30 border-muted-foreground/10'}`}>
                  <span className={`text-[10px] uppercase tracking-wider font-bold ${weekTotals.needsReview > 0 ? 'text-amber-700/60' : 'text-muted-foreground/60'}`}>À vérifier</span>
                  <div className="flex items-baseline gap-1">
                    <span className={`text-xl font-black tracking-tight ${weekTotals.needsReview > 0 ? 'text-amber-700' : 'text-muted-foreground/40'}`}>{weekTotals.needsReview}</span>
                    <span className="text-[10px] text-muted-foreground/60">activité{weekTotals.needsReview > 1 ? 's' : ''}</span>
                  </div>
                </div>
                <div className="flex flex-col p-3 bg-slate-50 rounded-xl border border-slate-200">
                  <span className="text-[10px] uppercase tracking-wider text-slate-500 font-bold">Total</span>
                  <span className="text-xl font-black text-slate-800 tracking-tight">{formatHours(weekTotals.total)}</span>
                </div>
                {weekTotals.lunch > 0 && (
                  <div className="flex flex-col p-3 bg-orange-50/50 rounded-xl border border-orange-100">
                    <span className="text-[10px] uppercase tracking-wider text-orange-700/60 font-bold">Dîner</span>
                    <span className="text-xl font-black text-orange-700 tracking-tight">{formatHours(weekTotals.lunch)}</span>
                  </div>
                )}
              </div>

              {/* Breakdown badges */}
              {breakdown && (breakdown.travel_seconds > 0 || Object.keys(breakdown.stop_by_type).length > 0 || gapSeconds > 0) && (
                <div className="flex flex-wrap items-center gap-1.5">
                  <span className="text-[10px] font-semibold text-muted-foreground uppercase mr-1">Répartition:</span>
                  {breakdown.travel_seconds > 0 && (
                    <span
                      className="inline-flex items-center gap-1 rounded-full bg-blue-50 px-2 py-0.5 text-xs font-medium text-blue-700 border border-blue-100"
                      title="Déplacement"
                    >
                      <Car className="h-3 w-3" />
                      {formatDuration(breakdown.travel_seconds)}
                    </span>
                  )}
                  {gapSeconds > 0 && (
                    <span
                      className="inline-flex items-center gap-1 rounded-full bg-purple-50 px-2 py-0.5 text-xs font-medium text-purple-700 border border-purple-100"
                      title="Temps non suivi"
                    >
                      <WifiOff className="h-3 w-3" />
                      {formatDuration(gapSeconds)}
                    </span>
                  )}
                  {Object.entries(breakdown.stop_by_type)
                    .filter(([, secs]) => secs > 0)
                    .sort(([a], [b]) => {
                      if (a === '_unmatched') return 1;
                      if (b === '_unmatched') return -1;
                      return (breakdown.stop_by_type[b] || 0) - (breakdown.stop_by_type[a] || 0);
                    })
                    .map(([type, secs]) => {
                      const isUnmatched = type === '_unmatched';
                      const iconEntry = isUnmatched ? null : LOCATION_TYPE_ICON_MAP[type as LocationType];
                      const Icon = iconEntry ? iconEntry.icon : MapPin;
                      const colorClass = iconEntry ? iconEntry.className : 'h-3 w-3 text-gray-400';
                      const label = isUnmatched ? 'Autre' : (LOCATION_TYPE_LABELS[type as LocationType] || type);
                      return (
                        <span
                          key={type}
                          className="inline-flex items-center gap-1 rounded-full bg-slate-50 px-2 py-0.5 text-xs font-medium text-slate-700 border border-slate-200"
                          title={label}
                        >
                          <Icon className={colorClass.replace('h-4 w-4', 'h-3 w-3')} />
                          {formatDuration(secs)}
                        </span>
                      );
                    })}
                </div>
              )}
            </div>
          )}
        </CardContent>
      </Card>

      {/* Grid */}
      {error && (
        <div className="rounded-md bg-red-50 p-3 text-sm text-red-700">{error}</div>
      )}

      {isLoading ? (
        <div className="flex items-center justify-center py-8">
          <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
        </div>
      ) : (
        <Card>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b bg-gray-50">
                  <th className="px-4 py-3 text-left font-medium text-gray-700 min-w-[180px]">Employé</th>
                  {weekDates.map((date, i) => (
                    <th key={date} className="px-2 py-3 text-center font-medium text-gray-700 min-w-[100px]">
                      <div>{DAY_HEADERS[i]}</div>
                      <div className="text-xs font-normal text-gray-500">{formatShortDate(date)}</div>
                    </th>
                  ))}
                  <th className="px-4 py-3 text-center font-medium text-gray-700 min-w-[80px]">Total</th>
                </tr>
              </thead>
              <tbody>
                {filteredData.length === 0 ? (
                  <tr>
                    <td colSpan={9} className="px-4 py-8 text-center text-gray-500">
                      Aucun employé trouvé
                    </td>
                  </tr>
                ) : (
                  filteredData.map(row => (
                    <tr key={row.employee_id} className="border-b hover:bg-gray-50">
                      <td className="px-4 py-3 font-medium text-gray-900">{row.employee_name}</td>
                      {row.days.map((day, i) => (
                        <td
                          key={day.date}
                          className={`px-2 py-2 text-center ${STATUS_COLORS[day.status]} transition-colors`}
                          onClick={() => handleCellClick(row, i)}
                        >
                          {renderCell(day)}
                        </td>
                      ))}
                      <td className="px-4 py-3 text-center">
                        {getWeekApproved(row) > 0 || getWeekRejected(row) > 0 ? (
                          <div className="flex flex-col items-center gap-0.5">
                            <span className="font-bold text-gray-900">{formatHours(getWeekApproved(row))}</span>
                            {getWeekRejected(row) > 0 && (
                              <span className="text-[10px] text-red-600">{formatHours(getWeekRejected(row))} refusé</span>
                            )}
                          </div>
                        ) : '—'}
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>
        </Card>
      )}

      {/* Detail panel */}
      {selectedCell && (
        <DayApprovalDetail
          employeeId={selectedCell.employeeId}
          employeeName={selectedCell.employeeName}
          date={selectedCell.date}
          onClose={handleDetailClose}
        />
      )}
    </div>
  );
}

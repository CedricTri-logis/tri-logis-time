'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Loader2, ChevronLeft, ChevronRight, CheckCircle2, XCircle, AlertTriangle, Clock, Minus } from 'lucide-react';
import { supabaseClient } from '@/lib/supabase/client';
import type { WeeklyEmployeeRow, DayApprovalStatus } from '@/types/mileage';
import { DayApprovalDetail } from './day-approval-detail';

function getMonday(date: Date): Date {
  const d = new Date(date);
  const day = d.getDay();
  const diff = d.getDate() - day + (day === 0 ? -6 : 1);
  d.setDate(diff);
  d.setHours(12, 0, 0, 0);
  return d;
}

function formatDateISO(date: Date): string {
  return date.toISOString().split('T')[0];
}

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

export function ApprovalGrid() {
  const [weekStart, setWeekStart] = useState(() => formatDateISO(getMonday(new Date())));
  const [data, setData] = useState<WeeklyEmployeeRow[]>([]);
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
      const { data: result, error: rpcError } = await supabaseClient.rpc(
        'get_weekly_approval_summary',
        { p_week_start: weekStart }
      );
      if (rpcError) {
        setError(rpcError.message);
        setData([]);
        return;
      }
      setData((result as WeeklyEmployeeRow[]) || []);
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
    const d = new Date(weekStart + 'T12:00:00');
    d.setDate(d.getDate() + direction * 7);
    setWeekStart(formatDateISO(d));
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

  // Week total per employee
  const getWeekTotal = (row: WeeklyEmployeeRow): number => {
    return row.days.reduce((sum, d) => sum + d.total_shift_minutes, 0);
  };

  const weekLabel = useMemo(() => {
    const start = new Date(weekStart + 'T12:00:00');
    const end = new Date(start);
    end.setDate(end.getDate() + 6);
    return `${start.toLocaleDateString('fr-CA', { day: 'numeric', month: 'short' })} — ${end.toLocaleDateString('fr-CA', { day: 'numeric', month: 'short', year: 'numeric' })}`;
  }, [weekStart]);

  // Dates for column headers
  const weekDates = useMemo(() => {
    const dates: string[] = [];
    const start = new Date(weekStart + 'T12:00:00');
    for (let i = 0; i < 7; i++) {
      const d = new Date(start);
      d.setDate(d.getDate() + i);
      dates.push(formatDateISO(d));
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

  const handleDetailClose = () => {
    setSelectedCell(null);
    // Refresh grid data after closing detail (in case of changes)
    fetchData();
  };

  const renderCell = (day: WeeklyEmployeeRow['days'][0]) => {
    if (day.status === 'no_shift') {
      return <Minus className="h-4 w-4 text-gray-300 mx-auto" />;
    }
    if (day.status === 'active') {
      return <Clock className="h-4 w-4 text-gray-400 mx-auto" />;
    }

    return (
      <div className="flex flex-col items-center gap-0.5">
        <span className="text-xs font-medium">{formatHours(day.total_shift_minutes)}</span>
        {day.status === 'approved' && day.approved_minutes !== null && (
          <span className="text-[10px] text-green-600">{formatHours(day.approved_minutes)} approuvé</span>
        )}
        {day.status === 'needs_review' && day.needs_review_count > 0 && (
          <Badge variant="secondary" className="bg-yellow-100 text-yellow-700 hover:bg-yellow-100 text-[10px] px-1 py-0">
            {day.needs_review_count} à vérifier
          </Badge>
        )}
        {day.status === 'approved' && (
          <CheckCircle2 className="h-3 w-3 text-green-600" />
        )}
      </div>
    );
  };

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
                      <td className="px-4 py-3 text-center font-medium text-gray-900">
                        {getWeekTotal(row) > 0 ? formatHours(getWeekTotal(row)) : '—'}
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

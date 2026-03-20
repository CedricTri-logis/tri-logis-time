'use client';

import { useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import { ChevronDown, ChevronRight } from 'lucide-react';
import { format, parseISO } from 'date-fns';
import { fr } from 'date-fns/locale';
import { cn } from '@/lib/utils';
import { formatDeviceModel } from '@/lib/utils/device-model';
import type { GapsByDayGroup } from '@/types/gps-diagnostics';

interface GpsGapsByDayProps {
  data: GapsByDayGroup[];
  isLoading: boolean;
}

export function GpsGapsByDay({ data, isLoading }: GpsGapsByDayProps) {
  // First 2 days expanded by default
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());

  const toggleDay = (day: string) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(day)) next.delete(day);
      else next.add(day);
      return next;
    });
  };

  if (isLoading) {
    return (
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base font-medium">Trous GPS par jour</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          {[...Array(3)].map((_, i) => (
            <Skeleton key={i} className="h-16 w-full" />
          ))}
        </CardContent>
      </Card>
    );
  }

  if (data.length === 0) {
    return (
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base font-medium">Trous GPS par jour</CardTitle>
        </CardHeader>
        <CardContent className="py-8 text-center">
          <p className="text-sm text-slate-500">Aucun trou GPS ≥ 5 min pour cette période</p>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="text-base font-medium">Trous GPS par jour</CardTitle>
      </CardHeader>
      <CardContent className="p-0">
        {data.map((dayGroup, dayIdx) => {
          const isCollapsed = dayIdx >= 2 ? !collapsed.has(dayGroup.day) : collapsed.has(dayGroup.day);
          const dayDate = parseISO(dayGroup.day);

          return (
            <div key={dayGroup.day}>
              {/* Day header */}
              <button
                onClick={() => toggleDay(dayGroup.day)}
                className="flex w-full items-center gap-2 px-6 py-3 border-b border-slate-200 hover:bg-slate-50 cursor-pointer"
              >
                {isCollapsed ? (
                  <ChevronRight className="h-4 w-4 text-slate-400" />
                ) : (
                  <ChevronDown className="h-4 w-4 text-slate-400" />
                )}
                <span className="text-sm font-bold text-slate-900">
                  {format(dayDate, 'EEEE d MMMM', { locale: fr })}
                </span>
                <span className={cn(
                  'px-2 py-0.5 rounded-full text-xs font-medium',
                  dayGroup.totalGaps > 15 ? 'bg-red-100 text-red-800' : 'bg-amber-100 text-amber-800'
                )}>
                  {dayGroup.totalGaps} trou{dayGroup.totalGaps > 1 ? 's' : ''} · {dayGroup.totalEmployees} employé{dayGroup.totalEmployees > 1 ? 's' : ''}
                </span>
              </button>

              {/* Employees + gaps (collapsible) */}
              {!isCollapsed && (
                <div className="px-6">
                  {dayGroup.employees.map((emp) => (
                    <div key={emp.employeeId} className="py-3 border-b border-slate-100 last:border-0">
                      <div className="flex items-center gap-2 mb-2">
                        <span className="text-sm font-semibold text-slate-900 w-40 truncate">
                          {emp.fullName}
                        </span>
                        <span className="text-xs text-slate-500">
                          {emp.devicePlatform === 'ios' ? 'iOS' : 'Android'} · {formatDeviceModel(emp.deviceModel) ?? ''}
                        </span>
                        <span className={cn(
                          'ml-auto text-xs font-semibold',
                          emp.totalMinutes > 60 ? 'text-red-600' : 'text-amber-600'
                        )}>
                          {emp.gaps.length} trou{emp.gaps.length > 1 ? 's' : ''} · {emp.totalMinutes} min total
                        </span>
                      </div>
                      <div className="flex gap-1.5 flex-wrap pl-1">
                        {emp.gaps.map((gap, gapIdx) => (
                          <div
                            key={gapIdx}
                            className={cn(
                              'rounded-md border px-2.5 py-1 text-xs',
                              gap.gapMinutes >= 30
                                ? 'bg-red-50 border-red-200'
                                : 'bg-amber-50 border-amber-200'
                            )}
                          >
                            <span className={cn(
                              'font-semibold',
                              gap.gapMinutes >= 30 ? 'text-red-700' : 'text-amber-700'
                            )}>
                              {gap.gapMinutes} min
                            </span>
                            <span className="text-slate-500 ml-1.5">
                              {format(gap.gapStart, 'HH:mm')} → {format(gap.gapEnd, 'HH:mm')}
                            </span>
                          </div>
                        ))}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          );
        })}
      </CardContent>
    </Card>
  );
}

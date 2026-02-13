'use client';

import { useMemo } from 'react';
import type { CleaningSession } from '@/types/cleaning';
import { formatDuration } from '@/types/cleaning';

interface EmployeePerformanceCardsProps {
  sessions: CleaningSession[];
  isLoading: boolean;
}

interface EmployeePerformance {
  name: string;
  totalSessions: number;
  completed: number;
  avgDurationMinutes: number;
  flaggedCount: number;
  flaggedRatio: number;
  buildings: string[];
}

function computePerformance(sessions: CleaningSession[]): EmployeePerformance[] {
  const byEmployee = new Map<string, CleaningSession[]>();
  for (const s of sessions) {
    const arr = byEmployee.get(s.employeeName) ?? [];
    arr.push(s);
    byEmployee.set(s.employeeName, arr);
  }

  return Array.from(byEmployee.entries())
    .map(([name, empSessions]) => {
      const completedSessions = empSessions.filter(
        (s) => s.durationMinutes != null && s.status !== 'in_progress'
      );
      const avgDuration =
        completedSessions.length > 0
          ? completedSessions.reduce((sum, s) => sum + (s.durationMinutes ?? 0), 0) /
            completedSessions.length
          : 0;
      const flaggedCount = empSessions.filter((s) => s.isFlagged).length;
      const buildings = [...new Set(empSessions.map((s) => s.buildingName))];

      return {
        name,
        totalSessions: empSessions.length,
        completed: empSessions.filter((s) => s.status === 'completed').length,
        avgDurationMinutes: avgDuration,
        flaggedCount,
        flaggedRatio: empSessions.length > 0 ? flaggedCount / empSessions.length : 0,
        buildings,
      };
    })
    .sort((a, b) => b.totalSessions - a.totalSessions);
}

export function EmployeePerformanceCards({
  sessions,
  isLoading,
}: EmployeePerformanceCardsProps) {
  const employees = useMemo(() => computePerformance(sessions), [sessions]);

  if (isLoading) {
    return (
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
        {Array.from({ length: 4 }).map((_, i) => (
          <div key={i} className="animate-pulse rounded-lg border bg-white p-4">
            <div className="h-4 w-32 rounded bg-slate-200" />
            <div className="mt-3 h-6 w-12 rounded bg-slate-200" />
            <div className="mt-2 h-3 w-24 rounded bg-slate-200" />
          </div>
        ))}
      </div>
    );
  }

  if (employees.length === 0) {
    return (
      <div className="rounded-lg border bg-white p-6 text-center text-sm text-slate-500">
        No employee data available for the selected period.
      </div>
    );
  }

  return (
    <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
      {employees.map((emp) => (
        <div
          key={emp.name}
          className="rounded-lg border bg-white p-4 shadow-sm"
        >
          <h3 className="text-sm font-semibold text-slate-900">{emp.name}</h3>

          <div className="mt-2 flex items-baseline gap-1">
            <span className="text-2xl font-bold text-slate-900">
              {emp.totalSessions}
            </span>
            <span className="text-sm text-slate-500">sessions</span>
          </div>

          <div className="mt-3 space-y-1.5">
            <div className="flex justify-between text-xs">
              <span className="text-slate-500">Completed</span>
              <span className="font-medium text-green-600">{emp.completed}</span>
            </div>
            <div className="flex justify-between text-xs">
              <span className="text-slate-500">Avg Duration</span>
              <span className="font-medium text-slate-700">
                {formatDuration(emp.avgDurationMinutes)}
              </span>
            </div>
            <div className="flex justify-between text-xs">
              <span className="text-slate-500">Flagged</span>
              <span
                className={`font-medium ${
                  emp.flaggedRatio > 0.2
                    ? 'text-red-600'
                    : emp.flaggedCount > 0
                      ? 'text-orange-500'
                      : 'text-slate-400'
                }`}
              >
                {emp.flaggedCount}
                {emp.totalSessions > 0 && (
                  <span className="ml-1 text-slate-400">
                    ({Math.round(emp.flaggedRatio * 100)}%)
                  </span>
                )}
              </span>
            </div>
            <div className="flex justify-between text-xs">
              <span className="text-slate-500">Buildings</span>
              <span className="text-right text-slate-600">
                {emp.buildings.length <= 2
                  ? emp.buildings.join(', ')
                  : `${emp.buildings.slice(0, 2).join(', ')} +${emp.buildings.length - 2}`}
              </span>
            </div>
          </div>
        </div>
      ))}
    </div>
  );
}

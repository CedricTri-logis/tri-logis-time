'use client';

import { useState, useCallback, useMemo } from 'react';
import {
  useCleaningSessions,
  useCleaningStatsByBuilding,
  useCleaningSessionMutations,
} from '@/lib/hooks/use-cleaning-sessions';
import { BuildingStatsCards } from '@/components/cleaning/building-stats-cards';
import {
  CleaningFilters,
  type CleaningFilterValues,
} from '@/components/cleaning/cleaning-filters';
import { CleaningSessionsTable } from '@/components/cleaning/cleaning-sessions-table';
import { CloseSessionDialog } from '@/components/cleaning/close-session-dialog';
import { EmployeePerformanceCards } from '@/components/cleaning/employee-performance-cards';
import type { CleaningSession } from '@/types/cleaning';
import { formatDuration } from '@/types/cleaning';

export default function CleaningPage() {
  const today = new Date();
  const [filters, setFilters] = useState<CleaningFilterValues>({
    dateFrom: today,
    dateTo: today,
  });
  const [offset, setOffset] = useState(0);
  const [sessionToClose, setSessionToClose] = useState<CleaningSession | null>(
    null
  );
  const limit = 50;

  const {
    sessions,
    summary,
    totalCount,
    isLoading,
    refetch,
  } = useCleaningSessions({
    buildingId: filters.buildingId,
    employeeId: filters.employeeId,
    dateFrom: filters.dateFrom,
    dateTo: filters.dateTo,
    status: filters.status,
    limit,
    offset,
  });

  const { stats: buildingStats, isLoading: buildingStatsLoading } =
    useCleaningStatsByBuilding(filters.dateFrom, filters.dateTo);

  const { closeSession, isClosing } = useCleaningSessionMutations();

  const handleFiltersChange = useCallback((newFilters: CleaningFilterValues) => {
    setFilters(newFilters);
    setOffset(0);
  }, []);

  const handleCloseSession = useCallback(
    async (sessionId: string) => {
      await closeSession(sessionId);
      setSessionToClose(null);
      refetch();
    },
    [closeSession, refetch]
  );

  // Analytics: building completion rates
  const buildingCompletionSummary = useMemo(() => {
    if (!buildingStats.length) return null;
    const totalStudios = buildingStats.reduce((s, b) => s + b.totalStudios, 0);
    const totalCleaned = buildingStats.reduce((s, b) => s + b.cleanedToday, 0);
    const completionPct = totalStudios > 0 ? Math.round((totalCleaned / totalStudios) * 100) : 0;
    const fullyComplete = buildingStats.filter((b) => b.cleanedToday >= b.totalStudios).length;
    return { totalStudios, totalCleaned, completionPct, fullyComplete, totalBuildings: buildingStats.length };
  }, [buildingStats]);

  return (
    <div className="space-y-6 p-6">
      {/* Page header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-900">Cleaning</h1>
          <p className="text-sm text-slate-500">
            {totalCount} session{totalCount !== 1 ? 's' : ''} total
          </p>
        </div>
        <button
          onClick={() => refetch()}
          className="rounded-md border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-600 hover:bg-slate-50"
        >
          Refresh
        </button>
      </div>

      {/* Filters */}
      <CleaningFilters
        filters={filters}
        onFiltersChange={handleFiltersChange}
      />

      {/* Summary stats row */}
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-6">
        <_StatCard label="Total" value={summary.totalSessions} />
        <_StatCard label="Completed" value={summary.completed} color="green" />
        <_StatCard label="In Progress" value={summary.inProgress} color="blue" />
        <_StatCard label="Auto-Closed" value={summary.autoClosed} color="orange" />
        <_StatCard
          label="Avg Duration"
          value={formatDuration(summary.avgDurationMinutes)}
        />
        <_StatCard label="Flagged" value={summary.flaggedCount} color="red" />
      </div>

      {/* Building stats */}
      <div>
        <h2 className="mb-3 text-lg font-semibold text-slate-900">
          By Building
        </h2>
        <BuildingStatsCards
          stats={buildingStats}
          isLoading={buildingStatsLoading}
        />
        {/* Building completion overview */}
        {buildingCompletionSummary && (
          <div className="mt-3 flex flex-wrap items-center gap-4 rounded-lg bg-slate-50 px-4 py-2.5 text-sm">
            <span className="text-slate-500">
              Overall:{' '}
              <span className="font-semibold text-slate-900">
                {buildingCompletionSummary.totalCleaned}/{buildingCompletionSummary.totalStudios}
              </span>{' '}
              studios ({buildingCompletionSummary.completionPct}%)
            </span>
            <span className="text-slate-500">
              Buildings complete:{' '}
              <span className="font-semibold text-green-600">
                {buildingCompletionSummary.fullyComplete}/{buildingCompletionSummary.totalBuildings}
              </span>
            </span>
          </div>
        )}
      </div>

      {/* Employee performance analytics */}
      <div>
        <h2 className="mb-3 text-lg font-semibold text-slate-900">
          Employee Performance
        </h2>
        <EmployeePerformanceCards
          sessions={sessions}
          isLoading={isLoading}
        />
      </div>

      {/* Sessions table */}
      <div>
        <h2 className="mb-3 text-lg font-semibold text-slate-900">
          Sessions
        </h2>
        <CleaningSessionsTable
          sessions={sessions}
          isLoading={isLoading}
          totalCount={totalCount}
          limit={limit}
          offset={offset}
          onPageChange={setOffset}
          onCloseSession={(id) => {
            const session = sessions.find((s) => s.id === id);
            if (session) setSessionToClose(session);
          }}
        />
      </div>

      {/* Close session dialog */}
      {sessionToClose && (
        <CloseSessionDialog
          session={sessionToClose}
          isOpen={!!sessionToClose}
          isClosing={isClosing}
          onClose={() => setSessionToClose(null)}
          onConfirm={handleCloseSession}
        />
      )}
    </div>
  );
}

function _StatCard({
  label,
  value,
  color,
}: {
  label: string;
  value: string | number;
  color?: string;
}) {
  const colorClass = color
    ? {
        green: 'text-green-600',
        blue: 'text-blue-600',
        orange: 'text-orange-600',
        red: 'text-red-600',
      }[color] ?? 'text-slate-900'
    : 'text-slate-900';

  return (
    <div className="rounded-lg border bg-white p-4">
      <p className="text-xs font-medium text-slate-500">{label}</p>
      <p className={`mt-1 text-xl font-bold ${colorClass}`}>{value}</p>
    </div>
  );
}

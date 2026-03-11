'use client';

import { useState, useCallback, useMemo } from 'react';
import {
  useWorkSessions,
  useManualCloseWorkSession,
} from '@/lib/hooks/use-work-sessions';
import {
  WorkSessionFilters,
  type WorkSessionFilterValues,
} from '@/components/work-sessions/work-session-filters';
import { WorkSessionsTable } from '@/components/work-sessions/work-sessions-table';
import { CloseSessionDialog } from '@/components/work-sessions/close-session-dialog';
import type { WorkSession } from '@/types/work-session';
import { formatWorkSessionDuration } from '@/types/work-session';

export default function WorkSessionsPage() {
  const today = new Date();
  const [filters, setFilters] = useState<WorkSessionFilterValues>({
    dateFrom: today,
    dateTo: today,
  });
  const [offset, setOffset] = useState(0);
  const [sessionToClose, setSessionToClose] = useState<WorkSession | null>(
    null
  );
  const limit = 50;

  const { sessions, summary, totalCount, isLoading, refetch } =
    useWorkSessions({
      activityType: filters.activityType,
      employeeId: filters.employeeId,
      dateFrom: filters.dateFrom,
      dateTo: filters.dateTo,
      status: filters.status,
      limit,
      offset,
    });

  const { closeSession, isClosing } = useManualCloseWorkSession();

  const handleFiltersChange = useCallback(
    (newFilters: WorkSessionFilterValues) => {
      setFilters(newFilters);
      setOffset(0);
    },
    []
  );

  const handleCloseSession = useCallback(
    async (sessionId: string, employeeId: string) => {
      await closeSession(sessionId, employeeId);
      setSessionToClose(null);
      refetch();
    },
    [closeSession, refetch]
  );

  // Computed stats
  const totalHours = useMemo(() => {
    const totalMinutes = sessions.reduce(
      (sum, s) => sum + (s.durationMinutes ?? 0),
      0
    );
    return formatWorkSessionDuration(totalMinutes > 0 ? totalMinutes : null);
  }, [sessions]);

  return (
    <div className="space-y-6 p-6">
      {/* Page header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-900">
            Sessions de travail
          </h1>
          <p className="text-sm text-slate-500">
            {totalCount} session{totalCount !== 1 ? 's' : ''} au total
          </p>
        </div>
        <button
          onClick={() => refetch()}
          className="rounded-md border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-600 hover:bg-slate-50"
        >
          Actualiser
        </button>
      </div>

      {/* Filters with activity type tabs */}
      <WorkSessionFilters
        filters={filters}
        onFiltersChange={handleFiltersChange}
        summary={summary}
      />

      {/* Summary stats row */}
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <_StatCard label="Total sessions" value={summary.totalSessions} />
        <_StatCard label="Heures totales" value={totalHours} color="blue" />
        <_StatCard
          label="Duree moy."
          value={formatWorkSessionDuration(summary.avgDurationMinutes)}
        />
        <_StatCard
          label="Signalees"
          value={summary.flaggedCount}
          color="red"
        />
      </div>

      {/* Status breakdown */}
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        <_StatCard
          label="Terminees"
          value={summary.completed}
          color="green"
        />
        <_StatCard label="En cours" value={summary.inProgress} color="blue" />
        <_StatCard
          label="Fermees auto"
          value={summary.autoClosed}
          color="orange"
        />
        <_StatCard
          label="Fermees manuellement"
          value={summary.manuallyClosed}
          color="yellow"
        />
      </div>

      {/* Sessions table */}
      <div>
        <h2 className="mb-3 text-lg font-semibold text-slate-900">Sessions</h2>
        <WorkSessionsTable
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
        yellow: 'text-yellow-600',
      }[color] ?? 'text-slate-900'
    : 'text-slate-900';

  return (
    <div className="rounded-lg border bg-white p-4">
      <p className="text-xs font-medium text-slate-500">{label}</p>
      <p className={`mt-1 text-xl font-bold ${colorClass}`}>{value}</p>
    </div>
  );
}

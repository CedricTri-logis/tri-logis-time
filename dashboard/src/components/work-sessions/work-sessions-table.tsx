'use client';

import { useState, useMemo } from 'react';
import type { WorkSession, WorkSessionStatus, ActivityType } from '@/types/work-session';
import {
  ACTIVITY_TYPE_CONFIG,
  WORK_SESSION_STATUS_LABELS,
  formatWorkSessionDuration,
} from '@/types/work-session';

interface WorkSessionsTableProps {
  sessions: WorkSession[];
  isLoading: boolean;
  totalCount: number;
  limit: number;
  offset: number;
  onPageChange: (offset: number) => void;
  onCloseSession?: (sessionId: string) => void;
}

function activityTypeBadge(type: ActivityType) {
  const config = ACTIVITY_TYPE_CONFIG[type];
  return (
    <span
      className="inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-medium"
      style={{ backgroundColor: config.bgColor, color: config.color }}
    >
      <span
        className="inline-block h-2 w-2 rounded-full"
        style={{ backgroundColor: config.color }}
      />
      {config.label}
    </span>
  );
}

function statusBadge(status: WorkSessionStatus) {
  const colors: Record<WorkSessionStatus, string> = {
    in_progress: 'bg-blue-100 text-blue-700',
    completed: 'bg-green-100 text-green-700',
    auto_closed: 'bg-orange-100 text-orange-700',
    manually_closed: 'bg-yellow-100 text-yellow-700',
  };

  return (
    <span
      className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ${colors[status]}`}
    >
      {WORK_SESSION_STATUS_LABELS[status]}
    </span>
  );
}

function formatTime(date: Date): string {
  return date.toLocaleTimeString('fr-CA', {
    hour: '2-digit',
    minute: '2-digit',
  });
}

function formatDate(date: Date): string {
  return date.toLocaleDateString('fr-CA', {
    month: 'short',
    day: 'numeric',
  });
}

function getLocationLabel(session: WorkSession): string {
  if (session.activityType === 'admin') return 'Administration';
  const parts: string[] = [];
  if (session.studioNumber) parts.push(session.studioNumber);
  if (session.buildingName) parts.push(session.buildingName);
  if (parts.length > 0) return parts.join(' — ');
  return '\u2014';
}

export function WorkSessionsTable({
  sessions,
  isLoading,
  totalCount,
  limit,
  offset,
  onPageChange,
  onCloseSession,
}: WorkSessionsTableProps) {
  const [sortBy, setSortBy] = useState<'started_at' | 'duration'>('started_at');
  const [sortOrder, setSortOrder] = useState<'asc' | 'desc'>('desc');

  const sortedSessions = useMemo(
    () =>
      [...sessions].sort((a, b) => {
        let cmp = 0;
        if (sortBy === 'started_at') {
          cmp = a.startedAt.getTime() - b.startedAt.getTime();
        } else {
          cmp = (a.durationMinutes ?? 0) - (b.durationMinutes ?? 0);
        }
        return sortOrder === 'asc' ? cmp : -cmp;
      }),
    [sessions, sortBy, sortOrder]
  );

  const toggleSort = (col: 'started_at' | 'duration') => {
    if (sortBy === col) {
      setSortOrder((o) => (o === 'asc' ? 'desc' : 'asc'));
    } else {
      setSortBy(col);
      setSortOrder('desc');
    }
  };

  const totalPages = Math.ceil(totalCount / limit);
  const currentPage = Math.floor(offset / limit) + 1;

  if (isLoading) {
    return (
      <div className="animate-pulse rounded-lg border bg-white">
        <div className="border-b p-4">
          <div className="h-4 w-48 rounded bg-slate-200" />
        </div>
        {Array.from({ length: 5 }).map((_, i) => (
          <div key={i} className="flex gap-4 border-b p-4">
            <div className="h-4 w-24 rounded bg-slate-200" />
            <div className="h-4 w-16 rounded bg-slate-200" />
            <div className="h-4 w-20 rounded bg-slate-200" />
            <div className="h-4 w-16 rounded bg-slate-200" />
          </div>
        ))}
      </div>
    );
  }

  if (sessions.length === 0) {
    return (
      <div className="rounded-lg border bg-white p-8 text-center text-sm text-slate-500">
        Aucune session de travail trouvee pour les filtres selectionnes.
      </div>
    );
  }

  return (
    <div className="overflow-hidden rounded-lg border bg-white">
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="border-b bg-slate-50">
            <tr>
              <th className="px-4 py-3 text-left font-medium text-slate-600">
                Employe
              </th>
              <th className="px-4 py-3 text-left font-medium text-slate-600">
                Type
              </th>
              <th className="px-4 py-3 text-left font-medium text-slate-600">
                Lieu
              </th>
              <th className="px-4 py-3 text-left font-medium text-slate-600">
                Statut
              </th>
              <th
                className="cursor-pointer px-4 py-3 text-left font-medium text-slate-600 hover:text-slate-900"
                onClick={() => toggleSort('started_at')}
              >
                Debut{' '}
                {sortBy === 'started_at' &&
                  (sortOrder === 'asc' ? '\u2191' : '\u2193')}
              </th>
              <th
                className="cursor-pointer px-4 py-3 text-left font-medium text-slate-600 hover:text-slate-900"
                onClick={() => toggleSort('duration')}
              >
                Duree{' '}
                {sortBy === 'duration' &&
                  (sortOrder === 'asc' ? '\u2191' : '\u2193')}
              </th>
              <th className="px-4 py-3 text-left font-medium text-slate-600">
                Signalee
              </th>
              {onCloseSession && (
                <th className="px-4 py-3 text-right font-medium text-slate-600">
                  Actions
                </th>
              )}
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {sortedSessions.map((session) => (
              <SessionRow
                key={session.id}
                session={session}
                onCloseSession={onCloseSession}
              />
            ))}
          </tbody>
        </table>
      </div>

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between border-t px-4 py-3">
          <span className="text-sm text-slate-500">
            Affichage {offset + 1}\u2013
            {Math.min(offset + limit, totalCount)} sur {totalCount}
          </span>
          <div className="flex gap-1">
            <button
              disabled={currentPage <= 1}
              onClick={() => onPageChange(Math.max(0, offset - limit))}
              className="rounded px-3 py-1 text-sm font-medium text-slate-600 hover:bg-slate-100 disabled:opacity-50"
            >
              Precedent
            </button>
            <button
              disabled={currentPage >= totalPages}
              onClick={() => onPageChange(offset + limit)}
              className="rounded px-3 py-1 text-sm font-medium text-slate-600 hover:bg-slate-100 disabled:opacity-50"
            >
              Suivant
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

function SessionRow({
  session,
  onCloseSession,
}: {
  session: WorkSession;
  onCloseSession?: (id: string) => void;
}) {
  return (
    <tr className="hover:bg-slate-50">
      <td className="px-4 py-3 font-medium text-slate-900">
        {session.employeeName}
      </td>
      <td className="px-4 py-3">{activityTypeBadge(session.activityType)}</td>
      <td className="px-4 py-3 text-slate-700">{getLocationLabel(session)}</td>
      <td className="px-4 py-3">{statusBadge(session.status)}</td>
      <td className="px-4 py-3 text-slate-600">
        {formatDate(session.startedAt)} {formatTime(session.startedAt)}
      </td>
      <td className="px-4 py-3 font-medium text-slate-900">
        {formatWorkSessionDuration(session.durationMinutes)}
      </td>
      <td className="px-4 py-3">
        {session.isFlagged && (
          <span
            className="text-orange-500"
            title={session.flagReason ?? 'Signalee'}
          >
            {'\u2691'}
          </span>
        )}
      </td>
      {onCloseSession && (
        <td className="px-4 py-3 text-right">
          {session.status === 'in_progress' && (
            <button
              onClick={() => onCloseSession(session.id)}
              className="rounded px-2 py-1 text-xs font-medium text-red-600 hover:bg-red-50"
            >
              Fermer
            </button>
          )}
        </td>
      )}
    </tr>
  );
}

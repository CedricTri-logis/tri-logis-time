'use client';

import { useState, useMemo } from 'react';
import type { CleaningSession, CleaningSessionStatus } from '@/types/cleaning';
import {
  CLEANING_STATUS_LABELS,
  STUDIO_TYPE_LABELS,
  formatDuration,
} from '@/types/cleaning';

type GroupBy = 'none' | 'employee' | 'building';

interface CleaningSessionsTableProps {
  sessions: CleaningSession[];
  isLoading: boolean;
  totalCount: number;
  limit: number;
  offset: number;
  onPageChange: (offset: number) => void;
  onCloseSession?: (sessionId: string) => void;
}

function statusBadge(status: CleaningSessionStatus) {
  const colors: Record<CleaningSessionStatus, string> = {
    in_progress: 'bg-blue-100 text-blue-700',
    completed: 'bg-green-100 text-green-700',
    auto_closed: 'bg-orange-100 text-orange-700',
    manually_closed: 'bg-yellow-100 text-yellow-700',
  };

  return (
    <span
      className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ${colors[status]}`}
    >
      {CLEANING_STATUS_LABELS[status]}
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

interface GroupSummary {
  key: string;
  label: string;
  sessions: CleaningSession[];
  totalSessions: number;
  completed: number;
  avgDurationMinutes: number;
  flaggedCount: number;
  buildings?: { name: string; count: number }[];
  employees?: { name: string; count: number }[];
}

function computeGroupSummaries(
  sessions: CleaningSession[],
  groupBy: GroupBy
): GroupSummary[] {
  if (groupBy === 'none') return [];

  const groups = new Map<string, CleaningSession[]>();
  for (const s of sessions) {
    const key = groupBy === 'employee' ? s.employeeName : s.buildingName;
    const arr = groups.get(key) ?? [];
    arr.push(s);
    groups.set(key, arr);
  }

  return Array.from(groups.entries())
    .map(([key, groupSessions]) => {
      const completedSessions = groupSessions.filter(
        (s) => s.durationMinutes != null && s.status !== 'in_progress'
      );
      const avgDuration =
        completedSessions.length > 0
          ? completedSessions.reduce((sum, s) => sum + (s.durationMinutes ?? 0), 0) /
            completedSessions.length
          : 0;

      const breakdown = new Map<string, number>();
      for (const s of groupSessions) {
        const bKey = groupBy === 'employee' ? s.buildingName : s.employeeName;
        breakdown.set(bKey, (breakdown.get(bKey) ?? 0) + 1);
      }
      const breakdownArr = Array.from(breakdown.entries())
        .map(([name, count]) => ({ name, count }))
        .sort((a, b) => b.count - a.count);

      return {
        key,
        label: key,
        sessions: groupSessions,
        totalSessions: groupSessions.length,
        completed: groupSessions.filter((s) => s.status === 'completed').length,
        avgDurationMinutes: avgDuration,
        flaggedCount: groupSessions.filter((s) => s.isFlagged).length,
        ...(groupBy === 'employee'
          ? { buildings: breakdownArr }
          : { employees: breakdownArr }),
      };
    })
    .sort((a, b) => b.totalSessions - a.totalSessions);
}

export function CleaningSessionsTable({
  sessions,
  isLoading,
  totalCount,
  limit,
  offset,
  onPageChange,
  onCloseSession,
}: CleaningSessionsTableProps) {
  const [sortBy, setSortBy] = useState<'started_at' | 'duration'>('started_at');
  const [sortOrder, setSortOrder] = useState<'asc' | 'desc'>('desc');
  const [groupBy, setGroupBy] = useState<GroupBy>('none');
  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(new Set());

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

  const groupSummaries = useMemo(
    () => computeGroupSummaries(sortedSessions, groupBy),
    [sortedSessions, groupBy]
  );

  const toggleSort = (col: 'started_at' | 'duration') => {
    if (sortBy === col) {
      setSortOrder((o) => (o === 'asc' ? 'desc' : 'asc'));
    } else {
      setSortBy(col);
      setSortOrder('desc');
    }
  };

  const toggleGroup = (key: string) => {
    setExpandedGroups((prev) => {
      const next = new Set(prev);
      if (next.has(key)) {
        next.delete(key);
      } else {
        next.add(key);
      }
      return next;
    });
  };

  const totalPages = Math.ceil(totalCount / limit);
  const currentPage = Math.floor(offset / limit) + 1;
  const colCount = onCloseSession ? 9 : 8;

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
        Aucune session de ménage trouvée pour les filtres sélectionnés.
      </div>
    );
  }

  return (
    <div className="overflow-hidden rounded-lg border bg-white">
      {/* Group-by toggle */}
      <div className="flex items-center gap-2 border-b bg-slate-50 px-4 py-2">
        <span className="text-xs font-medium text-slate-500">Grouper par :</span>
        {(['none', 'employee', 'building'] as const).map((option) => (
          <button
            key={option}
            onClick={() => {
              setGroupBy(option);
              setExpandedGroups(new Set());
            }}
            className={`rounded-md px-2.5 py-1 text-xs font-medium transition-colors ${
              groupBy === option
                ? 'bg-slate-900 text-white'
                : 'text-slate-600 hover:bg-slate-200'
            }`}
          >
            {option === 'none' ? 'Aucun' : option === 'employee' ? 'Employé' : 'Immeuble'}
          </button>
        ))}
      </div>

      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="border-b bg-slate-50">
            <tr>
              <th className="px-4 py-3 text-left font-medium text-slate-600">
                Employé
              </th>
              <th className="px-4 py-3 text-left font-medium text-slate-600">
                Studio
              </th>
              <th className="px-4 py-3 text-left font-medium text-slate-600">
                Immeuble
              </th>
              <th className="px-4 py-3 text-left font-medium text-slate-600">
                Statut
              </th>
              <th
                className="cursor-pointer px-4 py-3 text-left font-medium text-slate-600 hover:text-slate-900"
                onClick={() => toggleSort('started_at')}
              >
                Début {sortBy === 'started_at' && (sortOrder === 'asc' ? '↑' : '↓')}
              </th>
              <th className="px-4 py-3 text-left font-medium text-slate-600">
                Terminée
              </th>
              <th
                className="cursor-pointer px-4 py-3 text-left font-medium text-slate-600 hover:text-slate-900"
                onClick={() => toggleSort('duration')}
              >
                Durée {sortBy === 'duration' && (sortOrder === 'asc' ? '↑' : '↓')}
              </th>
              <th className="px-4 py-3 text-left font-medium text-slate-600">
                Signalée
              </th>
              {onCloseSession && (
                <th className="px-4 py-3 text-right font-medium text-slate-600">
                  Actions
                </th>
              )}
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {groupBy === 'none'
              ? sortedSessions.map((session) => (
                  <SessionRow
                    key={session.id}
                    session={session}
                    onCloseSession={onCloseSession}
                  />
                ))
              : groupSummaries.map((group) => (
                  <GroupRows
                    key={group.key}
                    group={group}
                    groupBy={groupBy}
                    isExpanded={expandedGroups.has(group.key)}
                    onToggle={() => toggleGroup(group.key)}
                    onCloseSession={onCloseSession}
                    colCount={colCount}
                  />
                ))}
          </tbody>
        </table>
      </div>

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between border-t px-4 py-3">
          <span className="text-sm text-slate-500">
            Affichage {offset + 1}–{Math.min(offset + limit, totalCount)} sur{' '}
            {totalCount}
          </span>
          <div className="flex gap-1">
            <button
              disabled={currentPage <= 1}
              onClick={() => onPageChange(Math.max(0, offset - limit))}
              className="rounded px-3 py-1 text-sm font-medium text-slate-600 hover:bg-slate-100 disabled:opacity-50"
            >
              Précédent
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
  session: CleaningSession;
  onCloseSession?: (id: string) => void;
}) {
  return (
    <tr className="hover:bg-slate-50">
      <td className="px-4 py-3 font-medium text-slate-900">
        {session.employeeName}
      </td>
      <td className="px-4 py-3 text-slate-700">
        {session.studioNumber}
        <span className="ml-1 text-xs text-slate-400">
          {STUDIO_TYPE_LABELS[session.studioType]}
        </span>
      </td>
      <td className="px-4 py-3 text-slate-700">{session.buildingName}</td>
      <td className="px-4 py-3">{statusBadge(session.status)}</td>
      <td className="px-4 py-3 text-slate-600">
        {formatDate(session.startedAt)} {formatTime(session.startedAt)}
      </td>
      <td className="px-4 py-3 text-slate-600">
        {session.completedAt
          ? `${formatDate(session.completedAt)} ${formatTime(session.completedAt)}`
          : '—'}
      </td>
      <td className="px-4 py-3 font-medium text-slate-900">
        {formatDuration(session.durationMinutes)}
      </td>
      <td className="px-4 py-3">
        {session.isFlagged && (
          <span
            className="text-orange-500"
            title={session.flagReason ?? 'Signalée'}
          >
            ⚑
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

function GroupRows({
  group,
  groupBy,
  isExpanded,
  onToggle,
  onCloseSession,
  colCount,
}: {
  group: GroupSummary;
  groupBy: GroupBy;
  isExpanded: boolean;
  onToggle: () => void;
  onCloseSession?: (id: string) => void;
  colCount: number;
}) {
  const breakdown = groupBy === 'employee' ? group.buildings : group.employees;

  return (
    <>
      {/* Group header row */}
      <tr
        className="cursor-pointer bg-slate-50 hover:bg-slate-100"
        onClick={onToggle}
      >
        <td colSpan={colCount} className="px-4 py-3">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <span className="text-xs text-slate-400">
                {isExpanded ? '▼' : '▶'}
              </span>
              <span className="font-semibold text-slate-900">{group.label}</span>
              <span className="rounded-full bg-slate-200 px-2 py-0.5 text-xs font-medium text-slate-700">
                {group.totalSessions} session{group.totalSessions !== 1 ? 's' : ''}
              </span>
              <span className="text-xs text-green-600">
                {group.completed} terminée{group.completed !== 1 ? 's' : ''}
              </span>
              <span className="text-xs text-slate-500">
                moy. {formatDuration(group.avgDurationMinutes)}
              </span>
              {group.flaggedCount > 0 && (
                <span className="text-xs text-orange-500">
                  {group.flaggedCount} signalée{group.flaggedCount !== 1 ? 's' : ''}
                </span>
              )}
            </div>
            {/* Breakdown pills */}
            <div className="hidden items-center gap-1.5 md:flex">
              {breakdown?.slice(0, 4).map((b) => (
                <span
                  key={b.name}
                  className="rounded bg-slate-100 px-2 py-0.5 text-xs text-slate-600"
                >
                  {b.name}: {b.count}
                </span>
              ))}
              {(breakdown?.length ?? 0) > 4 && (
                <span className="text-xs text-slate-400">
                  +{(breakdown?.length ?? 0) - 4} autres
                </span>
              )}
            </div>
          </div>
        </td>
      </tr>

      {/* Expanded session rows */}
      {isExpanded &&
        group.sessions.map((session) => (
          <SessionRow
            key={session.id}
            session={session}
            onCloseSession={onCloseSession}
          />
        ))}
    </>
  );
}

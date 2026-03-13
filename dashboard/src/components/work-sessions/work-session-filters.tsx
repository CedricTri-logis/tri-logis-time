'use client';

import type { ActivityType, WorkSessionStatus } from '@/types/work-session';
import {
  ACTIVITY_TYPE_CONFIG,
  WORK_SESSION_STATUS_LABELS,
} from '@/types/work-session';
import type { WorkSessionSummary } from '@/types/work-session';
import { toLocalDateString } from '@/lib/utils/date-utils';

export interface WorkSessionFilterValues {
  activityType?: ActivityType;
  buildingId?: string;
  employeeId?: string;
  dateFrom: Date;
  dateTo: Date;
  status?: WorkSessionStatus;
}

interface WorkSessionFiltersProps {
  filters: WorkSessionFilterValues;
  onFiltersChange: (filters: WorkSessionFilterValues) => void;
  summary: WorkSessionSummary;
}

const ACTIVITY_TABS: { key: ActivityType | 'all'; label: string }[] = [
  { key: 'all', label: 'Tous' },
  { key: 'cleaning', label: 'Menage' },
  { key: 'maintenance', label: 'Entretien' },
  { key: 'admin', label: 'Admin' },
];

export function WorkSessionFilters({
  filters,
  onFiltersChange,
  summary,
}: WorkSessionFiltersProps) {
  const handleDateFromChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const date = e.target.value
      ? new Date(e.target.value + 'T00:00:00')
      : new Date();
    onFiltersChange({ ...filters, dateFrom: date });
  };

  const handleDateToChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const date = e.target.value
      ? new Date(e.target.value + 'T23:59:59')
      : new Date();
    onFiltersChange({ ...filters, dateTo: date });
  };

  const handleClearFilters = () => {
    const today = new Date();
    onFiltersChange({
      dateFrom: today,
      dateTo: today,
      activityType: undefined,
      buildingId: undefined,
      employeeId: undefined,
      status: undefined,
    });
  };

  const formatDateInput = (date: Date) => toLocalDateString(date);

  const hasFilters =
    filters.activityType || filters.buildingId || filters.employeeId || filters.status;

  function getTabCount(key: ActivityType | 'all'): number {
    if (key === 'all') return summary.totalSessions;
    return summary.byType[key] ?? 0;
  }

  return (
    <div className="space-y-4">
      {/* Activity type tabs */}
      <div className="flex gap-1 rounded-lg bg-slate-100 p-1">
        {ACTIVITY_TABS.map((tab) => {
          const isActive =
            tab.key === 'all'
              ? !filters.activityType
              : filters.activityType === tab.key;
          const count = getTabCount(tab.key);
          const config =
            tab.key !== 'all' ? ACTIVITY_TYPE_CONFIG[tab.key] : null;

          return (
            <button
              key={tab.key}
              onClick={() =>
                onFiltersChange({
                  ...filters,
                  activityType:
                    tab.key === 'all' ? undefined : tab.key,
                })
              }
              className={`flex items-center gap-2 rounded-md px-4 py-2 text-sm font-medium transition-colors ${
                isActive
                  ? 'bg-white text-slate-900 shadow-sm'
                  : 'text-slate-600 hover:text-slate-900'
              }`}
            >
              {config && (
                <span
                  className="inline-block h-2.5 w-2.5 rounded-full"
                  style={{ backgroundColor: config.color }}
                />
              )}
              {tab.label}
              <span
                className={`rounded-full px-1.5 py-0.5 text-xs ${
                  isActive
                    ? 'bg-slate-100 text-slate-700'
                    : 'bg-slate-200 text-slate-500'
                }`}
              >
                {count}
              </span>
            </button>
          );
        })}
      </div>

      {/* Date range + status filter row */}
      <div className="flex flex-wrap items-end gap-3">
        {/* Date range */}
        <div className="flex gap-2">
          <div>
            <label className="text-xs font-medium text-slate-500">De</label>
            <input
              type="date"
              value={formatDateInput(filters.dateFrom)}
              onChange={handleDateFromChange}
              className="block w-full rounded-md border border-slate-300 px-3 py-1.5 text-sm shadow-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
            />
          </div>
          <div>
            <label className="text-xs font-medium text-slate-500">A</label>
            <input
              type="date"
              value={formatDateInput(filters.dateTo)}
              onChange={handleDateToChange}
              className="block w-full rounded-md border border-slate-300 px-3 py-1.5 text-sm shadow-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
            />
          </div>
        </div>

        {/* Status filter */}
        <div>
          <label className="text-xs font-medium text-slate-500">Statut</label>
          <select
            value={filters.status ?? ''}
            onChange={(e) =>
              onFiltersChange({
                ...filters,
                status: (e.target.value || undefined) as
                  | WorkSessionStatus
                  | undefined,
              })
            }
            className="block w-full rounded-md border border-slate-300 px-3 py-1.5 text-sm shadow-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
          >
            <option value="">Tous les statuts</option>
            {Object.entries(WORK_SESSION_STATUS_LABELS).map(
              ([value, label]) => (
                <option key={value} value={value}>
                  {label}
                </option>
              )
            )}
          </select>
        </div>

        {/* Clear button */}
        {hasFilters && (
          <button
            onClick={handleClearFilters}
            className="rounded-md px-3 py-1.5 text-sm text-slate-600 hover:bg-slate-100"
          >
            Effacer les filtres
          </button>
        )}
      </div>
    </div>
  );
}

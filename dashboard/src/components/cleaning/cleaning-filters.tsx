'use client';

import { useState } from 'react';
import type { CleaningSessionStatus } from '@/types/cleaning';
import { CLEANING_STATUS_LABELS } from '@/types/cleaning';

export interface CleaningFilterValues {
  buildingId?: string;
  employeeId?: string;
  dateFrom: Date;
  dateTo: Date;
  status?: CleaningSessionStatus;
}

interface CleaningFiltersProps {
  filters: CleaningFilterValues;
  onFiltersChange: (filters: CleaningFilterValues) => void;
  buildings?: { id: string; name: string }[];
  employees?: { id: string; name: string }[];
}

export function CleaningFilters({
  filters,
  onFiltersChange,
  buildings = [],
  employees = [],
}: CleaningFiltersProps) {
  const handleDateFromChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const date = e.target.value ? new Date(e.target.value + 'T00:00:00') : new Date();
    onFiltersChange({ ...filters, dateFrom: date });
  };

  const handleDateToChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const date = e.target.value ? new Date(e.target.value + 'T23:59:59') : new Date();
    onFiltersChange({ ...filters, dateTo: date });
  };

  const handleClearFilters = () => {
    const today = new Date();
    onFiltersChange({
      dateFrom: today,
      dateTo: today,
      buildingId: undefined,
      employeeId: undefined,
      status: undefined,
    });
  };

  const formatDateInput = (date: Date) => {
    return date.toISOString().split('T')[0];
  };

  const hasFilters =
    filters.buildingId || filters.employeeId || filters.status;

  return (
    <div className="flex flex-wrap items-end gap-3">
      {/* Date range */}
      <div className="flex gap-2">
        <div>
          <label className="text-xs font-medium text-slate-500">From</label>
          <input
            type="date"
            value={formatDateInput(filters.dateFrom)}
            onChange={handleDateFromChange}
            className="block w-full rounded-md border border-slate-300 px-3 py-1.5 text-sm shadow-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
          />
        </div>
        <div>
          <label className="text-xs font-medium text-slate-500">To</label>
          <input
            type="date"
            value={formatDateInput(filters.dateTo)}
            onChange={handleDateToChange}
            className="block w-full rounded-md border border-slate-300 px-3 py-1.5 text-sm shadow-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
          />
        </div>
      </div>

      {/* Building filter */}
      {buildings.length > 0 && (
        <div>
          <label className="text-xs font-medium text-slate-500">Building</label>
          <select
            value={filters.buildingId ?? ''}
            onChange={(e) =>
              onFiltersChange({
                ...filters,
                buildingId: e.target.value || undefined,
              })
            }
            className="block w-full rounded-md border border-slate-300 px-3 py-1.5 text-sm shadow-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
          >
            <option value="">All Buildings</option>
            {buildings.map((b) => (
              <option key={b.id} value={b.id}>
                {b.name}
              </option>
            ))}
          </select>
        </div>
      )}

      {/* Employee filter */}
      {employees.length > 0 && (
        <div>
          <label className="text-xs font-medium text-slate-500">Employee</label>
          <select
            value={filters.employeeId ?? ''}
            onChange={(e) =>
              onFiltersChange({
                ...filters,
                employeeId: e.target.value || undefined,
              })
            }
            className="block w-full rounded-md border border-slate-300 px-3 py-1.5 text-sm shadow-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
          >
            <option value="">All Employees</option>
            {employees.map((emp) => (
              <option key={emp.id} value={emp.id}>
                {emp.name}
              </option>
            ))}
          </select>
        </div>
      )}

      {/* Status filter */}
      <div>
        <label className="text-xs font-medium text-slate-500">Status</label>
        <select
          value={filters.status ?? ''}
          onChange={(e) =>
            onFiltersChange({
              ...filters,
              status: (e.target.value || undefined) as CleaningSessionStatus | undefined,
            })
          }
          className="block w-full rounded-md border border-slate-300 px-3 py-1.5 text-sm shadow-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
        >
          <option value="">All Statuses</option>
          {Object.entries(CLEANING_STATUS_LABELS).map(([value, label]) => (
            <option key={value} value={value}>
              {label}
            </option>
          ))}
        </select>
      </div>

      {/* Clear button */}
      {hasFilters && (
        <button
          onClick={handleClearFilters}
          className="rounded-md px-3 py-1.5 text-sm text-slate-600 hover:bg-slate-100"
        >
          Clear filters
        </button>
      )}
    </div>
  );
}

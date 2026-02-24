'use client';

import { Search, X, ArrowUpDown } from 'lucide-react';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';
import type { TeamSortOption } from '@/types/monitoring';

type ShiftStatusFilter = 'all' | 'on-shift' | 'off-shift' | 'never-installed';

interface TeamFiltersProps {
  search: string;
  shiftStatus: ShiftStatusFilter;
  sortBy: TeamSortOption;
  onSearchChange: (value: string) => void;
  onShiftStatusChange: (value: ShiftStatusFilter) => void;
  onSortChange: (value: TeamSortOption) => void;
  onClearFilters: () => void;
}

/**
 * Filter controls for the team list - search, shift status toggle, and sort.
 */
export function TeamFilters({
  search,
  shiftStatus,
  sortBy,
  onSearchChange,
  onShiftStatusChange,
  onSortChange,
  onClearFilters,
}: TeamFiltersProps) {
  const hasActiveFilters = search !== '' || shiftStatus !== 'all';

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        {/* Search input */}
        <div className="relative flex-1 max-w-sm">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
          <Input
            placeholder="Search by name, email or ID..."
            value={search}
            onChange={(e) => onSearchChange(e.target.value)}
            className="pl-10 pr-10"
          />
          {search && (
            <button
              onClick={() => onSearchChange('')}
              className="absolute right-3 top-1/2 -translate-y-1/2 text-slate-400 hover:text-slate-600"
            >
              <X className="h-4 w-4" />
            </button>
          )}
        </div>

        <div className="flex items-center gap-3">
          {/* Sort toggle */}
          <SortToggle value={sortBy} onChange={onSortChange} />

          {/* Clear filters button */}
          {hasActiveFilters && (
            <Button
              variant="ghost"
              size="sm"
              onClick={onClearFilters}
              className="text-slate-500"
            >
              Clear filters
            </Button>
          )}
        </div>
      </div>

      {/* Shift status toggle - on its own row for space */}
      <ShiftStatusToggle
        value={shiftStatus}
        onChange={onShiftStatusChange}
      />
    </div>
  );
}

interface ShiftStatusToggleProps {
  value: ShiftStatusFilter;
  onChange: (value: ShiftStatusFilter) => void;
}

function ShiftStatusToggle({ value, onChange }: ShiftStatusToggleProps) {
  const options: { value: ShiftStatusFilter; label: string }[] = [
    { value: 'all', label: 'All' },
    { value: 'on-shift', label: 'On Shift' },
    { value: 'off-shift', label: 'Off Shift' },
    { value: 'never-installed', label: 'Never Installed' },
  ];

  return (
    <div className="inline-flex rounded-lg border border-slate-200 bg-slate-50 p-1">
      {options.map((option) => (
        <button
          key={option.value}
          onClick={() => onChange(option.value)}
          className={cn(
            'px-3 py-1.5 text-sm font-medium rounded-md transition-colors whitespace-nowrap',
            value === option.value
              ? 'bg-white text-slate-900 shadow-sm'
              : 'text-slate-600 hover:text-slate-900'
          )}
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}

interface SortToggleProps {
  value: TeamSortOption;
  onChange: (value: TeamSortOption) => void;
}

function SortToggle({ value, onChange }: SortToggleProps) {
  const options: { value: TeamSortOption; label: string }[] = [
    { value: 'name', label: 'Name' },
    { value: 'last-connection', label: 'Last Connection' },
  ];

  return (
    <div className="flex items-center gap-2">
      <ArrowUpDown className="h-4 w-4 text-slate-400" />
      <div className="inline-flex rounded-lg border border-slate-200 bg-slate-50 p-1">
        {options.map((option) => (
          <button
            key={option.value}
            onClick={() => onChange(option.value)}
            className={cn(
              'px-2.5 py-1 text-xs font-medium rounded-md transition-colors whitespace-nowrap',
              value === option.value
                ? 'bg-white text-slate-900 shadow-sm'
                : 'text-slate-600 hover:text-slate-900'
            )}
          >
            {option.label}
          </button>
        ))}
      </div>
    </div>
  );
}

/**
 * Compact filter bar for small spaces
 */
interface CompactFiltersProps {
  search: string;
  onSearchChange: (value: string) => void;
}

export function CompactFilters({ search, onSearchChange }: CompactFiltersProps) {
  return (
    <div className="relative">
      <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
      <Input
        placeholder="Search..."
        value={search}
        onChange={(e) => onSearchChange(e.target.value)}
        className="pl-10 h-9 text-sm"
      />
    </div>
  );
}

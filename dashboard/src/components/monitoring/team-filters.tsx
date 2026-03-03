'use client';

import { Search, X, ArrowUp, ArrowDown } from 'lucide-react';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';
import type { SortDirection, TeamSortOption } from '@/types/monitoring';

type ShiftStatusFilter = 'all' | 'on-shift' | 'off-shift' | 'never-installed';

interface TeamFiltersProps {
  search: string;
  shiftStatus: ShiftStatusFilter;
  sortBy: TeamSortOption;
  sortDirection: SortDirection;
  onSearchChange: (value: string) => void;
  onShiftStatusChange: (value: ShiftStatusFilter) => void;
  onSortChange: (value: TeamSortOption) => void;
  onSortDirectionToggle: () => void;
  onClearFilters: () => void;
}

/**
 * Filter controls for the team list - search, shift status toggle, and sort.
 */
export function TeamFilters({
  search,
  shiftStatus,
  sortBy,
  sortDirection,
  onSearchChange,
  onShiftStatusChange,
  onSortChange,
  onSortDirectionToggle,
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
            placeholder="Rechercher par nom, courriel ou ID..."
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
          <SortToggle value={sortBy} direction={sortDirection} onChange={onSortChange} onDirectionToggle={onSortDirectionToggle} />

          {/* Clear filters button */}
          {hasActiveFilters && (
            <Button
              variant="ghost"
              size="sm"
              onClick={onClearFilters}
              className="text-slate-500"
            >
              Effacer les filtres
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
    { value: 'all', label: 'Tous' },
    { value: 'on-shift', label: 'En quart' },
    { value: 'off-shift', label: 'Hors quart' },
    { value: 'never-installed', label: 'Jamais installé' },
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
  direction: SortDirection;
  onChange: (value: TeamSortOption) => void;
  onDirectionToggle: () => void;
}

function SortToggle({ value, direction, onChange, onDirectionToggle }: SortToggleProps) {
  const options: { value: TeamSortOption; label: string }[] = [
    { value: 'name', label: 'Nom' },
    { value: 'last-connection', label: 'Dernière connexion' },
    { value: 'last-gps', label: 'Dernier GPS' },
  ];

  const DirectionIcon = direction === 'asc' ? ArrowUp : ArrowDown;
  const directionLabel = value === 'name'
    ? (direction === 'asc' ? 'A → Z' : 'Z → A')
    : (direction === 'asc' ? 'Plus ancien' : 'Plus récent');

  return (
    <div className="flex items-center gap-2">
      <button
        onClick={onDirectionToggle}
        className="flex items-center gap-1 text-slate-500 hover:text-slate-700 transition-colors"
        title={directionLabel}
      >
        <DirectionIcon className="h-4 w-4" />
        <span className="text-xs hidden sm:inline">{directionLabel}</span>
      </button>
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
        placeholder="Rechercher..."
        value={search}
        onChange={(e) => onSearchChange(e.target.value)}
        className="pl-10 h-9 text-sm"
      />
    </div>
  );
}

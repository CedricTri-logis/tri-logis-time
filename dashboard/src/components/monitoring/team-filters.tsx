'use client';

import { Search, X } from 'lucide-react';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';

interface TeamFiltersProps {
  search: string;
  shiftStatus: 'all' | 'on-shift' | 'off-shift';
  onSearchChange: (value: string) => void;
  onShiftStatusChange: (value: 'all' | 'on-shift' | 'off-shift') => void;
  onClearFilters: () => void;
}

/**
 * Filter controls for the team list - search and shift status toggle.
 */
export function TeamFilters({
  search,
  shiftStatus,
  onSearchChange,
  onShiftStatusChange,
  onClearFilters,
}: TeamFiltersProps) {
  const hasActiveFilters = search !== '' || shiftStatus !== 'all';

  return (
    <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
      {/* Search input */}
      <div className="relative flex-1 max-w-sm">
        <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
        <Input
          placeholder="Search by name or ID..."
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
        {/* Shift status toggle */}
        <ShiftStatusToggle
          value={shiftStatus}
          onChange={onShiftStatusChange}
        />

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
  );
}

interface ShiftStatusToggleProps {
  value: 'all' | 'on-shift' | 'off-shift';
  onChange: (value: 'all' | 'on-shift' | 'off-shift') => void;
}

function ShiftStatusToggle({ value, onChange }: ShiftStatusToggleProps) {
  const options: { value: 'all' | 'on-shift' | 'off-shift'; label: string }[] = [
    { value: 'all', label: 'All' },
    { value: 'on-shift', label: 'On Shift' },
    { value: 'off-shift', label: 'Off Shift' },
  ];

  return (
    <div className="inline-flex rounded-lg border border-slate-200 bg-slate-50 p-1">
      {options.map((option) => (
        <button
          key={option.value}
          onClick={() => onChange(option.value)}
          className={cn(
            'px-3 py-1.5 text-sm font-medium rounded-md transition-colors',
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

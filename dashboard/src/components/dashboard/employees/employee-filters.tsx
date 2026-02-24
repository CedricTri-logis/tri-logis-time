'use client';

import { useCallback } from 'react';
import { Search, X } from 'lucide-react';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { EmployeeRole, EmployeeStatus } from '@/lib/validations/employee';
import type { EmployeeRoleType, EmployeeStatusType } from '@/lib/validations/employee';

interface EmployeeFiltersProps {
  search: string;
  role: EmployeeRoleType | '';
  status: EmployeeStatusType | '';
  onSearchChange: (value: string) => void;
  onRoleChange: (value: EmployeeRoleType | '') => void;
  onStatusChange: (value: EmployeeStatusType | '') => void;
  onClearFilters: () => void;
}

export function EmployeeFilters({
  search,
  role,
  status,
  onSearchChange,
  onRoleChange,
  onStatusChange,
  onClearFilters,
}: EmployeeFiltersProps) {
  const hasActiveFilters = search !== '' || role !== '' || status !== '';

  const handleRoleChange = useCallback(
    (value: string) => {
      onRoleChange(value === 'all' ? '' : (value as EmployeeRoleType));
    },
    [onRoleChange]
  );

  const handleStatusChange = useCallback(
    (value: string) => {
      onStatusChange(value === 'all' ? '' : (value as EmployeeStatusType));
    },
    [onStatusChange]
  );

  return (
    <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
      <div className="flex flex-1 items-center gap-3">
        {/* Search Input */}
        <div className="relative flex-1 max-w-sm">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
          <Input
            placeholder="Search by name, email, or ID..."
            value={search}
            onChange={(e) => onSearchChange(e.target.value)}
            className="pl-9"
          />
        </div>

        {/* Role Filter */}
        <Select value={role || 'all'} onValueChange={handleRoleChange}>
          <SelectTrigger className="w-[140px]">
            <SelectValue placeholder="All Roles" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">All Roles</SelectItem>
            <SelectItem value={EmployeeRole.EMPLOYEE}>Employee</SelectItem>
            <SelectItem value={EmployeeRole.MANAGER}>Manager</SelectItem>
            <SelectItem value={EmployeeRole.ADMIN}>Admin</SelectItem>
            <SelectItem value={EmployeeRole.SUPER_ADMIN}>Super Admin</SelectItem>
          </SelectContent>
        </Select>

        {/* Status Filter */}
        <Select value={status || 'all'} onValueChange={handleStatusChange}>
          <SelectTrigger className="w-[140px]">
            <SelectValue placeholder="All Statuses" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">All Statuses</SelectItem>
            <SelectItem value={EmployeeStatus.ACTIVE}>Active</SelectItem>
            <SelectItem value={EmployeeStatus.INACTIVE}>Inactive</SelectItem>
            <SelectItem value={EmployeeStatus.SUSPENDED}>Suspended</SelectItem>
          </SelectContent>
        </Select>
      </div>

      {/* Clear Filters Button */}
      {hasActiveFilters && (
        <Button
          variant="ghost"
          size="sm"
          onClick={onClearFilters}
          className="text-slate-500 hover:text-slate-700"
        >
          <X className="mr-1 h-4 w-4" />
          Clear filters
        </Button>
      )}
    </div>
  );
}

// Helper function to format active filters for display
export function formatActiveFilters(
  search: string,
  role: EmployeeRoleType | '',
  status: EmployeeStatusType | ''
): string {
  const parts: string[] = [];

  if (search) {
    parts.push(`"${search}"`);
  }
  if (role) {
    const roleLabel = {
      employee: 'Employee',
      manager: 'Manager',
      admin: 'Admin',
      super_admin: 'Super Admin',
    }[role];
    parts.push(roleLabel);
  }
  if (status) {
    const statusLabel = {
      active: 'Active',
      inactive: 'Inactive',
      suspended: 'Suspended',
    }[status];
    parts.push(statusLabel);
  }

  return parts.join(', ');
}

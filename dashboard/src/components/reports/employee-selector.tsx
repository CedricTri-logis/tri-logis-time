'use client';

/**
 * Employee Selector Component
 * Spec: 013-reports-export
 *
 * Multi-select employee picker for bulk report generation
 */

import { useState, useMemo } from 'react';
import { Check, ChevronsUpDown, Users, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from '@/components/ui/command';
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from '@/components/ui/popover';
import { cn } from '@/lib/utils';
import type { EmployeeOption } from '@/types/reports';

interface EmployeeSelectorProps {
  employees: EmployeeOption[];
  selectedIds: string[];
  onChange: (ids: string[]) => void;
  placeholder?: string;
  maxSelected?: number;
  disabled?: boolean;
}

export function EmployeeSelector({
  employees,
  selectedIds,
  onChange,
  placeholder = 'Select employees...',
  maxSelected = 50,
  disabled = false,
}: EmployeeSelectorProps) {
  const [open, setOpen] = useState(false);
  const [searchValue, setSearchValue] = useState('');

  // Get selected employee details
  const selectedEmployees = useMemo(() => {
    return employees.filter((emp) => selectedIds.includes(emp.id));
  }, [employees, selectedIds]);

  // Filter employees based on search
  const filteredEmployees = useMemo(() => {
    if (!searchValue) return employees;

    const search = searchValue.toLowerCase();
    return employees.filter(
      (emp) =>
        emp.full_name.toLowerCase().includes(search) ||
        (emp.employee_id && emp.employee_id.toLowerCase().includes(search))
    );
  }, [employees, searchValue]);

  /**
   * Toggle employee selection
   */
  const toggleEmployee = (employeeId: string) => {
    if (selectedIds.includes(employeeId)) {
      onChange(selectedIds.filter((id) => id !== employeeId));
    } else {
      if (selectedIds.length >= maxSelected) {
        return; // Don't allow more than max
      }
      onChange([...selectedIds, employeeId]);
    }
  };

  /**
   * Remove a specific employee
   */
  const removeEmployee = (employeeId: string) => {
    onChange(selectedIds.filter((id) => id !== employeeId));
  };

  /**
   * Select all visible employees
   */
  const selectAll = () => {
    const visibleIds = filteredEmployees.map((e) => e.id).slice(0, maxSelected);
    onChange(visibleIds);
  };

  /**
   * Clear all selections
   */
  const clearAll = () => {
    onChange([]);
  };

  return (
    <div className="space-y-2">
      <Popover open={open} onOpenChange={setOpen}>
        <PopoverTrigger asChild>
          <Button
            variant="outline"
            role="combobox"
            aria-expanded={open}
            disabled={disabled}
            className="w-full justify-between"
          >
            <span className="flex items-center gap-2">
              <Users className="h-4 w-4" />
              {selectedIds.length === 0
                ? placeholder
                : `${selectedIds.length} employee${selectedIds.length > 1 ? 's' : ''} selected`}
            </span>
            <ChevronsUpDown className="ml-2 h-4 w-4 shrink-0 opacity-50" />
          </Button>
        </PopoverTrigger>
        <PopoverContent className="w-[400px] p-0" align="start">
          <Command shouldFilter={false}>
            <CommandInput
              placeholder="Search employees..."
              value={searchValue}
              onValueChange={setSearchValue}
            />
            <div className="flex items-center gap-2 border-b px-3 py-2">
              <Button
                variant="ghost"
                size="sm"
                onClick={selectAll}
                disabled={filteredEmployees.length === 0}
              >
                Select All
              </Button>
              <Button
                variant="ghost"
                size="sm"
                onClick={clearAll}
                disabled={selectedIds.length === 0}
              >
                Clear All
              </Button>
              <span className="text-xs text-slate-500 ml-auto">
                {selectedIds.length}/{maxSelected} max
              </span>
            </div>
            <CommandList>
              <CommandEmpty>No employees found.</CommandEmpty>
              <CommandGroup>
                {filteredEmployees.map((employee) => {
                  const isSelected = selectedIds.includes(employee.id);
                  const isDisabled = !isSelected && selectedIds.length >= maxSelected;

                  return (
                    <CommandItem
                      key={employee.id}
                      value={employee.id}
                      onSelect={() => toggleEmployee(employee.id)}
                      disabled={isDisabled}
                      className={cn(
                        'cursor-pointer',
                        isDisabled && 'opacity-50 cursor-not-allowed'
                      )}
                    >
                      <div
                        className={cn(
                          'mr-2 flex h-4 w-4 items-center justify-center rounded-sm border border-primary',
                          isSelected
                            ? 'bg-primary text-primary-foreground'
                            : 'opacity-50 [&_svg]:invisible'
                        )}
                      >
                        <Check className="h-3 w-3" />
                      </div>
                      <div className="flex-1">
                        <div className="font-medium">{employee.full_name}</div>
                        {employee.employee_id && (
                          <div className="text-xs text-slate-500">{employee.employee_id}</div>
                        )}
                      </div>
                    </CommandItem>
                  );
                })}
              </CommandGroup>
            </CommandList>
          </Command>
        </PopoverContent>
      </Popover>

      {/* Selected employee badges */}
      {selectedEmployees.length > 0 && (
        <div className="flex flex-wrap gap-1">
          {selectedEmployees.slice(0, 10).map((employee) => (
            <Badge
              key={employee.id}
              variant="secondary"
              className="flex items-center gap-1"
            >
              {employee.full_name}
              <button
                type="button"
                onClick={() => removeEmployee(employee.id)}
                className="ml-1 rounded-full hover:bg-slate-300 p-0.5"
              >
                <X className="h-3 w-3" />
              </button>
            </Badge>
          ))}
          {selectedEmployees.length > 10 && (
            <Badge variant="outline">+{selectedEmployees.length - 10} more</Badge>
          )}
        </div>
      )}
    </div>
  );
}

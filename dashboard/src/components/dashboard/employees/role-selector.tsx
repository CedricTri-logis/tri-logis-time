'use client';

import { useMemo } from 'react';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { EmployeeRole, type EmployeeRoleType } from '@/lib/validations/employee';

interface RoleSelectorProps {
  currentRole: EmployeeRoleType;
  onRoleChange: (role: EmployeeRoleType) => void;
  isDisabled?: boolean;
  callerIsSuperAdmin?: boolean;
}

export function RoleSelector({
  currentRole,
  onRoleChange,
  isDisabled = false,
  callerIsSuperAdmin = false,
}: RoleSelectorProps) {
  // Build available role options based on caller's permissions
  const roleOptions = useMemo(() => {
    const baseOptions: Array<{ value: EmployeeRoleType; label: string }> = [
      { value: EmployeeRole.EMPLOYEE, label: 'Employee' },
      { value: EmployeeRole.MANAGER, label: 'Manager' },
      { value: EmployeeRole.ADMIN, label: 'Admin' },
    ];

    // Only super_admin can assign super_admin role
    if (callerIsSuperAdmin) {
      baseOptions.push({ value: EmployeeRole.SUPER_ADMIN, label: 'Super Admin' });
    }

    return baseOptions;
  }, [callerIsSuperAdmin]);

  // If viewing a super_admin as a non-super_admin, just show the current value
  if (currentRole === 'super_admin' && !callerIsSuperAdmin) {
    return (
      <div className="space-y-2">
        <p className="text-sm font-medium">Current Role</p>
        <div className="rounded-md border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700">
          Super Admin (Protected)
        </div>
        <p className="text-xs text-slate-500">
          Only super admins can modify this role.
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <p className="text-sm font-medium">Role</p>
      <Select
        value={currentRole}
        onValueChange={(value) => onRoleChange(value as EmployeeRoleType)}
        disabled={isDisabled}
      >
        <SelectTrigger className="w-full">
          <SelectValue placeholder="Select role" />
        </SelectTrigger>
        <SelectContent>
          {roleOptions.map((option) => (
            <SelectItem key={option.value} value={option.value}>
              {option.label}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      <p className="text-xs text-slate-500">
        Changing roles will immediately affect user access permissions.
      </p>
    </div>
  );
}

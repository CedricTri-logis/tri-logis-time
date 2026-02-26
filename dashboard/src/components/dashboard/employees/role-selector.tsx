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
      { value: EmployeeRole.EMPLOYEE, label: 'Employé' },
      { value: EmployeeRole.MANAGER, label: 'Gestionnaire' },
      { value: EmployeeRole.ADMIN, label: 'Admin' },
    ];

    // Only super_admin can assign super_admin role
    if (callerIsSuperAdmin) {
      baseOptions.push({ value: EmployeeRole.SUPER_ADMIN, label: 'Super admin' });
    }

    return baseOptions;
  }, [callerIsSuperAdmin]);

  // If viewing a super_admin as a non-super_admin, just show the current value
  if (currentRole === 'super_admin' && !callerIsSuperAdmin) {
    return (
      <div className="space-y-2">
        <p className="text-sm font-medium">Rôle actuel</p>
        <div className="rounded-md border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700">
          Super admin (Protégé)
        </div>
        <p className="text-xs text-slate-500">
          Seuls les super admins peuvent modifier ce rôle.
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <p className="text-sm font-medium">Rôle</p>
      <Select
        value={currentRole}
        onValueChange={(value) => onRoleChange(value as EmployeeRoleType)}
        disabled={isDisabled}
      >
        <SelectTrigger className="w-full">
          <SelectValue placeholder="Sélectionner un rôle" />
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
        Le changement de rôle affectera immédiatement les permissions d&apos;accès de l&apos;utilisateur.
      </p>
    </div>
  );
}

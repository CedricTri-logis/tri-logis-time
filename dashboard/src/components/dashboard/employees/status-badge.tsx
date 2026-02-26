'use client';

import { Badge } from '@/components/ui/badge';
import type { EmployeeStatusType, EmployeeRoleType } from '@/lib/validations/employee';

interface StatusBadgeProps {
  status: EmployeeStatusType;
}

export function StatusBadge({ status }: StatusBadgeProps) {
  const variants: Record<EmployeeStatusType, { variant: 'default' | 'secondary' | 'destructive' | 'outline'; label: string }> = {
    active: { variant: 'default', label: 'Actif' },
    inactive: { variant: 'secondary', label: 'Inactif' },
    suspended: { variant: 'destructive', label: 'Suspendu' },
  };

  const { variant, label } = variants[status] ?? { variant: 'outline' as const, label: status };

  return (
    <Badge variant={variant} className="capitalize">
      {label}
    </Badge>
  );
}

interface RoleBadgeProps {
  role: EmployeeRoleType;
}

export function RoleBadge({ role }: RoleBadgeProps) {
  const variants: Record<EmployeeRoleType, { variant: 'default' | 'secondary' | 'destructive' | 'outline'; label: string }> = {
    super_admin: { variant: 'destructive', label: 'Super admin' },
    admin: { variant: 'default', label: 'Admin' },
    manager: { variant: 'secondary', label: 'Gestionnaire' },
    employee: { variant: 'outline', label: 'Employé' },
  };

  const { variant, label } = variants[role] ?? { variant: 'outline' as const, label: role };

  return (
    <Badge variant={variant} className="capitalize">
      {label}
    </Badge>
  );
}

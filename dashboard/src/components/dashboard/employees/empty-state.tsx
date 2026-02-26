'use client';

import { Users } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { formatActiveFilters } from './employee-filters';
import type { EmployeeRoleType, EmployeeStatusType } from '@/lib/validations/employee';

interface EmptyStateProps {
  search: string;
  role: EmployeeRoleType | '';
  status: EmployeeStatusType | '';
  onClearFilters: () => void;
}

export function EmptyState({
  search,
  role,
  status,
  onClearFilters,
}: EmptyStateProps) {
  const hasActiveFilters = search !== '' || role !== '' || status !== '';
  const filterDescription = formatActiveFilters(search, role, status);

  return (
    <div className="flex flex-col items-center justify-center py-12 text-center">
      <div className="rounded-full bg-slate-100 p-4">
        <Users className="h-8 w-8 text-slate-400" />
      </div>
      <h3 className="mt-4 text-lg font-semibold text-slate-900">
        Aucun employé trouvé
      </h3>
      {hasActiveFilters ? (
        <>
          <p className="mt-2 max-w-md text-sm text-slate-500">
            Aucun employé ne correspond à vos filtres actuels : {filterDescription}
          </p>
          <Button
            variant="outline"
            onClick={onClearFilters}
            className="mt-4"
          >
            Effacer les filtres
          </Button>
        </>
      ) : (
        <p className="mt-2 text-sm text-slate-500">
          Aucun employé dans le système pour le moment.
        </p>
      )}
    </div>
  );
}

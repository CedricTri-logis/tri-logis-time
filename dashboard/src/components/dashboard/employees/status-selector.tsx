'use client';

import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { AlertTriangle } from 'lucide-react';
import { EmployeeStatus, type EmployeeStatusType } from '@/lib/validations/employee';

interface StatusSelectorProps {
  currentStatus: EmployeeStatusType;
  onStatusChange: (status: EmployeeStatusType) => void;
  isDisabled?: boolean;
  hasActiveShift?: boolean;
}

export function StatusSelector({
  currentStatus,
  onStatusChange,
  isDisabled = false,
  hasActiveShift = false,
}: StatusSelectorProps) {
  const statusOptions = [
    {
      value: EmployeeStatus.ACTIVE,
      label: 'Actif',
      description: 'L\'employé peut se connecter et utiliser le système',
    },
    {
      value: EmployeeStatus.INACTIVE,
      label: 'Inactif',
      description: 'Départ permanent - l\'employé ne peut pas se connecter',
    },
    {
      value: EmployeeStatus.SUSPENDED,
      label: 'Suspendu',
      description: 'Suspension temporaire - l\'employé ne peut pas se connecter',
    },
  ];

  return (
    <div className="space-y-2">
      <p className="text-sm font-medium">Statut du compte</p>
      <Select
        value={currentStatus}
        onValueChange={(value) => onStatusChange(value as EmployeeStatusType)}
        disabled={isDisabled}
      >
        <SelectTrigger className="w-full">
          <SelectValue placeholder="Sélectionner un statut" />
        </SelectTrigger>
        <SelectContent>
          {statusOptions.map((option) => (
            <SelectItem key={option.value} value={option.value}>
              <div className="flex flex-col">
                <span>{option.label}</span>
                <span className="text-xs text-slate-500">{option.description}</span>
              </div>
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      {/* Active shift warning */}
      {hasActiveShift && currentStatus === 'active' && (
        <div className="flex items-start gap-2 rounded-md border border-amber-200 bg-amber-50 p-3">
          <AlertTriangle className="mt-0.5 h-4 w-4 text-amber-600 flex-shrink-0" />
          <div className="text-xs text-amber-800">
            <p className="font-medium">Quart de travail actif en cours</p>
            <p className="mt-0.5">
              Cet employé a actuellement un quart de travail actif. Le désactiver ou le suspendre
              laissera le quart ouvert.
            </p>
          </div>
        </div>
      )}

      {/* Status descriptions */}
      <div className="text-xs text-slate-500 space-y-1">
        {currentStatus === 'active' && (
          <p>L&apos;employé peut se connecter et utiliser l&apos;application mobile.</p>
        )}
        {currentStatus === 'inactive' && (
          <p>
            L&apos;employé ne peut pas se connecter. Utilisez ce statut pour les départs permanents.
            Les données historiques sont conservées.
          </p>
        )}
        {currentStatus === 'suspended' && (
          <p>
            L&apos;employé ne peut pas se connecter temporairement. Utilisez ce statut pour les suspensions
            temporaires comme les congés ou les enquêtes.
          </p>
        )}
      </div>
    </div>
  );
}

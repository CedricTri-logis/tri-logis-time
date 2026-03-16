'use client';

import { useState } from 'react';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { updateEmployeePayType } from '@/lib/api/remuneration';
import type { EmployeeRateListItem } from '@/types/remuneration';

interface PayTypeSwitchProps {
  employee: EmployeeRateListItem | null;
  onClose: () => void;
  onSaved: () => void;
}

export function PayTypeSwitch({ employee, onClose, onSaved }: PayTypeSwitchProps) {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!employee) return null;

  const targetType = employee.pay_type === 'hourly' ? 'annual' : 'hourly';
  const targetLabel = targetType === 'annual' ? 'Annuel' : 'Horaire';

  const handleConfirm = async () => {
    setSaving(true);
    setError(null);
    try {
      await updateEmployeePayType(employee.employee_id, targetType);
      onSaved();
    } catch (e: any) {
      const msg = e.message || 'Erreur lors du changement';
      if (msg.includes('no active')) {
        setError(
          targetType === 'annual'
            ? 'Vous devez d\'abord définir un salaire annuel pour cet employé.'
            : 'Vous devez d\'abord définir un taux horaire pour cet employé.'
        );
      } else {
        setError(msg);
      }
      setSaving(false);
    }
  };

  return (
    <AlertDialog open={employee !== null} onOpenChange={() => onClose()}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>
            Changer le type de rémunération
          </AlertDialogTitle>
          <AlertDialogDescription>
            Changer {employee.full_name} de{' '}
            <strong>{employee.pay_type === 'hourly' ? 'Horaire' : 'Annuel'}</strong> à{' '}
            <strong>{targetLabel}</strong> ?
            {targetType === 'annual'
              ? ' Le salaire annuel sera divisé par 26 périodes.'
              : ' Les heures approuvées seront multipliées par le taux horaire.'}
          </AlertDialogDescription>
        </AlertDialogHeader>
        {error && (
          <p className="text-sm text-destructive px-6">{error}</p>
        )}
        <AlertDialogFooter>
          <AlertDialogCancel disabled={saving}>Annuler</AlertDialogCancel>
          <AlertDialogAction onClick={handleConfirm} disabled={saving}>
            {saving ? 'Changement...' : `Passer à ${targetLabel}`}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

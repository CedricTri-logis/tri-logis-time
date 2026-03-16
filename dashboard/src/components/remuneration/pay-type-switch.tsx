'use client';

import { useState } from 'react';
import {
  AlertDialog,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { updateEmployeePayType, upsertEmployeeSalary, upsertEmployeeRate } from '@/lib/api/remuneration';
import type { EmployeeRateListItem } from '@/types/remuneration';

interface PayTypeSwitchProps {
  employee: EmployeeRateListItem | null;
  onClose: () => void;
  onSaved: () => void;
}

export function PayTypeSwitch({ employee, onClose, onSaved }: PayTypeSwitchProps) {
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // When target compensation is missing, show inline form
  const [needsCompensation, setNeedsCompensation] = useState(false);
  const [compensationValue, setCompensationValue] = useState('');
  const [effectiveFrom, setEffectiveFrom] = useState(
    new Date().toISOString().split('T')[0]
  );

  if (!employee) return null;

  const targetType = employee.pay_type === 'hourly' ? 'annual' : 'hourly';
  const targetLabel = targetType === 'annual' ? 'Annuel' : 'Horaire';

  // Check upfront if target compensation is missing
  const targetCompensationMissing =
    (targetType === 'annual' && employee.current_salary === null) ||
    (targetType === 'hourly' && employee.current_rate === null);

  const handleConfirm = async () => {
    setSaving(true);
    setError(null);

    try {
      // If compensation is missing and user hasn't filled the form yet, show it
      if (targetCompensationMissing && !needsCompensation) {
        setNeedsCompensation(true);
        setSaving(false);
        return;
      }

      // If user filled the compensation form, save it first
      if (needsCompensation) {
        const parsed = parseFloat(compensationValue);
        if (isNaN(parsed) || parsed <= 0) {
          setError(
            targetType === 'annual'
              ? 'Le salaire doit être supérieur à 0'
              : 'Le taux doit être supérieur à 0'
          );
          setSaving(false);
          return;
        }
        if (!effectiveFrom) {
          setError('La date est requise');
          setSaving(false);
          return;
        }

        // Save the compensation
        if (targetType === 'annual') {
          await upsertEmployeeSalary(employee.employee_id, parsed, effectiveFrom);
        } else {
          await upsertEmployeeRate(employee.employee_id, parsed, effectiveFrom);
        }
      }

      // Now switch the pay type
      await updateEmployeePayType(employee.employee_id, targetType);
      onSaved();
    } catch (e: any) {
      setError(e.message || 'Erreur lors du changement');
      setSaving(false);
    }
  };

  const handleClose = () => {
    setNeedsCompensation(false);
    setCompensationValue('');
    setError(null);
    onClose();
  };

  const biweeklyPreview =
    targetType === 'annual' && compensationValue
      ? (parseFloat(compensationValue) / 26).toFixed(2)
      : null;

  return (
    <AlertDialog open={employee !== null} onOpenChange={handleClose}>
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

        {/* Inline compensation form when target has no active rate/salary */}
        {needsCompensation && (
          <div className="space-y-4 px-6">
            <div className="rounded-md bg-muted p-3 text-sm">
              {targetType === 'annual'
                ? 'Aucun salaire annuel défini. Entrez-le pour continuer.'
                : 'Aucun taux horaire défini. Entrez-le pour continuer.'}
            </div>
            <div className="space-y-2">
              <Label htmlFor="compensation-value">
                {targetType === 'annual' ? 'Salaire annuel ($/an)' : 'Taux horaire ($/h)'}
              </Label>
              <Input
                id="compensation-value"
                type="number"
                step="0.01"
                min="0.01"
                value={compensationValue}
                onChange={(e) => setCompensationValue(e.target.value)}
                placeholder={targetType === 'annual' ? 'ex: 52000.00' : 'ex: 20.00'}
              />
              {biweeklyPreview && (
                <p className="text-xs text-muted-foreground">
                  Équivalent aux 2 semaines : {parseFloat(biweeklyPreview).toLocaleString('fr-CA')} $
                </p>
              )}
            </div>
            <div className="space-y-2">
              <Label htmlFor="effective-from">Date d&apos;entrée en vigueur</Label>
              <Input
                id="effective-from"
                type="date"
                value={effectiveFrom}
                onChange={(e) => setEffectiveFrom(e.target.value)}
              />
            </div>
          </div>
        )}

        {error && (
          <p className="text-sm text-destructive px-6">{error}</p>
        )}
        <AlertDialogFooter>
          <AlertDialogCancel disabled={saving} onClick={handleClose}>Annuler</AlertDialogCancel>
          <Button onClick={handleConfirm} disabled={saving}>
            {saving
              ? 'Changement...'
              : needsCompensation
                ? `Enregistrer et passer à ${targetLabel}`
                : `Passer à ${targetLabel}`}
          </Button>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

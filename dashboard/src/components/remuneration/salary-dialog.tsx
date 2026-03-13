'use client';

import { useState, useEffect } from 'react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { upsertEmployeeSalary } from '@/lib/api/remuneration';
import type { EmployeeRateListItem } from '@/types/remuneration';

interface SalaryDialogProps {
  employee: EmployeeRateListItem | null;
  onClose: () => void;
  onSaved: () => void;
}

export function SalaryDialog({ employee, onClose, onSaved }: SalaryDialogProps) {
  const [salary, setSalary] = useState('');
  const [effectiveFrom, setEffectiveFrom] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (employee) {
      setSalary(employee.current_salary?.toString() ?? '');
      setEffectiveFrom(new Date().toISOString().split('T')[0]);
      setError(null);
    }
  }, [employee]);

  const handleSave = async () => {
    setError(null);
    const parsedSalary = parseFloat(salary);
    if (isNaN(parsedSalary) || parsedSalary <= 0) {
      setError('Le salaire doit être supérieur à 0');
      return;
    }
    if (!effectiveFrom) {
      setError('La date est requise');
      return;
    }

    setSaving(true);
    try {
      await upsertEmployeeSalary(employee!.employee_id, parsedSalary, effectiveFrom);
      onSaved();
    } catch (e: any) {
      setError(e.message || 'Erreur lors de la sauvegarde');
    } finally {
      setSaving(false);
    }
  };

  const biweeklyAmount = salary ? (parseFloat(salary) / 26).toFixed(2) : null;

  return (
    <Dialog open={employee !== null} onOpenChange={() => onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            {employee?.current_salary !== null
              ? `Modifier le salaire — ${employee?.full_name}`
              : `Définir le salaire — ${employee?.full_name}`}
          </DialogTitle>
        </DialogHeader>
        <div className="space-y-4 py-4">
          {employee?.current_salary !== null && (
            <p className="text-sm text-muted-foreground">
              Salaire actuel : {employee?.current_salary?.toLocaleString('fr-CA')} $/an
              (depuis {employee?.effective_from})
            </p>
          )}
          <div className="space-y-2">
            <Label htmlFor="salary">Salaire annuel ($/an)</Label>
            <Input
              id="salary"
              type="number"
              step="0.01"
              min="0.01"
              value={salary}
              onChange={(e) => setSalary(e.target.value)}
              placeholder="ex: 52000.00"
            />
            {biweeklyAmount && (
              <p className="text-xs text-muted-foreground">
                Équivalent aux 2 semaines : {parseFloat(biweeklyAmount).toLocaleString('fr-CA')} $
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
          {error && (
            <p className="text-sm text-destructive">{error}</p>
          )}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Annuler
          </Button>
          <Button onClick={handleSave} disabled={saving}>
            {saving ? 'Enregistrement...' : 'Enregistrer'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

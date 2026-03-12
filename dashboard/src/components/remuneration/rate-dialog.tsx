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
import { upsertEmployeeRate } from '@/lib/api/remuneration';
import type { EmployeeRateListItem } from '@/types/remuneration';

interface RateDialogProps {
  employee: EmployeeRateListItem | null;
  onClose: () => void;
  onSaved: () => void;
}

export function RateDialog({ employee, onClose, onSaved }: RateDialogProps) {
  const [rate, setRate] = useState('');
  const [effectiveFrom, setEffectiveFrom] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (employee) {
      setRate(employee.current_rate?.toString() ?? '');
      setEffectiveFrom(new Date().toISOString().split('T')[0]);
      setError(null);
    }
  }, [employee]);

  const handleSave = async () => {
    setError(null);
    const parsedRate = parseFloat(rate);
    if (isNaN(parsedRate) || parsedRate <= 0) {
      setError('Le taux doit être supérieur à 0');
      return;
    }
    if (!effectiveFrom) {
      setError('La date est requise');
      return;
    }

    setSaving(true);
    try {
      await upsertEmployeeRate(employee!.employee_id, parsedRate, effectiveFrom);
      onSaved();
    } catch (e: any) {
      setError(e.message || 'Erreur lors de la sauvegarde');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={employee !== null} onOpenChange={() => onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            {employee?.current_rate !== null
              ? `Modifier le taux — ${employee?.full_name}`
              : `Définir le taux — ${employee?.full_name}`}
          </DialogTitle>
        </DialogHeader>
        <div className="space-y-4 py-4">
          {employee?.current_rate !== null && (
            <p className="text-sm text-muted-foreground">
              Taux actuel : {employee?.current_rate?.toFixed(2)} $/h
              (depuis {employee?.effective_from})
            </p>
          )}
          <div className="space-y-2">
            <Label htmlFor="rate">Nouveau taux horaire ($/h)</Label>
            <Input
              id="rate"
              type="number"
              step="0.01"
              min="0.01"
              value={rate}
              onChange={(e) => setRate(e.target.value)}
              placeholder="ex: 20.00"
            />
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

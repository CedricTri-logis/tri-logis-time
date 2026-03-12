'use client';

import { useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog';
import { Pencil } from 'lucide-react';
import { updateWeekendPremium } from '@/lib/api/remuneration';
import type { WeekendCleaningPremium } from '@/types/remuneration';

interface PremiumSectionProps {
  premium: WeekendCleaningPremium | null;
  onUpdate: () => void;
}

export function PremiumSection({ premium, onUpdate }: PremiumSectionProps) {
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState('');
  const [saving, setSaving] = useState(false);

  const handleOpen = () => {
    setAmount(premium?.amount?.toString() ?? '0');
    setOpen(true);
  };

  const handleSave = async () => {
    const parsed = parseFloat(amount);
    if (isNaN(parsed) || parsed < 0) return;
    setSaving(true);
    try {
      await updateWeekendPremium(parsed);
      onUpdate();
      setOpen(false);
    } finally {
      setSaving(false);
    }
  };

  return (
    <>
      <Card>
        <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
          <CardTitle className="text-base font-medium">
            Prime fin de semaine — Ménage
          </CardTitle>
          <Button variant="ghost" size="sm" onClick={handleOpen}>
            <Pencil className="h-4 w-4 mr-1" /> Modifier
          </Button>
        </CardHeader>
        <CardContent>
          <div className="text-2xl font-bold">
            +{premium?.amount?.toFixed(2) ?? '0.00'} $/h
          </div>
          <p className="text-xs text-muted-foreground mt-1">
            S&apos;applique aux heures de sessions ménage le samedi et dimanche.
          </p>
        </CardContent>
      </Card>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Modifier la prime weekend</DialogTitle>
          </DialogHeader>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="premium-amount">Montant ($/h)</Label>
              <Input
                id="premium-amount"
                type="number"
                step="0.01"
                min="0"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)}>
              Annuler
            </Button>
            <Button onClick={handleSave} disabled={saving}>
              {saving ? 'Enregistrement...' : 'Enregistrer'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}

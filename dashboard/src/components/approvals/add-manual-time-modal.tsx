'use client';

import { useState } from 'react';
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { createClient } from '@/lib/supabase/client';
import { toast } from 'sonner';
import type { DayApprovalDetail } from '@/types/mileage';

interface AddManualTimeModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  employeeId: string;
  date: string; // YYYY-MM-DD
  onUpdated: (newDetail: DayApprovalDetail) => void;
}

export function AddManualTimeModal({ open, onOpenChange, employeeId, date, onUpdated }: AddManualTimeModalProps) {
  const [startTime, setStartTime] = useState('');
  const [endTime, setEndTime] = useState('');
  const [reason, setReason] = useState('');
  const [locationId, setLocationId] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Compute duration
  const durationMinutes = (() => {
    if (!startTime || !endTime) return 0;
    const [sh, sm] = startTime.split(':').map(Number);
    const [eh, em] = endTime.split(':').map(Number);
    return (eh * 60 + em) - (sh * 60 + sm);
  })();

  const formatDur = (mins: number) => {
    if (mins <= 0) return '—';
    const h = Math.floor(mins / 60);
    const m = mins % 60;
    return h > 0 ? `${h}h${m.toString().padStart(2, '0')}` : `${m} min`;
  };

  const handleSubmit = async () => {
    if (!startTime || !endTime || !reason.trim()) return;
    setLoading(true);
    setError(null);

    const startsAt = new Date(`${date}T${startTime}:00`).toISOString();
    const endsAt = new Date(`${date}T${endTime}:00`).toISOString();

    const supabase = createClient();
    const { data, error: rpcError } = await supabase.rpc('add_manual_time', {
      p_employee_id: employeeId,
      p_date: date,
      p_starts_at: startsAt,
      p_ends_at: endsAt,
      p_reason: reason.trim(),
      p_location_id: locationId,
    });

    if (rpcError) {
      setError(rpcError.message);
      setLoading(false);
      return;
    }

    toast.success('Temps manuel ajouté');
    setLoading(false);
    onOpenChange(false);
    setStartTime('');
    setEndTime('');
    setReason('');
    setLocationId(null);
    onUpdated(data as DayApprovalDetail);
  };

  const canSubmit = startTime && endTime && reason.trim() && durationMinutes > 0 && !loading;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            Ajouter du temps manuel
          </DialogTitle>
        </DialogHeader>

        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-xs font-semibold text-muted-foreground uppercase">Heure début</label>
              <input type="time" value={startTime} onChange={e => setStartTime(e.target.value)}
                className="w-full rounded-md border px-3 py-2 text-sm" />
            </div>
            <div>
              <label className="text-xs font-semibold text-muted-foreground uppercase">Heure fin</label>
              <input type="time" value={endTime} onChange={e => setEndTime(e.target.value)}
                className="w-full rounded-md border px-3 py-2 text-sm" />
            </div>
          </div>

          {durationMinutes > 0 && (
            <div className="bg-muted/50 rounded-lg px-3 py-2 flex items-center gap-2">
              <span className="text-xs text-muted-foreground">Durée:</span>
              <span className="text-sm font-bold">{formatDur(durationMinutes)}</span>
            </div>
          )}

          <div>
            <label className="text-xs font-semibold text-muted-foreground uppercase">
              Raison <span className="text-destructive">*</span>
            </label>
            <Textarea value={reason} onChange={e => setReason(e.target.value)}
              placeholder="Expliquez pourquoi ce temps est ajouté manuellement..."
              className="h-20 text-sm" />
          </div>

          {error && <div className="text-xs text-destructive">{error}</div>}

          <div className="flex gap-2 justify-end">
            <Button variant="outline" onClick={() => onOpenChange(false)} disabled={loading}>Annuler</Button>
            <Button onClick={handleSubmit} disabled={!canSubmit}
              className="bg-amber-800 hover:bg-amber-900">
              {loading ? 'Ajout...' : 'Ajouter le temps'}
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}

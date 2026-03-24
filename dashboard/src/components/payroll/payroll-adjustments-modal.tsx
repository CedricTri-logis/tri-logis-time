'use client';

import { useEffect, useState, useMemo } from 'react';
import { format, parseISO } from 'date-fns';
import { fr } from 'date-fns/locale';
import { createClient } from '@/lib/supabase/client';
import { toast } from 'sonner';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
  DialogDescription,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Loader2 } from 'lucide-react';
import type { PayrollEmployeeSummary, PayPeriod } from '@/types/payroll';
import { formatMinutesAsHours } from '@/lib/utils/pay-periods';

// ─── Types ──────────────────────────────────────────────────────────────────

interface PayrollAdjustmentsModalProps {
  open: boolean;
  onClose: () => void;
  employee: PayrollEmployeeSummary;
  period: PayPeriod;
  onSuccess: () => void;
}

interface BankBalance {
  balance_dollars: number;
  balance_hours: number;
}

interface SickLeaveBalance {
  used_hours: number;
  remaining_hours: number;
  max_hours: number;
}

type BankOperation = 'deposit' | 'withdrawal';

// ─── Helpers ────────────────────────────────────────────────────────────────

/** Format money as "1 234.56 $" (Quebec French) */
function fmtMoney(n: number): string {
  const formatted = Math.abs(n)
    .toFixed(2)
    .replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  return n < 0 ? `-${formatted} $` : `${formatted} $`;
}

/** Format hours as "Xh30" style */
function fmtHours(hours: number): string {
  const h = Math.floor(hours);
  const m = Math.round((hours - h) * 60);
  return m > 0 ? `${h}h${m.toString().padStart(2, '0')}` : `${h}h`;
}

/** Format period range for display */
function fmtPeriodRange(period: PayPeriod): string {
  const start = parseISO(period.start);
  const end = parseISO(period.end);
  return `${format(start, 'd MMM', { locale: fr })} – ${format(end, 'd MMM yyyy', { locale: fr })}`;
}

// ─── Balance Bar Component ──────────────────────────────────────────────────

function BalanceBar({
  label,
  value,
  max,
  colorClass,
  valueLabel,
}: {
  label: string;
  value: number;
  max: number;
  colorClass: string;
  valueLabel: string;
}) {
  const pct = max > 0 ? Math.min((value / max) * 100, 100) : 0;
  return (
    <div className="space-y-1">
      <div className="flex justify-between text-xs text-muted-foreground">
        <span>{label}</span>
        <span>{valueLabel}</span>
      </div>
      <div className="h-2 rounded-full bg-muted overflow-hidden">
        <div
          className={`h-full rounded-full transition-all ${colorClass}`}
          style={{ width: `${pct}%` }}
        />
      </div>
    </div>
  );
}

// ─── Main Component ─────────────────────────────────────────────────────────

export function PayrollAdjustmentsModal({
  open,
  onClose,
  employee,
  period,
  onSuccess,
}: PayrollAdjustmentsModalProps) {
  // ── Balances (fetched on open) ──
  const [bankBalance, setBankBalance] = useState<BankBalance | null>(null);
  const [sickBalance, setSickBalance] = useState<SickLeaveBalance | null>(null);
  const [loadingBalances, setLoadingBalances] = useState(false);

  // ── Bank form ──
  const [bankOperation, setBankOperation] = useState<BankOperation>('deposit');
  const [bankHours, setBankHours] = useState<number>(0);
  const [bankReason, setBankReason] = useState('');

  // ── Sick leave form ──
  const [sickHours, setSickHours] = useState<number>(0);
  const [sickReason, setSickReason] = useState('');
  const [absenceDate, setAbsenceDate] = useState(period.start);

  // ── Submit state ──
  const [loading, setLoading] = useState(false);

  const isHourly = employee.pay_type === 'hourly';
  const hourlyRate = employee.hourly_rate ?? 0;

  // ── Reset state + fetch balances when modal opens ──
  useEffect(() => {
    if (!open) return;

    // Reset form
    setBankOperation('deposit');
    setBankHours(0);
    setBankReason('');
    setSickHours(0);
    setSickReason('');
    setAbsenceDate(period.start);
    setBankBalance(null);
    setSickBalance(null);

    const supabase = createClient();

    const fetchBalances = async () => {
      setLoadingBalances(true);
      try {
        if (isHourly) {
          const { data } = await supabase.rpc('get_hour_bank_balance', {
            p_employee_id: employee.employee_id,
          });
          if (data) {
            setBankBalance(data as unknown as BankBalance);
          }
        }
        const { data } = await supabase.rpc('get_sick_leave_balance', {
          p_employee_id: employee.employee_id,
        });
        if (data) {
          setSickBalance(data as unknown as SickLeaveBalance);
        }
      } catch {
        // Silently handle — balances will show as loading
      } finally {
        setLoadingBalances(false);
      }
    };

    fetchBalances();
  }, [open, employee.employee_id, isHourly, period.start]);

  // ── Computed values ──
  const bankAmount = bankHours * hourlyRate;

  const impactPreview = useMemo(() => {
    const approvedMin = employee.total_approved_minutes;
    const breakDeductionMin = employee.total_break_deduction_minutes;

    // Bank impact in minutes (deposit = reduce pay, withdrawal = add to pay)
    const bankImpactMin = bankHours > 0
      ? bankOperation === 'deposit'
        ? -(bankHours * 60)
        : bankHours * 60
      : 0;

    const sickImpactMin = sickHours > 0 ? sickHours * 60 : 0;

    const totalPayableMin = approvedMin + bankImpactMin + sickImpactMin - breakDeductionMin;
    const totalPayableHours = totalPayableMin / 60;
    const estimatedPay = totalPayableHours * hourlyRate;

    return {
      approvedMin,
      breakDeductionMin,
      bankImpactMin,
      sickImpactMin,
      totalPayableMin,
      estimatedPay,
    };
  }, [
    employee.total_approved_minutes,
    employee.total_break_deduction_minutes,
    bankHours,
    bankOperation,
    sickHours,
    hourlyRate,
  ]);

  // ── Validation ──
  const hasBankEntry = bankHours > 0 && bankReason.trim().length > 0;
  const hasSickEntry = sickHours > 0 && sickReason.trim().length > 0 && absenceDate;
  const hasAnyEntry = hasBankEntry || hasSickEntry;
  const bankReasonMissing = bankHours > 0 && bankReason.trim().length === 0;
  const sickReasonMissing = sickHours > 0 && sickReason.trim().length === 0;

  // ── Submit ──
  const handleSubmit = async () => {
    setLoading(true);
    try {
      const supabase = createClient();

      if (hasBankEntry) {
        const { error } = await supabase.rpc('add_hour_bank_transaction', {
          p_employee_id: employee.employee_id,
          p_period_start: period.start,
          p_period_end: period.end,
          p_type: bankOperation,
          p_hours: bankHours,
          p_reason: bankReason,
        });
        if (error) throw error;
      }

      if (hasSickEntry) {
        const { error } = await supabase.rpc('add_sick_leave_usage', {
          p_employee_id: employee.employee_id,
          p_period_start: period.start,
          p_period_end: period.end,
          p_hours: sickHours,
          p_absence_date: absenceDate,
          p_reason: sickReason,
        });
        if (error) throw error;
      }

      toast.success('Ajustements appliques avec succes');
      onSuccess();
      onClose();
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : 'Erreur inconnue';
      toast.error(message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={(isOpen) => { if (!isOpen) onClose(); }}>
      <DialogContent className="sm:max-w-lg max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Ajustements de paie</DialogTitle>
          <DialogDescription>
            {employee.full_name} — {fmtPeriodRange(period)} — {formatMinutesAsHours(employee.total_approved_minutes)} approuvees
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-6">
          {/* ── BANK SECTION (hourly only) ── */}
          {isHourly && (
            <div className="space-y-3 rounded-lg border border-blue-200 bg-blue-50/50 p-4">
              <h3 className="text-sm font-semibold text-blue-700">
                Banque d&apos;heures
              </h3>

              {/* Balance bar */}
              {loadingBalances ? (
                <div className="flex items-center gap-2 text-xs text-muted-foreground">
                  <Loader2 className="h-3 w-3 animate-spin" /> Chargement...
                </div>
              ) : bankBalance ? (
                <BalanceBar
                  label="Solde"
                  value={Math.max(bankBalance.balance_dollars, 0)}
                  max={Math.max(bankBalance.balance_dollars, 1)}
                  colorClass="bg-blue-500"
                  valueLabel={`${fmtMoney(bankBalance.balance_dollars)} (${fmtHours(bankBalance.balance_hours)})`}
                />
              ) : (
                <div className="text-xs text-muted-foreground">
                  Aucune donnee de banque
                </div>
              )}

              {/* Operation select */}
              <div className="space-y-1.5">
                <Label className="text-xs">Operation</Label>
                <Select
                  value={bankOperation}
                  onValueChange={(v) => setBankOperation(v as BankOperation)}
                >
                  <SelectTrigger className="w-full">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="deposit">
                      Deposer (&#8592; paie)
                    </SelectItem>
                    <SelectItem value="withdrawal">
                      Retirer (&#8594; paie)
                    </SelectItem>
                  </SelectContent>
                </Select>
              </div>

              {/* Hours input */}
              <div className="space-y-1.5">
                <Label className="text-xs">Heures</Label>
                <Input
                  type="number"
                  step={0.5}
                  min={0}
                  value={bankHours || ''}
                  onChange={(e) => setBankHours(parseFloat(e.target.value) || 0)}
                  placeholder="0"
                />
                {bankHours > 0 && hourlyRate > 0 && (
                  <p className="text-xs text-blue-600 font-mono">
                    {fmtHours(bankHours)} &times; {hourlyRate.toFixed(2)} $/h = {fmtMoney(bankAmount)}
                  </p>
                )}
              </div>

              {/* Reason */}
              <div className="space-y-1.5">
                <Label className="text-xs">
                  Raison {bankReasonMissing && <span className="text-destructive">*</span>}
                </Label>
                <Input
                  value={bankReason}
                  onChange={(e) => setBankReason(e.target.value)}
                  placeholder="Raison du depot/retrait"
                />
              </div>
            </div>
          )}

          {/* ── SICK LEAVE SECTION ── */}
          <div className="space-y-3 rounded-lg border border-green-200 bg-green-50/50 p-4">
            <h3 className="text-sm font-semibold text-green-700">
              Conge maladie
            </h3>

            {/* Balance bar */}
            {loadingBalances ? (
              <div className="flex items-center gap-2 text-xs text-muted-foreground">
                <Loader2 className="h-3 w-3 animate-spin" /> Chargement...
              </div>
            ) : sickBalance ? (
              <BalanceBar
                label={`Utilise cette annee: ${fmtHours(sickBalance.used_hours)} / ${fmtHours(sickBalance.max_hours)}`}
                value={sickBalance.remaining_hours}
                max={sickBalance.max_hours}
                colorClass="bg-green-500"
                valueLabel={`${fmtHours(sickBalance.remaining_hours)} restantes`}
              />
            ) : (
              <div className="text-xs text-muted-foreground">
                Aucune donnee de maladie
              </div>
            )}

            {/* Hours input */}
            <div className="space-y-1.5">
              <Label className="text-xs">Heures</Label>
              <Input
                type="number"
                step={0.5}
                min={0}
                max={sickBalance?.remaining_hours ?? 14}
                value={sickHours || ''}
                onChange={(e) => setSickHours(parseFloat(e.target.value) || 0)}
                placeholder="0"
              />
            </div>

            {/* Absence date */}
            <div className="space-y-1.5">
              <Label className="text-xs">Date d&apos;absence</Label>
              <Input
                type="date"
                min={period.start}
                max={period.end}
                value={absenceDate}
                onChange={(e) => setAbsenceDate(e.target.value)}
              />
            </div>

            {/* Reason */}
            <div className="space-y-1.5">
              <Label className="text-xs">
                Raison {sickReasonMissing && <span className="text-destructive">*</span>}
              </Label>
              <Input
                value={sickReason}
                onChange={(e) => setSickReason(e.target.value)}
                placeholder="Raison du conge maladie"
              />
            </div>
          </div>

          {/* ── IMPACT PREVIEW ── */}
          {isHourly && hasAnyEntry && (
            <div className="rounded-lg border border-amber-200 bg-amber-50/50 p-4 space-y-2">
              <h3 className="text-sm font-semibold text-amber-700">
                Apercu de l&apos;impact
              </h3>
              <div className="space-y-1 text-sm">
                <div className="flex justify-between">
                  <span>Heures approuvees</span>
                  <span className="font-mono">
                    {formatMinutesAsHours(impactPreview.approvedMin)}
                  </span>
                </div>
                {bankHours > 0 && (
                  <div className="flex justify-between">
                    <span>
                      Banque d&apos;heures ({bankOperation === 'deposit' ? 'depot' : 'retrait'})
                    </span>
                    <span className={`font-mono ${impactPreview.bankImpactMin >= 0 ? 'text-green-600' : 'text-destructive'}`}>
                      {impactPreview.bankImpactMin >= 0 ? '+' : ''}{formatMinutesAsHours(Math.abs(impactPreview.bankImpactMin))}
                    </span>
                  </div>
                )}
                {sickHours > 0 && (
                  <div className="flex justify-between">
                    <span>Heures maladie</span>
                    <span className="font-mono text-green-600">
                      +{formatMinutesAsHours(impactPreview.sickImpactMin)}
                    </span>
                  </div>
                )}
                {impactPreview.breakDeductionMin > 0 && (
                  <div className="flex justify-between">
                    <span>Deductions pause</span>
                    <span className="font-mono text-destructive">
                      -{formatMinutesAsHours(impactPreview.breakDeductionMin)}
                    </span>
                  </div>
                )}
                <div className="border-t border-amber-200 pt-1 flex justify-between font-semibold">
                  <span>Total heures payees</span>
                  <span className="font-mono">
                    {formatMinutesAsHours(Math.max(0, impactPreview.totalPayableMin))}
                  </span>
                </div>
                <div className="flex justify-between font-semibold text-amber-700">
                  <span>Total paie estimee</span>
                  <span className="font-mono">
                    {fmtMoney(Math.max(0, impactPreview.estimatedPay))}
                  </span>
                </div>
              </div>
            </div>
          )}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={loading}>
            Annuler
          </Button>
          <Button
            onClick={handleSubmit}
            disabled={loading || !hasAnyEntry}
          >
            {loading && <Loader2 className="h-4 w-4 animate-spin mr-2" />}
            Appliquer les ajustements
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

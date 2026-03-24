'use client';

import { useState } from 'react';
import { Button } from '@/components/ui/button';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog';
import { Lock, Unlock, CheckCircle } from 'lucide-react';
import { toast } from 'sonner';
import { approvePayroll, unlockPayroll } from '@/lib/api/payroll';
import { formatPeriodLabel } from '@/lib/utils/pay-periods';
import type { PayrollEmployeeSummary, PayPeriod } from '@/types/payroll';

interface PayrollApprovalButtonProps {
  employee: PayrollEmployeeSummary;
  period: PayPeriod;
  onRefetch: () => void;
}

export function PayrollApprovalButton({ employee, period, onRefetch }: PayrollApprovalButtonProps) {
  const [saving, setSaving] = useState(false);

  const unapprovedDays = employee.days_worked - employee.days_approved;
  const isApproved = employee.payroll_status === 'approved';
  const canApprove = unapprovedDays === 0 && employee.days_worked > 0;

  const handleApprove = async () => {
    setSaving(true);
    try {
      await approvePayroll(employee.employee_id, period.start, period.end);
      toast.success(`Paie approuvée pour ${employee.full_name}`);
      onRefetch();
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : 'Erreur inconnue');
    } finally {
      setSaving(false);
    }
  };

  const handleUnlock = async () => {
    setSaving(true);
    try {
      await unlockPayroll(employee.employee_id, period.start, period.end);
      toast.success(`Paie déverrouillée pour ${employee.full_name}`);
      onRefetch();
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : 'Erreur inconnue');
    } finally {
      setSaving(false);
    }
  };

  if (isApproved) {
    return (
      <div className="flex items-center gap-3">
        <div className="flex items-center gap-2 text-green-700 bg-green-50 px-3 py-2 rounded-md">
          <CheckCircle className="h-4 w-4" />
          <span className="text-sm">
            Paie approuvée le {employee.payroll_approved_at
              ? new Date(employee.payroll_approved_at).toLocaleDateString('fr-CA')
              : ''}
            {employee.payroll_approved_by && ` par ${employee.payroll_approved_by}`}
          </span>
        </div>
        <AlertDialog>
          <AlertDialogTrigger asChild>
            <Button variant="outline" size="sm" disabled={saving}>
              <Unlock className="h-4 w-4 mr-1" />
              Déverrouiller
            </Button>
          </AlertDialogTrigger>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Déverrouiller la paie</AlertDialogTitle>
              <AlertDialogDescription>
                Déverrouiller la paie de {employee.full_name} pour la période du {formatPeriodLabel(period)} ?
                Les approbations journalières pourront être modifiées.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Annuler</AlertDialogCancel>
              <AlertDialogAction onClick={handleUnlock}>Déverrouiller</AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </div>
    );
  }

  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button disabled={!canApprove || saving}>
          <Lock className="h-4 w-4 mr-1" />
          Approuver la paie de {employee.full_name}
          {!canApprove && unapprovedDays > 0 && (
            <span className="ml-2 text-xs opacity-70">
              ({unapprovedDays} jour{unapprovedDays > 1 ? 's' : ''} non approuvé{unapprovedDays > 1 ? 's' : ''})
            </span>
          )}
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>Approuver la paie</AlertDialogTitle>
          <AlertDialogDescription>
            Approuver la paie de {employee.full_name} pour la période du {formatPeriodLabel(period)} ?
            Les approbations journalières seront verrouillées.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Annuler</AlertDialogCancel>
          <AlertDialogAction onClick={handleApprove}>Approuver</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

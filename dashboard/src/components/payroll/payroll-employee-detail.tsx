'use client';

import { useState } from 'react';
import { parseISO, format } from 'date-fns';
import { fr } from 'date-fns/locale';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { AlertTriangle, Coffee, Undo2 } from 'lucide-react';
import { toast } from 'sonner';
import { toggleBreakDeductionWaiver } from '@/lib/api/payroll';
import { DayApprovalDetail } from '@/components/approvals/day-approval-detail';
import type { PayrollEmployeeSummary, PayPeriod, PayrollReportRow } from '@/types/payroll';
import { formatMinutesAsHours } from '@/lib/utils/pay-periods';
import { PayrollApprovalButton } from './payroll-approval-button';

interface PayrollEmployeeDetailProps {
  employee: PayrollEmployeeSummary;
  period: PayPeriod;
  onRefetch: () => void;
}

interface WeekSubtotalProps {
  days: PayrollReportRow[];
  weekLabel: string;
  periodSalaryHalf?: number; // For annual employees: period_salary / 2
}

function WeekSubtotal({ days, weekLabel, periodSalaryHalf }: WeekSubtotalProps) {
  const totalMin = days.reduce((s, d) => s + d.approved_minutes, 0);
  const totalBreak = days.reduce((s, d) => s + d.break_minutes, 0);
  const totalCallbackBonus = days.reduce((s, d) => s + d.callback_bonus_minutes, 0);
  const isAnnual = days[0]?.pay_type === 'annual';
  const weekPremium = days.reduce((s, d) => s + d.premium_amount, 0);
  // Annual: fixed salary/2 + premiums. Hourly: sum of daily amounts.
  const weekAmount = isAnnual
    ? (periodSalaryHalf ?? 0) + weekPremium
    : days.reduce((s, d) => s + d.total_amount, 0);

  return (
    <TableRow className="bg-muted/40 font-semibold text-sm border-b-2 border-border">
      <TableCell>{weekLabel}</TableCell>
      <TableCell className="text-right font-mono">{formatMinutesAsHours(totalMin)}</TableCell>
      <TableCell className="text-right font-mono">{formatMinutesAsHours(totalBreak)}</TableCell>
      <TableCell className="text-right font-mono text-destructive">
        {(() => {
          const totalDed = days.reduce((s, d) => s + d.break_deduction_minutes, 0);
          return totalDed > 0 ? `-${totalDed}min` : '';
        })()}
      </TableCell>
      <TableCell className="text-right font-mono">
        {totalCallbackBonus > 0 ? `+${formatMinutesAsHours(totalCallbackBonus)}` : ''}
      </TableCell>
      <TableCell />
      <TableCell className="text-right font-mono">{weekAmount.toFixed(2)} $</TableCell>
      <TableCell>
        {isAnnual && totalMin < 40 * 60 && (
          <Badge variant="outline" className="text-amber-600">
            <AlertTriangle className="h-3 w-3 mr-1" />
            {'<'} 40h
          </Badge>
        )}
      </TableCell>
    </TableRow>
  );
}

export function PayrollEmployeeDetail({ employee, period, onRefetch }: PayrollEmployeeDetailProps) {
  const [selectedDate, setSelectedDate] = useState<string | null>(null);
  const fmtMoney = (n: number | null) => n != null ? `${n.toFixed(2)} $` : '—';
  const midpoint = parseISO(period.start);
  // Split into 2 weeks: days 0-6 = week 1, days 7-13 = week 2
  const week1 = employee.days.filter(d => {
    const dayDate = parseISO(d.date);
    return dayDate < new Date(midpoint.getTime() + 7 * 86400000);
  });
  const week2 = employee.days.filter(d => {
    const dayDate = parseISO(d.date);
    return dayDate >= new Date(midpoint.getTime() + 7 * 86400000);
  });
  // For annual employees: split period salary evenly across 2 weeks
  const periodSalaryHalf = employee.pay_type === 'annual' && employee.days[0]?.period_salary
    ? Math.round((employee.days[0].period_salary / 2) * 100) / 100
    : undefined;

  const handleToggleWaiver = async (day: PayrollReportRow) => {
    try {
      const newValue = await toggleBreakDeductionWaiver(employee.employee_id, day.date);
      toast.success(newValue ? 'Déduction annulée' : 'Déduction appliquée');
      onRefetch();
    } catch {
      toast.error('Erreur lors de la modification');
    }
  };

  const renderDay = (day: PayrollReportRow) => {
    const dateLabel = format(parseISO(day.date), 'EEE d MMM', { locale: fr });
    const noBreak = day.approved_minutes >= 300 && day.break_minutes === 0;

    return (
      <TableRow key={day.date} className="text-sm">
        <TableCell>
          <button
            onClick={() => setSelectedDate(day.date)}
            className="text-left hover:underline cursor-pointer text-primary"
          >
            {dateLabel}
          </button>
        </TableCell>
        <TableCell className="text-right font-mono">
          {formatMinutesAsHours(day.approved_minutes)}
        </TableCell>
        <TableCell className="text-right font-mono">
          {noBreak ? (
            <span className="text-destructive font-medium">
              <AlertTriangle className="h-3 w-3 inline mr-1" />0min
            </span>
          ) : (
            `${day.break_minutes}min`
          )}
        </TableCell>
        <TableCell className="text-right font-mono">
          {day.break_deduction_minutes > 0 ? (
            <span className="flex items-center justify-end gap-1">
              <span className="text-destructive">-{day.break_deduction_minutes}min</span>
              <button
                onClick={(e) => { e.stopPropagation(); handleToggleWaiver(day); }}
                className="text-muted-foreground hover:text-primary"
                title="Annuler la déduction"
              >
                <Undo2 className="h-3 w-3" />
              </button>
            </span>
          ) : day.break_deduction_waived && day.approved_minutes >= 300 && day.break_minutes < 30 ? (
            <span className="flex items-center justify-end gap-1">
              <span className="text-muted-foreground line-through">-{30 - day.break_minutes}min</span>
              <button
                onClick={(e) => { e.stopPropagation(); handleToggleWaiver(day); }}
                className="text-muted-foreground hover:text-primary"
                title="Réappliquer la déduction"
              >
                <Coffee className="h-3 w-3" />
              </button>
            </span>
          ) : (
            '—'
          )}
        </TableCell>
        <TableCell className="text-right font-mono">
          {day.callback_bonus_minutes > 0
            ? `+${formatMinutesAsHours(day.callback_bonus_minutes)}`
            : '—'}
        </TableCell>
        <TableCell>
          <div className="flex flex-wrap gap-1">
            {day.cleaning_minutes > 0 && (
              <Badge className="bg-green-600 text-xs">Ménage {formatMinutesAsHours(day.cleaning_minutes)}</Badge>
            )}
            {day.maintenance_minutes > 0 && (
              <Badge className="bg-orange-500 text-xs">Entretien {formatMinutesAsHours(day.maintenance_minutes)}</Badge>
            )}
            {day.admin_minutes > 0 && (
              <Badge className="bg-blue-500 text-xs">Admin {formatMinutesAsHours(day.admin_minutes)}</Badge>
            )}
            {day.uncovered_minutes > 0 && (
              <Badge variant="outline" className="text-xs text-muted-foreground">
                Non couvert {formatMinutesAsHours(day.uncovered_minutes)}
              </Badge>
            )}
          </div>
        </TableCell>
        <TableCell className="text-right font-mono">
          {day.premium_amount > 0 ? fmtMoney(day.premium_amount) : '—'}
        </TableCell>
        <TableCell className="text-right font-mono">
          {day.pay_type === 'annual' ? '—' : fmtMoney(day.total_amount)}
        </TableCell>
        <TableCell className="text-center">
          {day.day_approval_status === 'approved' ? (
            <Badge className="bg-green-600 text-xs">✓</Badge>
          ) : (
            <Badge variant="destructive" className="text-xs">En attente</Badge>
          )}
        </TableCell>
      </TableRow>
    );
  };

  return (
    <div className="border-t bg-muted/10 p-4">
      <Table>
        <TableHeader>
          <TableRow className="text-xs">
            <TableHead>Jour</TableHead>
            <TableHead className="text-right">Heures</TableHead>
            <TableHead className="text-right">Pause</TableHead>
            <TableHead className="text-right">Déd. pause</TableHead>
            <TableHead className="text-right">Rappel bonus</TableHead>
            <TableHead>Work Sessions</TableHead>
            <TableHead className="text-right">Prime FDS</TableHead>
            <TableHead className="text-right">Montant</TableHead>
            <TableHead className="text-center">Statut</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {week1.map(renderDay)}
          {week1.length > 0 && <WeekSubtotal days={week1} weekLabel="Semaine 1" periodSalaryHalf={periodSalaryHalf} />}
          {week1.length > 0 && week2.length > 0 && (
            <TableRow><TableCell colSpan={9} className="h-4 p-0 border-0" /></TableRow>
          )}
          {week2.map(renderDay)}
          {week2.length > 0 && <WeekSubtotal days={week2} weekLabel="Semaine 2" periodSalaryHalf={periodSalaryHalf} />}
        </TableBody>
      </Table>

      <div className="mt-4 flex justify-end">
        <PayrollApprovalButton
          employee={employee}
          period={period}
          onRefetch={onRefetch}
        />
      </div>

      {selectedDate && (
        <DayApprovalDetail
          employeeId={employee.employee_id}
          employeeName={employee.full_name}
          date={selectedDate}
          onClose={(hasChanges) => {
            setSelectedDate(null);
            if (hasChanges) onRefetch();
          }}
        />
      )}
    </div>
  );
}

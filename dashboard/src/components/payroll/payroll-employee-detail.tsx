'use client';

import { parseISO, format } from 'date-fns';
import { fr } from 'date-fns/locale';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { AlertTriangle, ExternalLink } from 'lucide-react';
import type { PayrollEmployeeSummary, PayPeriod, PayrollReportRow } from '@/types/payroll';
import { formatMinutesAsHours } from '@/lib/utils/pay-periods';
import { PayrollApprovalButton } from './payroll-approval-button';

interface PayrollEmployeeDetailProps {
  employee: PayrollEmployeeSummary;
  period: PayPeriod;
  onRefetch: () => void;
}

function WeekSubtotal({ days, weekLabel }: { days: PayrollReportRow[]; weekLabel: string }) {
  const totalMin = days.reduce((s, d) => s + d.approved_minutes, 0);
  const totalBreak = days.reduce((s, d) => s + d.break_minutes, 0);
  const totalAmount = days.reduce((s, d) => s + d.total_amount, 0);
  const isAnnual = days[0]?.pay_type === 'annual';

  return (
    <TableRow className="bg-muted/20 font-medium text-sm">
      <TableCell colSpan={2}>{weekLabel}</TableCell>
      <TableCell className="text-right font-mono">{formatMinutesAsHours(totalMin)}</TableCell>
      <TableCell className="text-right font-mono">{formatMinutesAsHours(totalBreak)}</TableCell>
      <TableCell />
      <TableCell />
      <TableCell />
      <TableCell className="text-right font-mono">{totalAmount.toFixed(2)} $</TableCell>
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

  const renderDay = (day: PayrollReportRow) => {
    const dateLabel = format(parseISO(day.date), 'EEE d MMM', { locale: fr });
    const noBreak = day.approved_minutes >= 300 && day.break_minutes === 0;

    return (
      <TableRow key={day.date} className="text-sm">
        <TableCell>
          {/* NOTE: Approval page does not currently support query param deep-linking.
              This navigates to the approvals page — user must manually select the employee/date.
              Deep-linking can be added as a follow-up enhancement. */}
          <a
            href={`/dashboard/approvals`}
            className="flex items-center gap-1 hover:underline"
          >
            {dateLabel}
            <ExternalLink className="h-3 w-3 text-muted-foreground" />
          </a>
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
        <TableCell className="text-right font-mono">{fmtMoney(day.total_amount)}</TableCell>
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
            <TableHead className="text-right">Rappel bonus</TableHead>
            <TableHead>Work Sessions</TableHead>
            <TableHead className="text-right">Prime FDS</TableHead>
            <TableHead className="text-right">Montant</TableHead>
            <TableHead className="text-center">Statut</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {week1.map(renderDay)}
          {week1.length > 0 && <WeekSubtotal days={week1} weekLabel="Semaine 1" />}
          {week2.map(renderDay)}
          {week2.length > 0 && <WeekSubtotal days={week2} weekLabel="Semaine 2" />}
        </TableBody>
      </Table>

      <div className="mt-4 flex justify-end">
        <PayrollApprovalButton
          employee={employee}
          period={period}
          onRefetch={onRefetch}
        />
      </div>
    </div>
  );
}

'use client';

import { Fragment, useState } from 'react';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { ChevronDown, ChevronRight, AlertTriangle } from 'lucide-react';
import type { PayrollCategoryGroup, PayrollEmployeeSummary, PayPeriod } from '@/types/payroll';
import { formatMinutesAsHours } from '@/lib/utils/pay-periods';
import { PayrollEmployeeDetail } from './payroll-employee-detail';

const CATEGORY_LABELS: Record<string, string> = {
  menage: 'Ménage',
  maintenance: 'Maintenance',
  renovation: 'Rénovation',
  admin: 'Administration',
  'Non catégorisé': 'Non catégorisé',
};

interface PayrollSummaryTableProps {
  categoryGroups: PayrollCategoryGroup[];
  grandTotal: {
    approved_minutes: number;
    base_amount: number;
    premium_amount: number;
    total_amount: number;
    rejected_minutes: number;
    callback_bonus_minutes: number;
  };
  period: PayPeriod;
  onRefetch: () => void;
}

export function PayrollSummaryTable({
  categoryGroups,
  grandTotal,
  period,
  onRefetch,
}: PayrollSummaryTableProps) {
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [collapsedCategories, setCollapsedCategories] = useState<Set<string>>(new Set());

  const toggleExpand = (employeeId: string) => {
    setExpandedId(prev => prev === employeeId ? null : employeeId);
  };

  const toggleCategory = (category: string) => {
    setCollapsedCategories(prev => {
      const next = new Set(prev);
      if (next.has(category)) next.delete(category);
      else next.add(category);
      return next;
    });
  };

  const fmtMoney = (n: number) => `${n.toFixed(2)} $`;

  return (
    <Table>
      <TableHeader>
        {/* Row 1 — Group labels */}
        <TableRow className="border-b-0">
          <TableHead className="w-8" />
          <TableHead colSpan={2} className="text-xs text-green-600 tracking-wider font-normal">EMPLOYÉ</TableHead>
          <TableHead colSpan={6} className="text-xs text-blue-600 tracking-wider text-center font-normal border-l-2">TEMPS</TableHead>
          <TableHead className="text-xs text-muted-foreground tracking-wider text-center font-normal border-l-2">QUAL.</TableHead>
          <TableHead colSpan={4} className="text-xs text-amber-600 tracking-wider text-center font-normal border-l-2">CALCUL PAIE</TableHead>
          <TableHead colSpan={2} className="text-xs text-muted-foreground tracking-wider text-center font-normal border-l-2">STATUT</TableHead>
        </TableRow>
        {/* Row 2 — Column labels */}
        <TableRow>
          <TableHead className="w-8" />
          <TableHead>Employé</TableHead>
          <TableHead>Type</TableHead>
          <TableHead className="text-right border-l-2">Heures</TableHead>
          <TableHead className="text-right text-destructive">Refusées</TableHead>
          <TableHead className="text-right">Rappel</TableHead>
          <TableHead className="text-right">Pause</TableHead>
          <TableHead className="text-center">Sans pause</TableHead>
          <TableHead className="text-right text-destructive">Déd. pause</TableHead>
          <TableHead className="text-right border-l-2">% Sess.</TableHead>
          <TableHead className="text-right border-l-2 text-amber-600">Taux/h</TableHead>
          <TableHead className="text-right">Prime FDS</TableHead>
          <TableHead className="text-right">Rappel $</TableHead>
          <TableHead className="text-right text-amber-600 font-semibold">Total</TableHead>
          <TableHead className="text-center border-l-2">Jours</TableHead>
          <TableHead className="text-center">Paie</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {categoryGroups.map((group, groupIdx) => {
          const isCollapsed = collapsedCategories.has(group.category);
          return (
          <Fragment key={`group-${group.category}`}>
            {/* Spacing between categories */}
            {groupIdx > 0 && (
              <TableRow className="border-0">
                <TableCell colSpan={17} className="py-2 border-0" />
              </TableRow>
            )}

            {/* Category header — clickable, shows totals when collapsed */}
            <TableRow
              className="bg-muted/50 cursor-pointer hover:bg-muted/70"
              onClick={() => toggleCategory(group.category)}
            >
              <TableCell className="w-8">
                {isCollapsed
                  ? <ChevronRight className="h-4 w-4" />
                  : <ChevronDown className="h-4 w-4" />}
              </TableCell>
              {isCollapsed ? (
                <>
                  <TableCell colSpan={2} className="font-semibold">
                    {CATEGORY_LABELS[group.category] || group.category}
                    <span className="text-xs text-muted-foreground font-normal ml-2">
                      ({group.employees.length} employés)
                    </span>
                  </TableCell>
                  {/* Heures */}
                  <TableCell className="text-right font-mono font-semibold border-l-2">
                    {formatMinutesAsHours(group.totals.approved_minutes)}
                  </TableCell>
                  {/* Refusées */}
                  <TableCell className="text-right font-mono text-destructive">
                    {group.totals.rejected_minutes > 0
                      ? formatMinutesAsHours(group.totals.rejected_minutes)
                      : ''}
                  </TableCell>
                  {/* Rappel */}
                  <TableCell className="text-right font-mono">
                    {group.totals.callback_bonus_minutes > 0
                      ? `+${formatMinutesAsHours(group.totals.callback_bonus_minutes)}`
                      : ''}
                  </TableCell>
                  {/* Pause / Sans pause / Déd. pause */}
                  <TableCell colSpan={3} />
                  {/* % Sessions */}
                  <TableCell className="border-l-2" />
                  {/* Taux/h */}
                  <TableCell className="border-l-2" />
                  {/* Prime FDS */}
                  <TableCell className="text-right font-mono font-semibold">
                    {group.totals.premium_amount > 0 ? fmtMoney(group.totals.premium_amount) : ''}
                  </TableCell>
                  {/* Rappel $ */}
                  <TableCell />
                  {/* Total */}
                  <TableCell className="text-right font-mono font-semibold text-amber-600">
                    {fmtMoney(group.totals.total_amount)}
                  </TableCell>
                  {/* Jours / Paie */}
                  <TableCell colSpan={2} className="border-l-2" />
                </>
              ) : (
                <TableCell colSpan={16} className="font-semibold">
                  {CATEGORY_LABELS[group.category] || group.category}
                </TableCell>
              )}
            </TableRow>

            {/* Employee rows — hidden when collapsed */}
            {!isCollapsed && group.employees.map((emp: PayrollEmployeeSummary) => (
              <Fragment key={emp.employee_id}>
                <TableRow
                  className={`cursor-pointer hover:bg-muted/30 ${
                    emp.payroll_status === 'approved' ? 'bg-green-50' : ''
                  }`}
                  onClick={() => toggleExpand(emp.employee_id)}
                >
                  {/* Chevron */}
                  <TableCell>
                    {expandedId === emp.employee_id
                      ? <ChevronDown className="h-4 w-4" />
                      : <ChevronRight className="h-4 w-4" />}
                  </TableCell>
                  {/* Employé */}
                  <TableCell>
                    <div className="font-medium">{emp.full_name}</div>
                    <div className="text-xs text-muted-foreground">{emp.employee_id_code}</div>
                    {emp.secondary_categories?.map(cat => (
                      <Badge key={cat} variant="outline" className="text-xs ml-1">+{cat}</Badge>
                    ))}
                  </TableCell>
                  {/* Type */}
                  <TableCell>
                    <Badge variant={emp.pay_type === 'annual' ? 'secondary' : 'default'}>
                      {emp.pay_type === 'annual' ? 'Annuel' : 'Horaire'}
                    </Badge>
                  </TableCell>
                  {/* Heures */}
                  <TableCell className="text-right font-mono border-l-2">
                    {formatMinutesAsHours(emp.total_approved_minutes)}
                    {emp.pay_type === 'annual' && emp.total_approved_minutes < 80 * 60 && (
                      <AlertTriangle className="h-3 w-3 inline ml-1 text-amber-500" />
                    )}
                  </TableCell>
                  {/* Refusées */}
                  <TableCell className="text-right font-mono text-destructive">
                    {emp.total_rejected_minutes > 0
                      ? formatMinutesAsHours(emp.total_rejected_minutes)
                      : '—'}
                  </TableCell>
                  {/* Rappel */}
                  <TableCell className="text-right font-mono">
                    {emp.total_callback_bonus_minutes > 0
                      ? `+${formatMinutesAsHours(emp.total_callback_bonus_minutes)}`
                      : '—'}
                  </TableCell>
                  {/* Pause */}
                  <TableCell className="text-right font-mono">
                    {formatMinutesAsHours(emp.total_break_minutes)}
                  </TableCell>
                  {/* Sans pause */}
                  <TableCell className="text-center">
                    {emp.days_without_break > 0 ? (
                      <Badge variant="destructive">{emp.days_without_break}</Badge>
                    ) : '—'}
                  </TableCell>
                  {/* Déd. pause */}
                  <TableCell className="text-right font-mono text-destructive">
                    {emp.total_break_deduction_minutes > 0
                      ? `-${formatMinutesAsHours(emp.total_break_deduction_minutes)}`
                      : '—'}
                  </TableCell>
                  {/* % Sessions */}
                  <TableCell className="text-right font-mono border-l-2">
                    {emp.work_session_coverage_pct}%
                  </TableCell>
                  {/* Taux/h */}
                  <TableCell className="text-right font-mono text-amber-600 border-l-2">
                    {emp.hourly_rate_display}
                  </TableCell>
                  {/* Prime FDS */}
                  <TableCell className="text-right font-mono">
                    {emp.total_premium > 0 ? fmtMoney(emp.total_premium) : '—'}
                  </TableCell>
                  {/* Rappel $ */}
                  <TableCell className="text-right font-mono">
                    {emp.total_callback_bonus_amount > 0 ? fmtMoney(emp.total_callback_bonus_amount) : '—'}
                  </TableCell>
                  {/* Total */}
                  <TableCell className="text-right font-mono font-semibold text-amber-600">
                    {fmtMoney(emp.total_amount)}
                    {emp.pay_type === 'annual' && emp.hourly_rate && (
                      <div className="text-xs text-muted-foreground font-normal">
                        80h × {emp.hourly_rate.toFixed(2)}
                      </div>
                    )}
                  </TableCell>
                  {/* Jours */}
                  <TableCell className="text-center border-l-2">
                    <Badge variant={emp.days_approved === emp.days_worked ? 'default' : 'secondary'}>
                      {emp.days_approved}/{emp.days_worked}
                    </Badge>
                  </TableCell>
                  {/* Paie */}
                  <TableCell className="text-center">
                    {emp.payroll_status === 'approved' ? (
                      <Badge className="bg-green-600">Approuvée</Badge>
                    ) : (
                      <Badge variant="outline">En attente</Badge>
                    )}
                  </TableCell>
                </TableRow>

                {/* Expanded detail */}
                {expandedId === emp.employee_id && (
                  <TableRow>
                    <TableCell colSpan={17} className="p-0">
                      <PayrollEmployeeDetail
                        employee={emp}
                        period={period}
                        onRefetch={onRefetch}
                      />
                    </TableCell>
                  </TableRow>
                )}
              </Fragment>
            ))}

            {/* Category sub-total — hidden when collapsed */}
            {!isCollapsed && (
              <TableRow className="bg-muted/30 font-semibold">
                <TableCell colSpan={3}>
                  Sous-total {CATEGORY_LABELS[group.category]}
                </TableCell>
                {/* Heures */}
                <TableCell className="text-right font-mono border-l-2">
                  {formatMinutesAsHours(group.totals.approved_minutes)}
                </TableCell>
                {/* Refusées */}
                <TableCell className="text-right font-mono text-destructive">
                  {group.totals.rejected_minutes > 0
                    ? formatMinutesAsHours(group.totals.rejected_minutes)
                    : '—'}
                </TableCell>
                {/* Rappel */}
                <TableCell className="text-right font-mono">
                  {group.totals.callback_bonus_minutes > 0
                    ? `+${formatMinutesAsHours(group.totals.callback_bonus_minutes)}`
                    : ''}
                </TableCell>
                {/* Pause / Sans pause / Déd. pause */}
                <TableCell colSpan={3} />
                {/* % Sessions */}
                <TableCell className="border-l-2" />
                {/* Taux/h */}
                <TableCell className="border-l-2" />
                {/* Prime FDS */}
                <TableCell className="text-right font-mono">{fmtMoney(group.totals.premium_amount)}</TableCell>
                {/* Rappel $ */}
                <TableCell />
                {/* Total */}
                <TableCell className="text-right font-mono text-amber-600">{fmtMoney(group.totals.total_amount)}</TableCell>
                {/* Jours / Paie */}
                <TableCell colSpan={2} className="border-l-2" />
              </TableRow>
            )}
          </Fragment>
          );
        })}

        {/* Spacing before grand total */}
        <TableRow className="border-0">
          <TableCell colSpan={17} className="py-2 border-0" />
        </TableRow>
        {/* Grand total */}
        <TableRow className="bg-muted font-bold">
          <TableCell colSpan={3}>Grand total</TableCell>
          {/* Heures */}
          <TableCell className="text-right font-mono border-l-2">
            {formatMinutesAsHours(grandTotal.approved_minutes)}
          </TableCell>
          {/* Refusées */}
          <TableCell className="text-right font-mono text-destructive">
            {grandTotal.rejected_minutes > 0
              ? formatMinutesAsHours(grandTotal.rejected_minutes)
              : '—'}
          </TableCell>
          {/* Rappel */}
          <TableCell className="text-right font-mono">
            {grandTotal.callback_bonus_minutes > 0
              ? `+${formatMinutesAsHours(grandTotal.callback_bonus_minutes)}`
              : ''}
          </TableCell>
          {/* Pause / Sans pause / Déd. pause */}
          <TableCell colSpan={3} />
          {/* % Sessions */}
          <TableCell className="border-l-2" />
          {/* Taux/h */}
          <TableCell className="border-l-2" />
          {/* Prime FDS */}
          <TableCell className="text-right font-mono">{fmtMoney(grandTotal.premium_amount)}</TableCell>
          {/* Rappel $ */}
          <TableCell />
          {/* Total */}
          <TableCell className="text-right font-mono text-amber-600">{fmtMoney(grandTotal.total_amount)}</TableCell>
          {/* Jours / Paie */}
          <TableCell colSpan={2} className="border-l-2" />
        </TableRow>
      </TableBody>
    </Table>
  );
}

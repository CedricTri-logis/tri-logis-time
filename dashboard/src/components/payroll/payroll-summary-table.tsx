'use client';

import { Fragment, useState } from 'react';
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { ChevronDown, ChevronRight, AlertTriangle } from 'lucide-react';
import type { PayrollCategoryGroup, PayrollEmployeeSummary, PayPeriod } from '@/types/payroll';
import { formatMinutesAsHours } from '@/lib/utils/pay-periods';
import { PayrollEmployeeDetail } from './payroll-employee-detail';
import { PayrollAdjustmentsModal } from './payroll-adjustments-modal';
import { HourBankHistoryDialog } from './hour-bank-history-dialog';

const CATEGORY_LABELS: Record<string, string> = {
  menage: 'M\u00e9nage',
  maintenance: 'Maintenance',
  renovation: 'R\u00e9novation',
  admin: 'Administration',
  'Non cat\u00e9goris\u00e9': 'Non cat\u00e9goris\u00e9',
};

/** Total column count: 15 original + 4 bank/sick + 1 ajustements + 1 header = 21 */
const TOTAL_COLS = 21;

interface PayrollSummaryTableProps {
  categoryGroups: PayrollCategoryGroup[];
  grandTotal: {
    approved_minutes: number;
    base_amount: number;
    premium_amount: number;
    total_amount: number;
    rejected_minutes: number;
    callback_bonus_minutes: number;
    bank_net_amount: number;
    sick_leave_amount: number;
  };
  period: PayPeriod;
  onRefetch: () => void;
}

/** Format decimal hours (e.g. 9.333) as "9h20" */
function formatDecimalHours(h: number): string {
  const hours = Math.floor(Math.abs(h));
  const mins = Math.round((Math.abs(h) - hours) * 60);
  return mins > 0 ? `${hours}h${mins.toString().padStart(2, '0')}` : `${hours}h`;
}

export function PayrollSummaryTable({
  categoryGroups,
  grandTotal,
  period,
  onRefetch,
}: PayrollSummaryTableProps) {
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [collapsedCategories, setCollapsedCategories] = useState<Set<string>>(new Set());
  const [adjustmentEmployee, setAdjustmentEmployee] = useState<PayrollEmployeeSummary | null>(null);
  const [historyEmployee, setHistoryEmployee] = useState<{id: string; name: string} | null>(null);

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
    <>
    <Table>
      <TableHeader>
        {/* Row 1 \u2014 Group labels */}
        <TableRow className="border-b-0">
          <TableHead className="w-8" />
          <TableHead colSpan={2} className="text-xs text-green-600 tracking-wider font-normal">EMPLOY\u00c9</TableHead>
          <TableHead colSpan={6} className="text-xs text-blue-600 tracking-wider text-center font-normal border-l-2">TEMPS</TableHead>
          <TableHead className="text-xs text-muted-foreground tracking-wider text-center font-normal border-l-2">QUAL.</TableHead>
          <TableHead colSpan={4} className="text-xs text-amber-600 tracking-wider text-center font-normal border-l-2">CALCUL PAIE</TableHead>
          <TableHead colSpan={2} className="text-xs text-blue-700 tracking-wider text-center font-normal border-l-2 bg-blue-50">BANQUE</TableHead>
          <TableHead colSpan={2} className="text-xs text-green-700 tracking-wider text-center font-normal border-l-2 bg-green-50">MALADIE</TableHead>
          <TableHead colSpan={2} className="text-xs text-muted-foreground tracking-wider text-center font-normal border-l-2">STATUT</TableHead>
          <TableHead className="text-xs text-muted-foreground tracking-wider text-center font-normal" />
        </TableRow>
        {/* Row 2 \u2014 Column labels */}
        <TableRow>
          <TableHead className="w-8" />
          <TableHead>Employ\u00e9</TableHead>
          <TableHead>Type</TableHead>
          <TableHead className="text-right border-l-2">Heures</TableHead>
          <TableHead className="text-right text-destructive">Refus\u00e9es</TableHead>
          <TableHead className="text-right">Rappel</TableHead>
          <TableHead className="text-right">Pause</TableHead>
          <TableHead className="text-right text-destructive">D\u00e9d. pause</TableHead>
          <TableHead className="text-right border-l-2">% Sess.</TableHead>
          <TableHead className="text-right border-l-2 text-amber-600">Taux/h</TableHead>
          <TableHead className="text-right">Prime FDS</TableHead>
          <TableHead className="text-right">Rappel $</TableHead>
          <TableHead className="text-right text-amber-600 font-semibold">Total</TableHead>
          <TableHead className="text-right border-l-2 text-blue-700 bg-blue-50">Banque +/-</TableHead>
          <TableHead className="text-right text-blue-700 bg-blue-50">Solde banque</TableHead>
          <TableHead className="text-right border-l-2 text-green-700 bg-green-50">Maladie</TableHead>
          <TableHead className="text-right text-green-700 bg-green-50">Solde mal.</TableHead>
          <TableHead className="text-center border-l-2">Jours</TableHead>
          <TableHead className="text-center">Paie</TableHead>
          <TableHead className="text-center">Ajust.</TableHead>
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
                <TableCell colSpan={TOTAL_COLS} className="py-2 border-0" />
              </TableRow>
            )}

            {/* Category header \u2014 clickable, shows totals when collapsed */}
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
                      ({group.employees.length} employ\u00e9s)
                    </span>
                  </TableCell>
                  {/* Heures */}
                  <TableCell className="text-right font-mono font-semibold border-l-2">
                    {formatMinutesAsHours(group.totals.approved_minutes)}
                  </TableCell>
                  {/* Refus\u00e9es */}
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
                  {/* Pause / D\u00e9d. pause */}
                  <TableCell colSpan={2} />
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
                  {/* Banque +/- */}
                  <TableCell className="text-right font-mono border-l-2 bg-blue-50">
                    {group.totals.bank_net_amount !== 0
                      ? (group.totals.bank_net_amount > 0
                        ? <span className="text-green-600">+{fmtMoney(group.totals.bank_net_amount)}</span>
                        : <span className="text-red-600">{fmtMoney(group.totals.bank_net_amount)}</span>)
                      : ''}
                  </TableCell>
                  {/* Solde banque \u2014 no subtotal for balance */}
                  <TableCell className="bg-blue-50" />
                  {/* Maladie */}
                  <TableCell className="text-right font-mono border-l-2 bg-green-50">
                    {group.totals.sick_leave_amount > 0
                      ? fmtMoney(group.totals.sick_leave_amount)
                      : ''}
                  </TableCell>
                  {/* Solde mal. \u2014 no subtotal for balance */}
                  <TableCell className="bg-green-50" />
                  {/* Jours / Paie */}
                  <TableCell colSpan={2} className="border-l-2" />
                  {/* Ajustements */}
                  <TableCell />
                </>
              ) : (
                <TableCell colSpan={TOTAL_COLS - 1} className="font-semibold">
                  {CATEGORY_LABELS[group.category] || group.category}
                </TableCell>
              )}
            </TableRow>

            {/* Employee rows \u2014 hidden when collapsed */}
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
                  {/* Employ\u00e9 */}
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
                  {/* Refus\u00e9es */}
                  <TableCell className="text-right font-mono text-destructive">
                    {emp.total_rejected_minutes > 0
                      ? formatMinutesAsHours(emp.total_rejected_minutes)
                      : '\u2014'}
                  </TableCell>
                  {/* Rappel */}
                  <TableCell className="text-right font-mono">
                    {emp.total_callback_bonus_minutes > 0
                      ? `+${formatMinutesAsHours(emp.total_callback_bonus_minutes)}`
                      : '\u2014'}
                  </TableCell>
                  {/* Pause */}
                  <TableCell className="text-right font-mono">
                    {formatMinutesAsHours(emp.total_break_minutes)}
                  </TableCell>
                  {/* D\u00e9d. pause */}
                  <TableCell className="text-right font-mono text-destructive">
                    {emp.total_break_deduction_minutes > 0
                      ? `-${formatMinutesAsHours(emp.total_break_deduction_minutes)}`
                      : '\u2014'}
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
                    {emp.total_premium > 0 ? fmtMoney(emp.total_premium) : '\u2014'}
                  </TableCell>
                  {/* Rappel $ */}
                  <TableCell className="text-right font-mono">
                    {emp.total_callback_bonus_amount > 0 ? fmtMoney(emp.total_callback_bonus_amount) : '\u2014'}
                  </TableCell>
                  {/* Total */}
                  <TableCell className="text-right font-mono font-semibold text-amber-600">
                    {fmtMoney(emp.total_amount)}
                    {emp.pay_type === 'annual' && emp.hourly_rate && (
                      <div className="text-xs text-muted-foreground font-normal">
                        80h \u00d7 {emp.hourly_rate.toFixed(2)}
                      </div>
                    )}
                  </TableCell>
                  {/* Banque +/- */}
                  <TableCell className="text-right font-mono border-l-2 bg-blue-50/50">
                    {emp.bank_net_amount !== 0
                      ? (emp.bank_net_amount > 0
                        ? <span className="text-green-600">+{fmtMoney(emp.bank_net_amount)}</span>
                        : <span className="text-red-600">{fmtMoney(emp.bank_net_amount)}</span>)
                      : '\u2014'}
                  </TableCell>
                  {/* Solde banque */}
                  <TableCell className="text-right bg-blue-50/50">
                    {emp.pay_type === 'hourly' && emp.bank_balance_dollars != null ? (
                      <Badge variant="outline" className="text-blue-700 border-blue-300 bg-blue-50 font-mono text-xs">
                        {fmtMoney(emp.bank_balance_dollars)} ({formatDecimalHours(emp.bank_balance_hours)})
                      </Badge>
                    ) : '\u2014'}
                  </TableCell>
                  {/* Maladie */}
                  <TableCell className="text-right font-mono border-l-2 bg-green-50/50">
                    {emp.sick_leave_hours > 0
                      ? `${formatDecimalHours(emp.sick_leave_hours)}`
                      : '\u2014'}
                  </TableCell>
                  {/* Solde mal. */}
                  <TableCell className="text-right bg-green-50/50">
                    {emp.sick_leave_remaining != null ? (
                      <Badge variant="outline" className="text-green-700 border-green-300 bg-green-50 font-mono text-xs">
                        {formatDecimalHours(emp.sick_leave_remaining)}/14h
                      </Badge>
                    ) : '\u2014'}
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
                      <Badge className="bg-green-600">Approuv\u00e9e</Badge>
                    ) : (
                      <Badge variant="outline">En attente</Badge>
                    )}
                  </TableCell>
                  {/* Ajustements */}
                  <TableCell className="text-center">
                    <Button
                      variant="outline"
                      size="sm"
                      className="text-xs h-7 px-2"
                      onClick={(e) => {
                        e.stopPropagation();
                        setAdjustmentEmployee(emp);
                      }}
                    >
                      Ajustements
                    </Button>
                  </TableCell>
                </TableRow>

                {/* Expanded detail */}
                {expandedId === emp.employee_id && (
                  <TableRow>
                    <TableCell colSpan={TOTAL_COLS} className="p-0">
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

            {/* Category sub-total \u2014 hidden when collapsed */}
            {!isCollapsed && (
              <TableRow className="bg-muted/30 font-semibold">
                <TableCell colSpan={3}>
                  Sous-total {CATEGORY_LABELS[group.category]}
                </TableCell>
                {/* Heures */}
                <TableCell className="text-right font-mono border-l-2">
                  {formatMinutesAsHours(group.totals.approved_minutes)}
                </TableCell>
                {/* Refus\u00e9es */}
                <TableCell className="text-right font-mono text-destructive">
                  {group.totals.rejected_minutes > 0
                    ? formatMinutesAsHours(group.totals.rejected_minutes)
                    : '\u2014'}
                </TableCell>
                {/* Rappel */}
                <TableCell className="text-right font-mono">
                  {group.totals.callback_bonus_minutes > 0
                    ? `+${formatMinutesAsHours(group.totals.callback_bonus_minutes)}`
                    : ''}
                </TableCell>
                {/* Pause / Sans pause / D\u00e9d. pause */}
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
                {/* Banque +/- */}
                <TableCell className="text-right font-mono border-l-2 bg-blue-50/30">
                  {group.totals.bank_net_amount !== 0
                    ? (group.totals.bank_net_amount > 0
                      ? <span className="text-green-600">+{fmtMoney(group.totals.bank_net_amount)}</span>
                      : <span className="text-red-600">{fmtMoney(group.totals.bank_net_amount)}</span>)
                    : ''}
                </TableCell>
                {/* Solde banque \u2014 no subtotal */}
                <TableCell className="bg-blue-50/30" />
                {/* Maladie */}
                <TableCell className="text-right font-mono border-l-2 bg-green-50/30">
                  {group.totals.sick_leave_amount > 0
                    ? fmtMoney(group.totals.sick_leave_amount)
                    : ''}
                </TableCell>
                {/* Solde mal. \u2014 no subtotal */}
                <TableCell className="bg-green-50/30" />
                {/* Jours / Paie */}
                <TableCell colSpan={2} className="border-l-2" />
                {/* Ajustements */}
                <TableCell />
              </TableRow>
            )}
          </Fragment>
          );
        })}

        {/* Spacing before grand total */}
        <TableRow className="border-0">
          <TableCell colSpan={TOTAL_COLS} className="py-2 border-0" />
        </TableRow>
        {/* Grand total */}
        <TableRow className="bg-muted font-bold">
          <TableCell colSpan={3}>Grand total</TableCell>
          {/* Heures */}
          <TableCell className="text-right font-mono border-l-2">
            {formatMinutesAsHours(grandTotal.approved_minutes)}
          </TableCell>
          {/* Refus\u00e9es */}
          <TableCell className="text-right font-mono text-destructive">
            {grandTotal.rejected_minutes > 0
              ? formatMinutesAsHours(grandTotal.rejected_minutes)
              : '\u2014'}
          </TableCell>
          {/* Rappel */}
          <TableCell className="text-right font-mono">
            {grandTotal.callback_bonus_minutes > 0
              ? `+${formatMinutesAsHours(grandTotal.callback_bonus_minutes)}`
              : ''}
          </TableCell>
          {/* Pause / Sans pause / D\u00e9d. pause */}
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
          {/* Banque +/- */}
          <TableCell className="text-right font-mono border-l-2 bg-blue-50/30">
            {grandTotal.bank_net_amount !== 0
              ? (grandTotal.bank_net_amount > 0
                ? <span className="text-green-600">+{fmtMoney(grandTotal.bank_net_amount)}</span>
                : <span className="text-red-600">{fmtMoney(grandTotal.bank_net_amount)}</span>)
              : ''}
          </TableCell>
          {/* Solde banque \u2014 no grand total */}
          <TableCell className="bg-blue-50/30" />
          {/* Maladie */}
          <TableCell className="text-right font-mono border-l-2 bg-green-50/30">
            {grandTotal.sick_leave_amount > 0
              ? fmtMoney(grandTotal.sick_leave_amount)
              : ''}
          </TableCell>
          {/* Solde mal. \u2014 no grand total */}
          <TableCell className="bg-green-50/30" />
          {/* Jours / Paie */}
          <TableCell colSpan={2} className="border-l-2" />
          {/* Ajustements */}
          <TableCell />
        </TableRow>
      </TableBody>
    </Table>

    {/* Adjustments modal */}
    {adjustmentEmployee && (
      <PayrollAdjustmentsModal
        open={!!adjustmentEmployee}
        onClose={() => setAdjustmentEmployee(null)}
        employee={adjustmentEmployee}
        period={period}
        onSuccess={onRefetch}
      />
    )}

    {/* Hour bank history dialog */}
    {historyEmployee && (
      <HourBankHistoryDialog
        open={!!historyEmployee}
        onClose={() => setHistoryEmployee(null)}
        employeeId={historyEmployee.id}
        employeeName={historyEmployee.name}
        onDelete={onRefetch}
      />
    )}
    </>
  );
}

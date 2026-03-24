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

  const toggleExpand = (employeeId: string) => {
    setExpandedId(prev => prev === employeeId ? null : employeeId);
  };

  const fmtMoney = (n: number) => `${n.toFixed(2)} $`;

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead className="w-8" />
          <TableHead>Employé</TableHead>
          <TableHead>Type</TableHead>
          <TableHead className="text-right">Heures</TableHead>
          <TableHead className="text-right">Rappel bonus</TableHead>
          <TableHead className="text-right">Pause</TableHead>
          <TableHead className="text-center">Sans pause</TableHead>
          <TableHead className="text-right">% Sessions</TableHead>
          <TableHead className="text-right">Prime FDS</TableHead>
          <TableHead className="text-right">Base</TableHead>
          <TableHead className="text-right">Total</TableHead>
          <TableHead className="text-center">Jours</TableHead>
          <TableHead className="text-center">Paie</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {categoryGroups.map((group) => (
          <Fragment key={`group-${group.category}`}>
            {/* Category header */}
            <TableRow className="bg-muted/50">
              <TableCell colSpan={13} className="font-semibold">
                {CATEGORY_LABELS[group.category] || group.category}
              </TableCell>
            </TableRow>

            {/* Employee rows */}
            {group.employees.map((emp) => (
              <Fragment key={emp.employee_id}>
                <TableRow
                  className={`cursor-pointer hover:bg-muted/30 ${
                    emp.payroll_status === 'approved' ? 'bg-green-50' : ''
                  }`}
                  onClick={() => toggleExpand(emp.employee_id)}
                >
                  <TableCell>
                    {expandedId === emp.employee_id
                      ? <ChevronDown className="h-4 w-4" />
                      : <ChevronRight className="h-4 w-4" />}
                  </TableCell>
                  <TableCell>
                    <div className="font-medium">{emp.full_name}</div>
                    <div className="text-xs text-muted-foreground">{emp.employee_id_code}</div>
                    {emp.secondary_categories?.map(cat => (
                      <Badge key={cat} variant="outline" className="text-xs ml-1">+{cat}</Badge>
                    ))}
                  </TableCell>
                  <TableCell>
                    <Badge variant={emp.pay_type === 'annual' ? 'secondary' : 'default'}>
                      {emp.pay_type === 'annual' ? 'Annuel' : 'Horaire'}
                    </Badge>
                  </TableCell>
                  <TableCell className="text-right font-mono">
                    {formatMinutesAsHours(emp.total_approved_minutes)}
                    {emp.pay_type === 'annual' && emp.total_approved_minutes < 80 * 60 && (
                      <AlertTriangle className="h-3 w-3 inline ml-1 text-amber-500" />
                    )}
                  </TableCell>
                  <TableCell className="text-right font-mono">
                    {emp.total_callback_bonus_minutes > 0
                      ? `+${formatMinutesAsHours(emp.total_callback_bonus_minutes)}`
                      : '—'}
                  </TableCell>
                  <TableCell className="text-right font-mono">
                    {formatMinutesAsHours(emp.total_break_minutes)}
                  </TableCell>
                  <TableCell className="text-center">
                    {emp.days_without_break > 0 ? (
                      <Badge variant="destructive">{emp.days_without_break}</Badge>
                    ) : '—'}
                  </TableCell>
                  <TableCell className="text-right font-mono">
                    {emp.work_session_coverage_pct}%
                  </TableCell>
                  <TableCell className="text-right font-mono">
                    {emp.total_premium > 0 ? fmtMoney(emp.total_premium) : '—'}
                  </TableCell>
                  <TableCell className="text-right font-mono">{fmtMoney(emp.total_base)}</TableCell>
                  <TableCell className="text-right font-mono font-semibold">{fmtMoney(emp.total_amount)}</TableCell>
                  <TableCell className="text-center">
                    <Badge variant={emp.days_approved === emp.days_worked ? 'default' : 'secondary'}>
                      {emp.days_approved}/{emp.days_worked}
                    </Badge>
                  </TableCell>
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
                    <TableCell colSpan={13} className="p-0">
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

            {/* Category sub-total */}
            <TableRow className="bg-muted/30 font-semibold">
              <TableCell colSpan={3}>
                Sous-total {CATEGORY_LABELS[group.category]}
              </TableCell>
              <TableCell className="text-right font-mono">
                {formatMinutesAsHours(group.totals.approved_minutes)}
              </TableCell>
              <TableCell colSpan={4} />
              <TableCell className="text-right font-mono">{fmtMoney(group.totals.premium_amount)}</TableCell>
              <TableCell className="text-right font-mono">{fmtMoney(group.totals.base_amount)}</TableCell>
              <TableCell className="text-right font-mono">{fmtMoney(group.totals.total_amount)}</TableCell>
              <TableCell colSpan={2} />
            </TableRow>
          </Fragment>
        ))}

        {/* Grand total */}
        <TableRow className="bg-muted font-bold">
          <TableCell colSpan={3}>Grand total</TableCell>
          <TableCell className="text-right font-mono">
            {formatMinutesAsHours(grandTotal.approved_minutes)}
          </TableCell>
          <TableCell colSpan={4} />
          <TableCell className="text-right font-mono">{fmtMoney(grandTotal.premium_amount)}</TableCell>
          <TableCell className="text-right font-mono">{fmtMoney(grandTotal.base_amount)}</TableCell>
          <TableCell className="text-right font-mono">{fmtMoney(grandTotal.total_amount)}</TableCell>
          <TableCell colSpan={2} />
        </TableRow>
      </TableBody>
    </Table>
  );
}

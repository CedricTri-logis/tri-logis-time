'use client';

import { useState } from 'react';
import { format } from 'date-fns';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Alert, AlertDescription } from '@/components/ui/alert';
import { Loader2 } from 'lucide-react';
import { PayrollPeriodSelector } from '@/components/payroll/payroll-period-selector';
import { PayrollSummaryTable } from '@/components/payroll/payroll-summary-table';
import { PayrollExportButton } from '@/components/payroll/payroll-export-button';
import { usePayrollReport } from '@/lib/hooks/use-payroll-report';
import { getLastCompletedPeriod } from '@/lib/utils/pay-periods';
import type { PayPeriod } from '@/types/payroll';

export default function PayrollPage() {
  const todayStr = format(new Date(), 'yyyy-MM-dd');
  const [period, setPeriod] = useState<PayPeriod>(() => getLastCompletedPeriod(todayStr));

  const { categoryGroups, grandTotal, isLoading, error, refetch } = usePayrollReport(period);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">Paie</h1>
        <div className="flex items-center gap-3">
          <PayrollExportButton
            categoryGroups={categoryGroups}
            period={period}
            disabled={isLoading}
          />
        </div>
      </div>

      <div className="flex items-center justify-center">
        <PayrollPeriodSelector
          period={period}
          onPeriodChange={setPeriod}
          todayStr={todayStr}
        />
      </div>

      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}

      <Card>
        <CardHeader>
          <CardTitle>Feuilles de temps</CardTitle>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <div className="flex items-center justify-center py-12">
              <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
            </div>
          ) : categoryGroups.length === 0 ? (
            <p className="text-center text-muted-foreground py-12">
              Aucune donnee pour cette periode.
            </p>
          ) : (
            <PayrollSummaryTable
              categoryGroups={categoryGroups}
              grandTotal={grandTotal}
              period={period}
              onRefetch={refetch}
            />
          )}
        </CardContent>
      </Card>
    </div>
  );
}

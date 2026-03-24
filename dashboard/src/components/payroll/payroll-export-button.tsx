'use client';

import { Button } from '@/components/ui/button';
import { Download } from 'lucide-react';
import { exportPayrollToExcel } from '@/lib/utils/export-payroll-excel';
import type { PayrollCategoryGroup, PayPeriod } from '@/types/payroll';

interface PayrollExportButtonProps {
  categoryGroups: PayrollCategoryGroup[];
  period: PayPeriod;
  disabled?: boolean;
}

export function PayrollExportButton({ categoryGroups, period, disabled }: PayrollExportButtonProps) {
  return (
    <Button
      variant="outline"
      onClick={() => exportPayrollToExcel(categoryGroups, period)}
      disabled={disabled || categoryGroups.length === 0}
    >
      <Download className="h-4 w-4 mr-2" />
      Exporter Excel
    </Button>
  );
}

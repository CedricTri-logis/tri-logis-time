'use client';

import { ChevronLeft, ChevronRight, Calendar } from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import type { PayPeriod } from '@/types/payroll';
import {
  getPreviousPeriod,
  getNextPeriod,
  formatPeriodLabel,
  getRecentPeriods,
} from '@/lib/utils/pay-periods';
import { format } from 'date-fns';

interface PayrollPeriodSelectorProps {
  period: PayPeriod;
  onPeriodChange: (period: PayPeriod) => void;
  todayStr: string;
}

export function PayrollPeriodSelector({
  period,
  onPeriodChange,
  todayStr,
}: PayrollPeriodSelectorProps) {
  const recentPeriods = getRecentPeriods(12, todayStr);
  const label = formatPeriodLabel(period);

  return (
    <div className="flex items-center gap-3">
      <Button
        variant="outline"
        size="icon"
        onClick={() => onPeriodChange(getPreviousPeriod(period))}
      >
        <ChevronLeft className="h-4 w-4" />
      </Button>

      <Select
        value={period.start}
        onValueChange={(val) => {
          const found = recentPeriods.find(p => p.start === val);
          if (found) onPeriodChange(found);
        }}
      >
        <SelectTrigger className="w-[280px]">
          <Calendar className="mr-2 h-4 w-4" />
          <SelectValue>{label}</SelectValue>
        </SelectTrigger>
        <SelectContent>
          {recentPeriods.map((p) => (
            <SelectItem key={p.start} value={p.start}>
              {formatPeriodLabel(p)}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Button
        variant="outline"
        size="icon"
        onClick={() => onPeriodChange(getNextPeriod(period))}
        disabled={period.end >= todayStr}
      >
        <ChevronRight className="h-4 w-4" />
      </Button>
    </div>
  );
}

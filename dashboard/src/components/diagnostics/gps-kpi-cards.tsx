import { Card, CardContent } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import { TrendingUp, TrendingDown, Minus } from 'lucide-react';
import type { GpsSummaryPeriod } from '@/types/gps-diagnostics';

interface KpiCardProps {
  label: string;
  value: number | string;
  previousValue?: number;
  unit?: string;
  color: string;
  isLoading?: boolean;
  invertDelta?: boolean;
  subtitle?: string | null;
}

function KpiCard({ label, value, previousValue, unit, color, isLoading, invertDelta, subtitle }: KpiCardProps) {
  if (isLoading) {
    return (
      <Card>
        <CardContent className="py-4">
          <Skeleton className="h-3 w-20 mb-2" />
          <Skeleton className="h-8 w-16" />
          <Skeleton className="h-3 w-14 mt-2" />
        </CardContent>
      </Card>
    );
  }

  const numValue = typeof value === 'number' ? value : parseFloat(value as string);
  const delta = previousValue != null && previousValue > 0
    ? Math.round(((numValue - previousValue) / previousValue) * 100)
    : null;

  const upColor = invertDelta ? 'text-green-500' : 'text-red-500';
  const downColor = invertDelta ? 'text-red-500' : 'text-green-500';

  return (
    <Card>
      <CardContent className="py-4">
        <p className="text-xs text-slate-500 uppercase tracking-wide">{label}</p>
        <p className={`text-2xl font-bold mt-1 ${color}`}>
          {value}{unit && <span className="text-sm font-normal ml-0.5">{unit}</span>}
        </p>
        {delta !== null && (
          <div className="flex items-center gap-1 mt-1">
            {delta > 0 ? (
              <TrendingUp className={`h-3 w-3 ${upColor}`} />
            ) : delta < 0 ? (
              <TrendingDown className={`h-3 w-3 ${downColor}`} />
            ) : (
              <Minus className="h-3 w-3 text-slate-400" />
            )}
            <span className={`text-xs ${delta > 0 ? upColor : delta < 0 ? downColor : 'text-slate-400'}`}>
              {delta > 0 ? '+' : ''}{delta}% vs période préc.
            </span>
          </div>
        )}
        {subtitle && (
          <p className="text-xs text-slate-400 mt-1 truncate">{subtitle}</p>
        )}
      </CardContent>
    </Card>
  );
}

interface GpsKpiCardsProps {
  primary: GpsSummaryPeriod | null;
  comparison: GpsSummaryPeriod | null;
  isLoading: boolean;
}

export function GpsKpiCards({ primary, comparison, isLoading }: GpsKpiCardsProps) {
  return (
    <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-4">
      <KpiCard
        label="Gaps détectés"
        value={primary?.gapsCount ?? 0}
        previousValue={comparison?.gapsCount}
        color="text-amber-600"
        isLoading={isLoading}
      />
      <KpiCard
        label="Service died"
        value={primary?.serviceDiedCount ?? 0}
        previousValue={comparison?.serviceDiedCount}
        color="text-red-600"
        isLoading={isLoading}
      />
      <KpiCard
        label="SLC activations"
        value={primary?.slcCount ?? 0}
        previousValue={comparison?.slcCount}
        color="text-purple-600"
        isLoading={isLoading}
      />
      <KpiCard
        label="Recovery rate"
        value={primary?.recoveryRate ?? 0}
        previousValue={comparison?.recoveryRate}
        unit="%"
        color="text-green-600"
        isLoading={isLoading}
        invertDelta
      />
      <KpiCard
        label="Gap moyen"
        value={primary?.medianGapMinutes ?? 0}
        previousValue={comparison?.medianGapMinutes}
        unit="m"
        color="text-blue-600"
        isLoading={isLoading}
      />
      <KpiCard
        label="Plus long gap"
        value={primary?.maxGapMinutes ?? 0}
        previousValue={comparison?.maxGapMinutes}
        unit="m"
        color="text-red-600"
        isLoading={isLoading}
        subtitle={primary?.maxGapEmployeeName}
      />
    </div>
  );
}

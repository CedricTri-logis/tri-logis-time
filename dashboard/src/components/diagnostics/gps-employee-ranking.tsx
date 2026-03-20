import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import { ChevronRight } from 'lucide-react';
import { cn } from '@/lib/utils';
import { formatDeviceModel } from '@/lib/utils/device-model';
import type { GpsRankedEmployee } from '@/types/gps-diagnostics';

interface GpsEmployeeRankingProps {
  data: GpsRankedEmployee[];
  isLoading: boolean;
  onSelect: (employee: GpsRankedEmployee) => void;
}

export function GpsEmployeeRanking({ data, isLoading, onSelect }: GpsEmployeeRankingProps) {
  if (isLoading) {
    return (
      <Card className="h-full">
        <CardHeader className="pb-3">
          <CardTitle className="text-base font-medium">Employés les plus affectés</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2">
          {[...Array(5)].map((_, i) => (
            <Skeleton key={i} className="h-14 w-full" />
          ))}
        </CardContent>
      </Card>
    );
  }

  if (data.length === 0) {
    return (
      <Card className="h-full">
        <CardHeader className="pb-3">
          <CardTitle className="text-base font-medium">Employés les plus affectés</CardTitle>
        </CardHeader>
        <CardContent className="flex items-center justify-center py-8">
          <p className="text-sm text-slate-500">Aucun problème GPS détecté pour cette période</p>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className="h-full">
      <CardHeader className="pb-3">
        <CardTitle className="text-base font-medium">Employés les plus affectés</CardTitle>
      </CardHeader>
      <CardContent className="space-y-2">
        {data.slice(0, 10).map((emp, idx) => (
          <button
            key={emp.employeeId}
            onClick={() => onSelect(emp)}
            className={cn(
              'flex w-full items-center rounded-lg p-3 text-left transition-colors',
              'border cursor-pointer hover:shadow-sm',
              idx < 1 ? 'bg-red-50 border-red-200' :
              idx < 3 ? 'bg-amber-50 border-amber-200' :
              'bg-white border-slate-200 hover:bg-slate-50'
            )}
          >
            <div className={cn(
              'w-6 text-sm font-bold',
              idx < 1 ? 'text-red-600' : idx < 3 ? 'text-amber-600' : 'text-slate-500'
            )}>
              {idx + 1}
            </div>
            <div className="flex-1 min-w-0">
              <div className="font-medium text-sm text-slate-900 truncate">{emp.fullName}</div>
              <div className="text-xs text-slate-500">
                {emp.devicePlatform === 'ios' ? 'iOS' : 'Android'} · {formatDeviceModel(emp.deviceModel) ?? ''}
              </div>
            </div>
            <div className="text-right mr-2">
              <div className={cn(
                'font-bold text-sm',
                idx < 1 ? 'text-red-600' : 'text-amber-600'
              )}>
                {emp.totalGaps}
              </div>
              <div className="text-xs text-slate-500">
                gaps{emp.totalSlc > 0 ? ` · ${emp.totalSlc} SLC` : ''}{emp.totalServiceDied > 0 ? ` · ${emp.totalServiceDied} died` : ''}
              </div>
            </div>
            <ChevronRight className="h-4 w-4 text-slate-400" />
          </button>
        ))}
      </CardContent>
    </Card>
  );
}

'use client';

import { X } from 'lucide-react';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';
import { useEmployeeGpsGaps } from '@/lib/hooks/use-employee-gps-gaps';
import { useEmployeeGpsEvents } from '@/lib/hooks/use-employee-gps-events';
import { GpsGapsList } from './gps-gaps-list';
import { GpsCorrelatedTimeline } from './gps-correlated-timeline';
import { formatDeviceModel } from '@/lib/utils/device-model';
import type { DrawerState, GpsRankedEmployee } from '@/types/gps-diagnostics';

interface GpsDetailDrawerProps {
  drawer: DrawerState;
  onClose: () => void;
  startDate: string;
  endDate: string;
  rankingData?: GpsRankedEmployee | null;
}

export function GpsDetailDrawer({ drawer, onClose, startDate, endDate, rankingData }: GpsDetailDrawerProps) {
  const { data: gaps, isLoading: gapsLoading } = useEmployeeGpsGaps(
    drawer.employeeId,
    startDate,
    endDate,
  );

  const { data: events, isLoading: eventsLoading } = useEmployeeGpsEvents(
    drawer.employeeId,
    startDate,
    endDate,
  );

  return (
    <div className={cn(
      'fixed inset-y-0 right-0 w-[420px] bg-white border-l-2 border-blue-500 shadow-xl z-50',
      'transform transition-transform duration-200',
      drawer.isOpen ? 'translate-x-0' : 'translate-x-full'
    )}>
      <div className="flex flex-col h-full overflow-y-auto p-5">
        {/* Header */}
        <div className="flex justify-between items-start mb-4">
          <div>
            <h3 className="text-lg font-bold text-slate-900">{drawer.employeeName}</h3>
            <p className="text-xs text-slate-500 mt-0.5">
              {drawer.devicePlatform === 'ios' ? 'iOS' : 'Android'} · {formatDeviceModel(drawer.deviceModel) ?? ''}
            </p>
          </div>
          <Button variant="ghost" size="icon" onClick={onClose} className="h-8 w-8">
            <X className="h-4 w-4" />
          </Button>
        </div>

        {/* Device Info Card */}
        <Card className="mb-4">
          <CardContent className="py-3">
            <div className="grid grid-cols-2 gap-2 text-sm">
              <div><span className="text-slate-500">Plateforme:</span> <strong>{drawer.devicePlatform === 'ios' ? 'iOS' : 'Android'}</strong></div>
              <div><span className="text-slate-500">Appareil:</span> <strong>{formatDeviceModel(drawer.deviceModel) ?? 'N/A'}</strong></div>
              {events.length > 0 && events[0].appVersion && (
                <div><span className="text-slate-500">App:</span> <strong>{events[0].appVersion}</strong></div>
              )}
            </div>
          </CardContent>
        </Card>

        {/* Mini KPIs */}
        {rankingData && (
          <div className="grid grid-cols-3 gap-2 mb-4">
            <div className="bg-red-50 rounded-lg p-3 text-center">
              <div className="text-lg font-bold text-red-600">{rankingData.totalServiceDied}</div>
              <div className="text-xs text-red-800">Service died</div>
            </div>
            <div className="bg-amber-50 rounded-lg p-3 text-center">
              <div className="text-lg font-bold text-amber-600">{rankingData.totalGaps}</div>
              <div className="text-xs text-amber-800">GPS gaps</div>
            </div>
            <div className="bg-green-50 rounded-lg p-3 text-center">
              <div className="text-lg font-bold text-green-600">{rankingData.totalRecoveries}</div>
              <div className="text-xs text-green-800">Recoveries</div>
            </div>
          </div>
        )}

        {/* GPS Gaps */}
        <h4 className="text-sm font-semibold text-slate-900 mb-2">Vrais trous GPS calculés</h4>
        <GpsGapsList gaps={gaps} isLoading={gapsLoading} />

        <div className="my-4 border-t" />

        {/* Correlated Events */}
        <h4 className="text-sm font-semibold text-slate-900 mb-2">Événements corrélés</h4>
        <GpsCorrelatedTimeline events={events} isLoading={eventsLoading} />
      </div>
    </div>
  );
}

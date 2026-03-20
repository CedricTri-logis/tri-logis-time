'use client';

import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Loader2 } from 'lucide-react';
import { format } from 'date-fns';
import { EventTypeBadge, SeverityBadge } from './gps-severity-badge';
import { formatDeviceModel } from '@/lib/utils/device-model';
import type { GpsFeedItem, DiagnosticSeverity } from '@/types/gps-diagnostics';

const SEVERITY_FILTERS: DiagnosticSeverity[] = ['info', 'warn', 'error', 'critical'];

interface GpsIncidentFeedProps {
  items: GpsFeedItem[];
  isLoading: boolean;
  hasMore: boolean;
  onLoadMore: () => void;
  onRowClick: (item: GpsFeedItem) => void;
  activeSeverities: DiagnosticSeverity[];
  onToggleSeverity: (severity: DiagnosticSeverity) => void;
}

export function GpsIncidentFeed({
  items,
  isLoading,
  hasMore,
  onLoadMore,
  onRowClick,
  activeSeverities,
  onToggleSeverity,
}: GpsIncidentFeedProps) {
  return (
    <Card>
      <CardHeader className="pb-3">
        <div className="flex items-center justify-between">
          <CardTitle className="text-base font-medium">Feed d&apos;incidents GPS</CardTitle>
          <div className="flex gap-1.5">
            {SEVERITY_FILTERS.map((sev) => (
              <button
                key={sev}
                onClick={() => onToggleSeverity(sev)}
                className={`px-2.5 py-0.5 rounded-full text-xs font-medium transition-colors cursor-pointer ${
                  activeSeverities.includes(sev)
                    ? sev === 'info' ? 'bg-blue-100 text-blue-800'
                    : sev === 'warn' ? 'bg-amber-100 text-amber-800'
                    : 'bg-red-100 text-red-800'
                    : 'bg-slate-100 text-slate-400'
                }`}
              >
                {sev}
              </button>
            ))}
          </div>
        </div>
      </CardHeader>
      <CardContent className="p-0">
        {isLoading && items.length === 0 ? (
          <div className="p-4 space-y-3">
            {[...Array(5)].map((_, i) => (
              <Skeleton key={i} className="h-10 w-full" />
            ))}
          </div>
        ) : items.length === 0 ? (
          <div className="p-8 text-center text-slate-500">
            <p className="font-medium">Aucun événement pour les filtres sélectionnés</p>
            <p className="text-xs mt-1">Essayez d&apos;élargir les filtres de sévérité</p>
          </div>
        ) : (
          <>
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-[80px]">Heure</TableHead>
                    <TableHead className="w-[140px]">Employé</TableHead>
                    <TableHead>Événement</TableHead>
                    <TableHead className="w-[100px]">Type</TableHead>
                    <TableHead className="w-[100px]">Appareil</TableHead>
                    <TableHead className="w-[60px]">Ver.</TableHead>
                    <TableHead className="w-[70px]">Sév.</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {items.map((item) => (
                    <TableRow
                      key={item.id}
                      className="cursor-pointer hover:bg-slate-50"
                      onClick={() => onRowClick(item)}
                    >
                      <TableCell className="font-mono text-xs text-slate-500">
                        {format(item.createdAt, 'HH:mm:ss')}
                      </TableCell>
                      <TableCell className="font-medium text-sm">{item.fullName}</TableCell>
                      <TableCell className="text-sm text-slate-600 max-w-[300px] truncate">
                        {item.message}
                      </TableCell>
                      <TableCell><EventTypeBadge type={item.eventType} /></TableCell>
                      <TableCell className="text-xs text-slate-500">
                        {formatDeviceModel(item.deviceModel) ?? ''}
                      </TableCell>
                      <TableCell className="text-xs text-slate-500">
                        {item.appVersion ? `+${item.appVersion.split('+')[1] ?? item.appVersion}` : '—'}
                      </TableCell>
                      <TableCell><SeverityBadge severity={item.severity} /></TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
            {hasMore && (
              <div className="p-3 text-center border-t">
                <Button variant="ghost" size="sm" onClick={onLoadMore} disabled={isLoading}>
                  {isLoading ? <Loader2 className="h-4 w-4 animate-spin mr-2" /> : null}
                  Charger plus
                </Button>
              </div>
            )}
          </>
        )}
      </CardContent>
    </Card>
  );
}

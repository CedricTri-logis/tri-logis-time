'use client';

import { useState, useMemo } from 'react';
import { useParams, useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { toLocalDateString } from '@/lib/utils/date-utils';
import {
  useEmployeeUtilizationDetail,
  type DayDetail,
  type ClusterDetail,
} from '@/lib/hooks/use-employee-utilization-detail';
import { format, parseISO, subDays } from 'date-fns';
import { fr } from 'date-fns/locale';

function formatHours(minutes: number): string {
  return (minutes / 60).toFixed(1) + 'h';
}

function PercentBar({ value, thresholds }: {
  value: number | null;
  thresholds: { green: number; yellow: number };
}) {
  if (value === null) return <span className="text-sm text-slate-400">N/A</span>;
  const color = value >= thresholds.green ? 'text-emerald-600'
    : value >= thresholds.yellow ? 'text-amber-600' : 'text-red-600';
  return <span className={`font-semibold ${color}`}>{value.toFixed(1)}%</span>;
}

const CATEGORY_COLORS: Record<string, string> = {
  match: '#10b981',
  mismatch: '#ef4444',
  office: '#3b82f6',
  home: '#8b5cf6',
};
const TRIP_COLOR = '#f59e0b';
const EMPTY_COLOR = '#e2e8f0';

function DayTimeline({
  day,
  isSelected,
  onClick,
}: {
  day: DayDetail;
  isSelected: boolean;
  onClick: () => void;
}) {
  const shiftStart = new Date(day.clocked_in_at).getTime();
  const shiftEnd = new Date(day.clocked_out_at).getTime();
  const shiftDuration = shiftEnd - shiftStart;
  if (shiftDuration <= 0) return null;

  const toPercent = (time: string) => {
    const t = new Date(time).getTime();
    return Math.max(0, Math.min(100, ((t - shiftStart) / shiftDuration) * 100));
  };

  const segments: Array<{ left: number; width: number; color: string }> = [];

  for (const c of day.clusters) {
    const left = toPercent(c.started_at);
    const right = toPercent(c.ended_at);
    const color = c.location_category
      ? (CATEGORY_COLORS[c.location_category] || EMPTY_COLOR)
      : EMPTY_COLOR;
    segments.push({ left, width: right - left, color });
  }

  for (const t of day.trips) {
    const left = toPercent(t.started_at);
    const right = toPercent(t.ended_at);
    segments.push({ left, width: right - left, color: TRIP_COLOR });
  }

  const dateLabel = format(parseISO(day.date), 'EEE d MMM', { locale: fr });

  return (
    <div
      className={`flex items-center gap-3 cursor-pointer rounded-md px-2 py-1 ${isSelected ? 'bg-blue-50 ring-2 ring-blue-400' : 'hover:bg-slate-50'}`}
      onClick={onClick}
    >
      <span className="w-28 shrink-0 text-xs text-slate-500">
        {dateLabel} ({formatHours(day.shift_minutes)})
      </span>
      <div className="relative h-6 flex-1 rounded bg-slate-100 overflow-hidden">
        {segments.map((seg, i) => (
          <div
            key={i}
            className="absolute top-0 h-full"
            style={{
              left: `${seg.left}%`,
              width: `${Math.max(seg.width, 0.5)}%`,
              backgroundColor: seg.color,
              opacity: 0.7,
            }}
          />
        ))}
      </div>
    </div>
  );
}

export default function EmployeeUtilizationDetailPage() {
  const params = useParams();
  const searchParams = useSearchParams();
  const employeeId = params.employeeId as string;

  const fromParam = searchParams.get('from');
  const toParam = searchParams.get('to');

  const [dateFrom, setDateFrom] = useState(() =>
    fromParam ? new Date(fromParam + 'T00:00:00') : subDays(new Date(), 7)
  );
  const [dateTo, setDateTo] = useState(() =>
    toParam ? new Date(toParam + 'T00:00:00') : new Date()
  );
  const [selectedDate, setSelectedDate] = useState<string | null>(null);

  const { data, isLoading } = useEmployeeUtilizationDetail({
    employeeId,
    dateFrom,
    dateTo,
  });

  const filteredClusters = useMemo(() => {
    if (!data) return [];
    const days = selectedDate
      ? data.days.filter((d) => d.date === selectedDate)
      : data.days;
    return days.flatMap((d) =>
      d.clusters.map((c) => ({ ...c, date: d.date }))
    );
  }, [data, selectedDate]);

  const clusterStats = useMemo(() => {
    const total = filteredClusters.length;
    const matches = filteredClusters.filter((c) => c.match === true).length;
    const mismatches = filteredClusters.filter((c) => c.match === false).length;
    return { total, matches, mismatches };
  }, [filteredClusters]);

  const backHref = `/dashboard/reports/cleaning-utilization?from=${toLocalDateString(dateFrom)}&to=${toLocalDateString(dateTo)}`;

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <div className="flex items-center gap-3 mb-1">
            <Button variant="ghost" size="sm" asChild>
              <Link href={backHref}>
                <ArrowLeft className="h-4 w-4 mr-1" />
                Retour
              </Link>
            </Button>
          </div>
          <h1 className="text-2xl font-bold text-slate-900">
            {data?.employeeName ?? 'Chargement...'}
          </h1>
          {data?.summary && (
            <div className="mt-1 flex flex-wrap gap-4 text-sm text-slate-500">
              <span>{data.summary.total_shifts} shifts</span>
              <span>Utilisation: <PercentBar value={data.summary.utilization_pct} thresholds={{ green: 80, yellow: 60 }} /></span>
              <span>Accuracy: <PercentBar value={data.summary.accuracy_pct} thresholds={{ green: 90, yellow: 70 }} /></span>
              <span>{formatHours(data.summary.total_shift_minutes)} total</span>
            </div>
          )}
        </div>
        <div className="flex gap-2">
          <input type="date" className="rounded-md border border-slate-300 px-3 py-2 text-sm"
            value={toLocalDateString(dateFrom)}
            onChange={(e) => { setDateFrom(new Date(e.target.value + 'T00:00:00')); setSelectedDate(null); }} />
          <input type="date" className="rounded-md border border-slate-300 px-3 py-2 text-sm"
            value={toLocalDateString(dateTo)}
            onChange={(e) => { setDateTo(new Date(e.target.value + 'T00:00:00')); setSelectedDate(null); }} />
        </div>
      </div>

      {isLoading ? (
        <div className="py-12 text-center text-sm text-slate-400">Chargement...</div>
      ) : !data || data.days.length === 0 ? (
        <div className="py-12 text-center text-sm text-slate-400">Aucune donnee pour la periode selectionnee</div>
      ) : (
        <>
          {/* Timeline */}
          <Card>
            <CardHeader>
              <CardTitle className="text-lg">Timeline par jour</CardTitle>
            </CardHeader>
            <CardContent>
              <div className="space-y-1">
                {data.days.map((day) => (
                  <DayTimeline
                    key={day.shift_id}
                    day={day}
                    isSelected={selectedDate === day.date}
                    onClick={() => setSelectedDate(
                      selectedDate === day.date ? null : day.date
                    )}
                  />
                ))}
              </div>
              <div className="mt-4 flex flex-wrap gap-4 text-xs text-slate-400">
                <span><span className="inline-block w-3 h-3 rounded-sm mr-1" style={{ backgroundColor: CATEGORY_COLORS.match, opacity: 0.7 }} />Au bon endroit</span>
                <span><span className="inline-block w-3 h-3 rounded-sm mr-1" style={{ backgroundColor: CATEGORY_COLORS.mismatch, opacity: 0.7 }} />Mauvais endroit</span>
                <span><span className="inline-block w-3 h-3 rounded-sm mr-1" style={{ backgroundColor: CATEGORY_COLORS.office, opacity: 0.7 }} />Bureau</span>
                <span><span className="inline-block w-3 h-3 rounded-sm mr-1" style={{ backgroundColor: CATEGORY_COLORS.home, opacity: 0.7 }} />Domicile</span>
                <span><span className="inline-block w-3 h-3 rounded-sm mr-1" style={{ backgroundColor: TRIP_COLOR, opacity: 0.7 }} />Deplacement</span>
                <span><span className="inline-block w-3 h-3 rounded-sm mr-1" style={{ backgroundColor: EMPTY_COLOR }} />Pas de session</span>
              </div>
              <p className="mt-2 text-xs text-slate-400">Cliquez sur un jour pour filtrer le tableau</p>
            </CardContent>
          </Card>

          {/* Cluster detail table */}
          <Card>
            <CardHeader>
              <div className="flex items-center justify-between">
                <CardTitle className="text-lg">
                  Detail des clusters{selectedDate ? ` — ${format(parseISO(selectedDate), 'd MMM', { locale: fr })}` : ''}
                </CardTitle>
                <span className="text-sm text-slate-500">
                  {clusterStats.total} clusters · {clusterStats.matches} match · {clusterStats.mismatches} mismatch
                </span>
              </div>
            </CardHeader>
            <CardContent>
              {filteredClusters.length === 0 ? (
                <div className="py-8 text-center text-sm text-slate-400">Aucun cluster</div>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="border-b text-left text-xs font-medium uppercase text-slate-500">
                        <th className="pb-3 pr-4">Heure</th>
                        <th className="pb-3 pr-4">Lieu physique</th>
                        <th className="pb-3 pr-4">Session declaree</th>
                        <th className="pb-3 pr-4 text-center">Match</th>
                        <th className="pb-3 text-right">Duree</th>
                      </tr>
                    </thead>
                    <tbody>
                      {filteredClusters.map((c, i) => {
                        const isMismatch = c.match === false;
                        return (
                          <tr key={i} className={`border-b last:border-0 ${isMismatch ? 'bg-red-50' : ''}`}>
                            <td className="py-3 pr-4 text-slate-600">
                              {format(parseISO(c.started_at), 'HH:mm')} - {format(parseISO(c.ended_at), 'HH:mm')}
                            </td>
                            <td className="py-3 pr-4 font-medium">{c.physical_location}</td>
                            <td className="py-3 pr-4 text-slate-600">{c.session_building ?? '\u2014'}</td>
                            <td className="py-3 pr-4 text-center">
                              {c.match === true && <span className="text-emerald-600 font-bold">{'\u2713'}</span>}
                              {c.match === false && <span className="text-red-600 font-bold">{'\u2717'}</span>}
                              {c.match === null && c.location_category === 'office' && <span className="text-blue-600 font-bold">Bureau</span>}
                              {c.match === null && c.location_category === 'home' && <span className="text-purple-600 font-bold">Domicile</span>}
                              {c.match === null && c.location_category === null && <span className="text-slate-400">{'\u2014'}</span>}
                            </td>
                            <td className="py-3 text-right">{c.duration_minutes} min</td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}

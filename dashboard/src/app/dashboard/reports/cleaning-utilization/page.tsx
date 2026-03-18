'use client';

import { useState, useEffect } from 'react';
import { useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { toLocalDateString } from '@/lib/utils/date-utils';
import { supabaseClient } from '@/lib/supabase/client';
import {
  useCleaningUtilization,
  type CleaningUtilizationEmployee,
} from '@/lib/hooks/use-cleaning-utilization';
import { subDays } from 'date-fns';

function formatHours(minutes: number): string {
  return (minutes / 60).toFixed(1) + 'h';
}

function PercentBar({ value, thresholds }: {
  value: number | null;
  thresholds: { green: number; yellow: number };
}) {
  if (value === null) return <span className="text-sm text-slate-400">N/A</span>;
  const color =
    value >= thresholds.green
      ? 'bg-emerald-500'
      : value >= thresholds.yellow
        ? 'bg-amber-500'
        : 'bg-red-500';
  return (
    <div className="flex items-center gap-2">
      <div className="h-2 w-20 rounded-full bg-slate-100">
        <div
          className={`h-2 rounded-full ${color}`}
          style={{ width: `${Math.min(value, 100)}%` }}
        />
      </div>
      <span className="text-sm font-medium">{value.toFixed(1)}%</span>
    </div>
  );
}

export default function CleaningUtilizationPage() {
  const searchParams = useSearchParams();
  const fromParam = searchParams.get('from');
  const toParam = searchParams.get('to');

  const [dateFrom, setDateFrom] = useState(() =>
    fromParam ? new Date(fromParam + 'T00:00:00') : subDays(new Date(), 7)
  );
  const [dateTo, setDateTo] = useState(() =>
    toParam ? new Date(toParam + 'T00:00:00') : new Date()
  );
  const [employeeId, setEmployeeId] = useState<string>('');

  // Fetch employee list for filter
  const [employeeOptions, setEmployeeOptions] = useState<Array<{ id: string; full_name: string }>>([]);
  useEffect(() => {
    async function loadEmployees() {
      const { data, error } = await supabaseClient.rpc('get_supervised_employees');
      if (data && !error) {
        const sorted = (data as Array<{ id: string; full_name: string }>)
          .sort((a, b) => (a.full_name ?? '').localeCompare(b.full_name ?? ''));
        setEmployeeOptions(sorted);
      }
    }
    loadEmployees();
  }, []);

  const { employees, totals, isLoading } = useCleaningUtilization({
    dateFrom,
    dateTo,
    employeeId: employeeId || undefined,
  });

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-slate-900">
          Utilisation menage
        </h1>
        <p className="mt-1 text-sm text-slate-500">
          Taux d&apos;utilisation et precision GPS par employe
        </p>
      </div>

      {/* Filters */}
      <Card>
        <CardContent className="pt-6">
          <div className="flex flex-wrap items-end gap-4">
            <div>
              <label className="mb-1 block text-sm font-medium text-slate-700">
                Du
              </label>
              <input
                type="date"
                className="rounded-md border border-slate-300 px-3 py-2 text-sm"
                value={toLocalDateString(dateFrom)}
                onChange={(e) =>
                  setDateFrom(new Date(e.target.value + 'T00:00:00'))
                }
              />
            </div>
            <div>
              <label className="mb-1 block text-sm font-medium text-slate-700">
                Au
              </label>
              <input
                type="date"
                className="rounded-md border border-slate-300 px-3 py-2 text-sm"
                value={toLocalDateString(dateTo)}
                onChange={(e) =>
                  setDateTo(new Date(e.target.value + 'T00:00:00'))
                }
              />
            </div>
            <div>
              <label className="mb-1 block text-sm font-medium text-slate-700">
                Employe
              </label>
              <select
                className="rounded-md border border-slate-300 px-3 py-2 text-sm"
                value={employeeId}
                onChange={(e) => setEmployeeId(e.target.value)}
              >
                <option value="">Tous les employes</option>
                {employeeOptions.map((emp) => (
                  <option key={emp.id} value={emp.id}>
                    {emp.full_name}
                  </option>
                ))}
              </select>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Table */}
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Resultats</CardTitle>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <div className="py-12 text-center text-sm text-slate-400">
              Chargement...
            </div>
          ) : employees.length === 0 ? (
            <div className="py-12 text-center text-sm text-slate-400">
              Aucune donnee pour la periode selectionnee
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b text-left text-xs font-medium uppercase text-slate-500">
                    <th className="pb-3 pr-4">Employe</th>
                    <th className="pb-3 pr-4 text-right">Shifts</th>
                    <th className="pb-3 pr-4 text-right">Deplacements</th>
                    <th className="pb-3 pr-4 text-right">Sessions</th>
                    <th className="pb-3 pr-4">Utilisation</th>
                    <th className="pb-3 pr-4">Accuracy</th>
                    <th className="pb-3 pr-4 text-right">Unites CT</th>
                    <th className="pb-3 pr-4 text-right">Aires comm. CT</th>
                    <th className="pb-3 pr-4 text-right">Menage LT</th>
                    <th className="pb-3 pr-4 text-right">Entretien LT</th>
                    <th className="pb-3 text-right">Bureau</th>
                  </tr>
                </thead>
                <tbody>
                  {employees.map((emp: CleaningUtilizationEmployee) => (
                    <tr
                      key={emp.employee_id}
                      className="border-b last:border-0"
                    >
                      <td className="py-3 pr-4 font-medium">
                        <Link
                          href={`/dashboard/reports/cleaning-utilization/${emp.employee_id}?from=${toLocalDateString(dateFrom)}&to=${toLocalDateString(dateTo)}`}
                          className="text-blue-600 hover:underline"
                        >
                          {emp.employee_name}
                        </Link>
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(emp.total_shift_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(emp.total_trip_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(emp.total_session_minutes)}
                      </td>
                      <td className="py-3 pr-4">
                        <PercentBar
                          value={emp.utilization_pct}
                          thresholds={{ green: 80, yellow: 60 }}
                        />
                      </td>
                      <td className="py-3 pr-4">
                        <PercentBar
                          value={emp.accuracy_pct}
                          thresholds={{ green: 90, yellow: 70 }}
                        />
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(emp.short_term_unit_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(emp.short_term_common_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(emp.cleaning_long_term_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(emp.maintenance_long_term_minutes)}
                      </td>
                      <td className="py-3 text-right">
                        {formatHours(emp.office_minutes)}
                      </td>
                    </tr>
                  ))}
                </tbody>
                {/* Footer totals */}
                {totals && (
                  <tfoot>
                    <tr className="border-t-2 font-semibold">
                      <td className="py-3 pr-4">
                        Totaux ({totals.employee_count} employes)
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(totals.total_shift_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(totals.total_trip_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(totals.total_session_minutes)}
                      </td>
                      <td className="py-3 pr-4">
                        <PercentBar
                          value={totals.utilization_pct}
                          thresholds={{ green: 80, yellow: 60 }}
                        />
                      </td>
                      <td className="py-3 pr-4">
                        <PercentBar
                          value={totals.accuracy_pct}
                          thresholds={{ green: 90, yellow: 70 }}
                        />
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(totals.short_term_unit_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(totals.short_term_common_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(totals.cleaning_long_term_minutes)}
                      </td>
                      <td className="py-3 pr-4 text-right">
                        {formatHours(totals.maintenance_long_term_minutes)}
                      </td>
                      <td className="py-3 text-right">
                        {formatHours(totals.office_minutes)}
                      </td>
                    </tr>
                  </tfoot>
                )}
              </table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

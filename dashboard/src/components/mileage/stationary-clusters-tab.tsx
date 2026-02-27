'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Loader2, MapPin } from 'lucide-react';
import { supabaseClient } from '@/lib/supabase/client';
import { StationaryClustersMap } from './stationary-clusters-map';
import type { StationaryCluster } from './stationary-clusters-map';

interface Employee {
  id: string;
  full_name: string | null;
}

function formatDuration(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (hours > 0) return `${hours}h ${minutes}min`;
  return `${minutes}min`;
}

function formatDateTime(dateStr: string): string {
  const d = new Date(dateStr);
  return `${d.toLocaleDateString('fr-CA', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  })} ${d.toLocaleTimeString('fr-CA', { hour: '2-digit', minute: '2-digit' })}`;
}

function getDefaultDateFrom(): string {
  const d = new Date();
  d.setDate(d.getDate() - 30);
  return d.toISOString().split('T')[0];
}

function getDefaultDateTo(): string {
  return new Date().toISOString().split('T')[0];
}

export function StationaryClustersTab() {
  // Filters
  const [selectedEmployee, setSelectedEmployee] = useState<string>('');
  const [dateFrom, setDateFrom] = useState(getDefaultDateFrom);
  const [dateTo, setDateTo] = useState(getDefaultDateTo);
  const [minDuration, setMinDuration] = useState(300); // 5 min default

  // Data
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [clusters, setClusters] = useState<StationaryCluster[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Map selection
  const [selectedClusterId, setSelectedClusterId] = useState<string | null>(null);

  // Fetch employees
  useEffect(() => {
    (async () => {
      const { data } = await supabaseClient
        .from('employee_profiles')
        .select('id, full_name')
        .order('full_name');
      if (data) {
        setEmployees(data as Employee[]);
      }
    })();
  }, []);

  // Fetch clusters
  const fetchClusters = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      const { data, error: rpcError } = await supabaseClient.rpc('get_stationary_clusters', {
        p_employee_id: selectedEmployee || undefined,
        p_date_from: dateFrom || undefined,
        p_date_to: dateTo || undefined,
        p_min_duration_seconds: minDuration,
      });

      if (rpcError) {
        setError(rpcError.message);
        setClusters([]);
        return;
      }

      setClusters((data as StationaryCluster[]) || []);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Erreur lors du chargement');
      setClusters([]);
    } finally {
      setIsLoading(false);
    }
  }, [selectedEmployee, dateFrom, dateTo, minDuration]);

  useEffect(() => {
    fetchClusters();
  }, [fetchClusters]);

  // Stats
  const stats = useMemo(() => {
    const total = clusters.length;
    const matched = clusters.filter((c) => c.matched_location_id).length;
    const unmatched = total - matched;
    return { total, matched, unmatched };
  }, [clusters]);

  return (
    <div className="space-y-4">
      {/* Filter bar */}
      <Card>
        <CardContent className="pt-4 pb-4">
          <div className="flex flex-wrap items-end gap-4">
            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-muted-foreground">Employ&eacute;</label>
              <select
                className="h-9 rounded-md border border-input bg-background px-3 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2"
                value={selectedEmployee}
                onChange={(e) => setSelectedEmployee(e.target.value)}
              >
                <option value="">Tous les employ&eacute;s</option>
                {employees.map((emp) => (
                  <option key={emp.id} value={emp.id}>
                    {emp.full_name || emp.id}
                  </option>
                ))}
              </select>
            </div>

            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-muted-foreground">Date d&eacute;but</label>
              <input
                type="date"
                className="h-9 rounded-md border border-input bg-background px-3 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2"
                value={dateFrom}
                onChange={(e) => setDateFrom(e.target.value)}
              />
            </div>

            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-muted-foreground">Date fin</label>
              <input
                type="date"
                className="h-9 rounded-md border border-input bg-background px-3 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2"
                value={dateTo}
                onChange={(e) => setDateTo(e.target.value)}
              />
            </div>

            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-muted-foreground">Dur&eacute;e minimum</label>
              <select
                className="h-9 rounded-md border border-input bg-background px-3 text-sm ring-offset-background focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2"
                value={minDuration}
                onChange={(e) => setMinDuration(Number(e.target.value))}
              >
                <option value={180}>3 min</option>
                <option value={300}>5 min</option>
                <option value={600}>10 min</option>
                <option value={900}>15 min</option>
                <option value={1800}>30 min</option>
              </select>
            </div>

            <div className="flex items-center gap-3 text-xs text-muted-foreground ml-auto">
              <span>{stats.total} arr&ecirc;t{stats.total !== 1 ? 's' : ''}</span>
              <span className="text-green-600">{stats.matched} associ&eacute;{stats.matched !== 1 ? 's' : ''}</span>
              <span className="text-amber-600">{stats.unmatched} non associ&eacute;{stats.unmatched !== 1 ? 's' : ''}</span>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Map */}
      <StationaryClustersMap
        clusters={clusters}
        height={400}
        selectedClusterId={selectedClusterId}
        onClusterSelect={setSelectedClusterId}
      />

      {/* Table */}
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <MapPin className="h-5 w-5" />
            Arr&ecirc;ts d&eacute;tect&eacute;s
          </CardTitle>
        </CardHeader>
        <CardContent>
          {error && (
            <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 mb-4">
              {error}
            </div>
          )}

          {isLoading ? (
            <div className="flex items-center justify-center py-12">
              <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
            </div>
          ) : clusters.length === 0 ? (
            <div className="py-8 text-center text-sm text-muted-foreground">
              Aucun arr&ecirc;t trouv&eacute; pour les filtres s&eacute;lectionn&eacute;s.
            </div>
          ) : (
            <div className="overflow-x-auto -mx-6">
              <table className="w-full text-sm">
                <thead className="border-b bg-muted/50">
                  <tr>
                    <th className="px-4 py-3 text-left font-medium text-muted-foreground">Employ&eacute;</th>
                    <th className="px-4 py-3 text-left font-medium text-muted-foreground">Emplacement</th>
                    <th className="px-4 py-3 text-left font-medium text-muted-foreground">D&eacute;but</th>
                    <th className="px-4 py-3 text-right font-medium text-muted-foreground">Dur&eacute;e</th>
                    <th className="px-4 py-3 text-right font-medium text-muted-foreground">Points GPS</th>
                    <th className="px-4 py-3 text-right font-medium text-muted-foreground">Pr&eacute;cision</th>
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {clusters.map((cluster) => (
                    <tr
                      key={cluster.id}
                      className={`cursor-pointer hover:bg-muted/50 transition-colors ${
                        !cluster.matched_location_id ? 'bg-amber-50' : ''
                      } ${selectedClusterId === cluster.id ? 'ring-2 ring-inset ring-primary/30' : ''}`}
                      onClick={() =>
                        setSelectedClusterId(selectedClusterId === cluster.id ? null : cluster.id)
                      }
                    >
                      <td className="px-4 py-3 font-medium">{cluster.employee_name}</td>
                      <td className="px-4 py-3">
                        {cluster.matched_location_name ? (
                          <span>{cluster.matched_location_name}</span>
                        ) : (
                          <span className="text-amber-600">Non associ&eacute;</span>
                        )}
                      </td>
                      <td className="px-4 py-3 text-muted-foreground whitespace-nowrap">
                        {formatDateTime(cluster.started_at)}
                      </td>
                      <td className="px-4 py-3 text-right tabular-nums">
                        {formatDuration(cluster.duration_seconds)}
                      </td>
                      <td className="px-4 py-3 text-right tabular-nums">
                        {cluster.gps_point_count}
                      </td>
                      <td className="px-4 py-3 text-right tabular-nums text-muted-foreground">
                        {cluster.centroid_accuracy != null
                          ? `${Math.round(cluster.centroid_accuracy)} m`
                          : '\u2014'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

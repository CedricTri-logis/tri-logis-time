'use client';

import { useState, useCallback, useEffect, useMemo } from 'react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import {
  RefreshCw,
  CheckCircle,
  AlertTriangle,
  XCircle,
  Loader2,
  Car,
  Footprints,
  MapPin,
  ArrowRight,
  ChevronDown,
  ChevronUp,
  Play,
} from 'lucide-react';
import { toast } from 'sonner';
import { supabaseClient } from '@/lib/supabase/client';
import { MatchStatusBadge } from '@/components/trips/match-status-badge';
import { GoogleTripRouteMap } from '@/components/trips/google-trip-route-map';
import { LocationPickerDropdown } from '@/components/trips/location-picker-dropdown';
import type { Trip, TripGpsPoint } from '@/types/mileage';

interface BatchResult {
  trip_id: string;
  status: 'matched' | 'failed' | 'anomalous' | 'skipped';
  road_distance_km: number | null;
  match_confidence: number | null;
  error: string | null;
}

interface BatchSummary {
  total_requested: number;
  processed: number;
  matched: number;
  failed: number;
  anomalous: number;
  skipped: number;
  duration_seconds: number;
}

interface BatchResponse {
  success: boolean;
  summary: BatchSummary;
  results: BatchResult[];
  error?: string;
  code?: string;
}

type SortField = 'started_at' | 'distance_km' | 'road_distance_km' | 'match_status';
type SortOrder = 'asc' | 'desc';
type StatusFilter = 'all' | 'matched' | 'pending' | 'failed' | 'anomalous';
type ModeFilter = 'all' | 'driving' | 'walking';

function formatDate(dateStr: string): string {
  const d = new Date(dateStr);
  return d.toLocaleDateString('fr-CA', { month: 'short', day: 'numeric', year: 'numeric' });
}

function formatTime(dateStr: string): string {
  const d = new Date(dateStr);
  return d.toLocaleTimeString('fr-CA', { hour: '2-digit', minute: '2-digit' });
}

function formatDistance(km: number | null): string {
  if (km == null) return '—';
  return `${km.toFixed(1)} km`;
}

function formatConfidence(conf: number | null): string {
  if (conf == null) return '—';
  return `${(conf * 100).toFixed(0)}%`;
}

function formatLocation(address: string | null, lat: number, lng: number): string {
  if (address) return address;
  return `${lat.toFixed(4)}, ${lng.toFixed(4)}`;
}

export default function MileagePage() {
  const [isProcessing, setIsProcessing] = useState(false);
  const [showDialog, setShowDialog] = useState(false);
  const [dialogMode, setDialogMode] = useState<'failed' | 'all'>('failed');
  const [batchResult, setBatchResult] = useState<BatchResponse | null>(null);
  const [batchError, setBatchError] = useState<string | null>(null);

  // Trips list state
  const [trips, setTrips] = useState<Trip[]>([]);
  const [isLoadingTrips, setIsLoadingTrips] = useState(true);
  const [tripsError, setTripsError] = useState<string | null>(null);
  const [sortField, setSortField] = useState<SortField>('started_at');
  const [sortOrder, setSortOrder] = useState<SortOrder>('desc');
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('all');
  const [expandedTrip, setExpandedTrip] = useState<string | null>(null);
  const [modeFilter, setModeFilter] = useState<ModeFilter>('all');

  // Fetch trips — uses two separate queries to avoid PostgREST recursive RLS
  // on employee_profiles (self-referencing subquery in SELECT policy)
  const fetchTrips = useCallback(async () => {
    setIsLoadingTrips(true);
    setTripsError(null);
    try {
      // 1. Fetch trips
      const { data: tripsData, error: tripsError } = await supabaseClient
        .from('trips')
        .select('*')
        .order('started_at', { ascending: false })
        .limit(500);

      if (tripsError) {
        setTripsError(tripsError.message);
        return;
      }

      if (!tripsData || tripsData.length === 0) {
        setTrips([]);
        return;
      }

      // 2. Fetch employee profiles for all unique employee_ids
      const employeeIds = [...new Set(tripsData.map((t) => t.employee_id).filter(Boolean))];
      const employeeMap: Record<string, { id: string; full_name: string | null; email: string | null }> = {};

      if (employeeIds.length > 0) {
        const { data: employees } = await supabaseClient
          .from('employee_profiles')
          .select('id, full_name, email')
          .in('id', employeeIds);

        if (employees) {
          for (const emp of employees) {
            employeeMap[emp.id] = emp;
          }
        }
      }

      // 3. Fetch location names for all referenced location IDs
      const locationIds = [
        ...new Set([
          ...tripsData.map((t: any) => t.start_location_id).filter(Boolean),
          ...tripsData.map((t: any) => t.end_location_id).filter(Boolean),
        ]),
      ];
      const locationMap: Record<string, { id: string; name: string }> = {};

      if (locationIds.length > 0) {
        const { data: locations } = await supabaseClient
          .from('locations')
          .select('id, name')
          .in('id', locationIds);

        if (locations) {
          for (const loc of locations) {
            locationMap[loc.id] = loc;
          }
        }
      }

      // 4. Merge employee + location data into trips
      const mergedTrips = tripsData.map((trip: any) => ({
        ...trip,
        employee: employeeMap[trip.employee_id] ?? null,
        start_location: trip.start_location_id ? locationMap[trip.start_location_id] ?? null : null,
        end_location: trip.end_location_id ? locationMap[trip.end_location_id] ?? null : null,
      }));

      setTrips(mergedTrips as Trip[]);
    } catch (err) {
      setTripsError(err instanceof Error ? err.message : 'Échec du chargement des trajets');
    } finally {
      setIsLoadingTrips(false);
    }
  }, []);

  useEffect(() => {
    fetchTrips();
  }, [fetchTrips]);

  // Summary stats
  const stats = useMemo(() => {
    const total = trips.length;
    const matched = trips.filter((t) => t.match_status === 'matched').length;
    const pending = trips.filter((t) => t.match_status === 'pending' || t.match_status === 'processing').length;
    const failed = trips.filter((t) => t.match_status === 'failed').length;
    const anomalous = trips.filter((t) => t.match_status === 'anomalous').length;
    const driving = trips.filter((t) => t.transport_mode === 'driving').length;
    const walking = trips.filter((t) => t.transport_mode === 'walking').length;
    return { total, matched, pending, failed, anomalous, driving, walking };
  }, [trips]);

  // Filter and sort
  const filteredTrips = useMemo(() => {
    let filtered = trips;
    if (statusFilter !== 'all') {
      if (statusFilter === 'pending') {
        filtered = filtered.filter((t) => t.match_status === 'pending' || t.match_status === 'processing');
      } else {
        filtered = filtered.filter((t) => t.match_status === statusFilter);
      }
    }
    if (modeFilter !== 'all') {
      filtered = filtered.filter((t) => t.transport_mode === modeFilter);
    }

    return [...filtered].sort((a, b) => {
      let cmp = 0;
      switch (sortField) {
        case 'started_at':
          cmp = new Date(a.started_at).getTime() - new Date(b.started_at).getTime();
          break;
        case 'distance_km':
          cmp = a.distance_km - b.distance_km;
          break;
        case 'road_distance_km':
          cmp = (a.road_distance_km ?? 0) - (b.road_distance_km ?? 0);
          break;
        case 'match_status': {
          const order = { matched: 0, anomalous: 1, pending: 2, processing: 2, failed: 3 };
          cmp = (order[a.match_status] ?? 4) - (order[b.match_status] ?? 4);
          break;
        }
      }
      return sortOrder === 'asc' ? cmp : -cmp;
    });
  }, [trips, statusFilter, modeFilter, sortField, sortOrder]);

  const toggleSort = (field: SortField) => {
    if (sortField === field) {
      setSortOrder((o) => (o === 'asc' ? 'desc' : 'asc'));
    } else {
      setSortField(field);
      setSortOrder('desc');
    }
  };

  const sortIndicator = (field: SortField) => {
    if (sortField !== field) return null;
    return sortOrder === 'asc' ? <ChevronUp className="inline h-3 w-3" /> : <ChevronDown className="inline h-3 w-3" />;
  };

  const handleReprocess = useCallback(
    async (mode: 'failed' | 'all') => {
      setIsProcessing(true);
      setBatchError(null);
      setBatchResult(null);

      try {
        const body =
          mode === 'failed'
            ? { reprocess_failed: true, limit: 500 }
            : { reprocess_all: true, limit: 500 };

        const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!.trim();
        const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!.trim();

        const res = await fetch(`${supabaseUrl}/functions/v1/batch-match-trips`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${anonKey}`,
            apikey: anonKey,
          },
          body: JSON.stringify(body),
        });

        if (!res.ok) {
          const errorText = await res.text();
          setBatchError(`HTTP ${res.status}: ${errorText}`);
          return;
        }

        const response = (await res.json()) as BatchResponse;
        if (!response.success && response.error) {
          setBatchError(response.error);
          return;
        }

        setBatchResult(response);
        // Refresh trip list after batch processing
        fetchTrips();
      } catch (err) {
        setBatchError(err instanceof Error ? err.message : 'Une erreur inattendue est survenue');
      } finally {
        setIsProcessing(false);
      }
    },
    [fetchTrips]
  );

  const handleProcessPending = useCallback(async () => {
    setIsProcessing(true);
    const toastId = toast.loading(`Traitement de ${stats.pending} trajet(s) en attente...`);
    try {
      const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!.trim();
      const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!.trim();

      const res = await fetch(`${supabaseUrl}/functions/v1/batch-match-trips`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${anonKey}`,
          apikey: anonKey,
        },
        body: JSON.stringify({ reprocess_failed: true, limit: 500 }),
      });

      if (!res.ok) {
        const errorText = await res.text();
        toast.error(`Erreur HTTP ${res.status}: ${errorText}`, { id: toastId });
        return;
      }

      const response = (await res.json()) as BatchResponse;
      if (!response.success && response.error) {
        toast.error(response.error, { id: toastId });
        return;
      }

      const s = response.summary;
      if (s.total_requested === 0) {
        toast.info('Aucun trajet en attente à traiter.', { id: toastId });
      } else {
        toast.success(
          `${s.matched} apparié(s), ${s.failed} échoué(s), ${s.skipped} ignoré(s) — ${s.duration_seconds}s`,
          { id: toastId }
        );
      }
      fetchTrips();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Erreur inattendue', { id: toastId });
    } finally {
      setIsProcessing(false);
    }
  }, [fetchTrips, stats.pending]);

  const openDialog = useCallback((mode: 'failed' | 'all') => {
    setDialogMode(mode);
    setBatchResult(null);
    setBatchError(null);
    setShowDialog(true);
  }, []);

  const startProcessing = useCallback(() => {
    handleReprocess(dialogMode);
  }, [dialogMode, handleReprocess]);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Kilométrage</h1>
        <p className="text-muted-foreground">
          Gérer l'appariement des itinéraires et le suivi du kilométrage
        </p>
      </div>

      {/* Route Matching Card */}
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <Car className="h-5 w-5" />
            Appariement des itinéraires
          </CardTitle>
          <CardDescription>
            Apparier les traces GPS des trajets aux routes réelles via OSRM pour un calcul précis du kilométrage.
            Les trajets sont automatiquement appariés après la fin du quart, mais vous pouvez retraiter
            les trajets échoués ou tous les trajets ici.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="flex flex-wrap gap-3">
            <Button
              onClick={handleProcessPending}
              disabled={isProcessing || stats.pending === 0}
            >
              {isProcessing ? (
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
              ) : (
                <Play className="h-4 w-4 mr-2" />
              )}
              Traiter les en attente ({stats.pending})
            </Button>
            <Button
              variant="outline"
              onClick={() => openDialog('failed')}
              disabled={isProcessing}
            >
              <RefreshCw className="h-4 w-4 mr-2" />
              Retraiter les trajets échoués
            </Button>
            <Button
              variant="outline"
              onClick={() => openDialog('all')}
              disabled={isProcessing}
            >
              <RefreshCw className="h-4 w-4 mr-2" />
              Retraiter tous les trajets
            </Button>
          </div>
        </CardContent>
      </Card>

      {/* Transport Mode Filter */}
      <div className="grid grid-cols-3 gap-4">
        <Card
          className={`cursor-pointer hover:ring-2 hover:ring-primary/20 ${modeFilter === 'all' ? 'ring-2 ring-primary' : ''}`}
          onClick={() => setModeFilter('all')}
        >
          <CardContent className="pt-4 pb-3 text-center">
            <p className="text-2xl font-bold">{stats.total}</p>
            <p className="text-xs text-muted-foreground">Tous les trajets</p>
          </CardContent>
        </Card>
        <Card
          className={`cursor-pointer hover:ring-2 hover:ring-blue-500/20 ${modeFilter === 'driving' ? 'ring-2 ring-blue-500' : ''}`}
          onClick={() => setModeFilter('driving')}
        >
          <CardContent className="pt-4 pb-3 text-center">
            <div className="flex items-center justify-center gap-1.5 mb-0.5">
              <Car className="h-4 w-4 text-blue-600" />
              <p className="text-2xl font-bold text-blue-600">{stats.driving}</p>
            </div>
            <p className="text-xs text-muted-foreground">Auto</p>
          </CardContent>
        </Card>
        <Card
          className={`cursor-pointer hover:ring-2 hover:ring-orange-500/20 ${modeFilter === 'walking' ? 'ring-2 ring-orange-500' : ''}`}
          onClick={() => setModeFilter('walking')}
        >
          <CardContent className="pt-4 pb-3 text-center">
            <div className="flex items-center justify-center gap-1.5 mb-0.5">
              <Footprints className="h-4 w-4 text-orange-600" />
              <p className="text-2xl font-bold text-orange-600">{stats.walking}</p>
            </div>
            <p className="text-xs text-muted-foreground">À pied</p>
          </CardContent>
        </Card>
      </div>

      {/* Match Status Stats */}
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-5">
        <Card className="cursor-pointer hover:ring-2 hover:ring-primary/20" onClick={() => setStatusFilter('all')}>
          <CardContent className="pt-4 pb-3 text-center">
            <p className="text-2xl font-bold">{stats.total}</p>
            <p className="text-xs text-muted-foreground">Total trajets</p>
          </CardContent>
        </Card>
        <Card className="cursor-pointer hover:ring-2 hover:ring-green-500/20" onClick={() => setStatusFilter('matched')}>
          <CardContent className="pt-4 pb-3 text-center">
            <p className="text-2xl font-bold text-green-600">{stats.matched}</p>
            <p className="text-xs text-muted-foreground">Appariés</p>
          </CardContent>
        </Card>
        <Card className="cursor-pointer hover:ring-2 hover:ring-yellow-500/20" onClick={() => setStatusFilter('pending')}>
          <CardContent className="pt-4 pb-3 text-center">
            <p className="text-2xl font-bold text-yellow-600">{stats.pending}</p>
            <p className="text-xs text-muted-foreground">En attente</p>
          </CardContent>
        </Card>
        <Card className="cursor-pointer hover:ring-2 hover:ring-gray-500/20" onClick={() => setStatusFilter('failed')}>
          <CardContent className="pt-4 pb-3 text-center">
            <p className="text-2xl font-bold text-gray-500">{stats.failed}</p>
            <p className="text-xs text-muted-foreground">Échoués</p>
          </CardContent>
        </Card>
        <Card className="cursor-pointer hover:ring-2 hover:ring-red-500/20" onClick={() => setStatusFilter('anomalous')}>
          <CardContent className="pt-4 pb-3 text-center">
            <p className="text-2xl font-bold text-red-600">{stats.anomalous}</p>
            <p className="text-xs text-muted-foreground">Anomalies</p>
          </CardContent>
        </Card>
      </div>

      {/* Trips Table */}
      <Card>
        <CardHeader>
          <div className="flex items-center justify-between">
            <CardTitle className="flex items-center gap-2">
              <MapPin className="h-5 w-5" />
              Tous les trajets
              {statusFilter !== 'all' && (
                <Badge variant="secondary" className="ml-2 text-xs">
                  {statusFilter} ({filteredTrips.length})
                  <button
                    onClick={() => setStatusFilter('all')}
                    className="ml-1 hover:text-destructive"
                  >
                    &times;
                  </button>
                </Badge>
              )}
              {modeFilter !== 'all' && (
                <Badge variant="secondary" className="ml-2 text-xs">
                  {modeFilter === 'driving' ? 'Auto' : 'À pied'} ({filteredTrips.length})
                  <button
                    onClick={() => setModeFilter('all')}
                    className="ml-1 hover:text-destructive"
                  >
                    &times;
                  </button>
                </Badge>
              )}
            </CardTitle>
            <Button
              variant="ghost"
              size="sm"
              onClick={fetchTrips}
              disabled={isLoadingTrips}
            >
              <RefreshCw className={`h-4 w-4 ${isLoadingTrips ? 'animate-spin' : ''}`} />
            </Button>
          </div>
        </CardHeader>
        <CardContent>
          {tripsError && (
            <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 mb-4">
              {tripsError}
            </div>
          )}

          {isLoadingTrips ? (
            <div className="animate-pulse space-y-3">
              {Array.from({ length: 5 }).map((_, i) => (
                <div key={i} className="flex gap-4 py-3">
                  <div className="h-4 w-20 rounded bg-slate-200" />
                  <div className="h-4 w-32 rounded bg-slate-200" />
                  <div className="h-4 w-24 rounded bg-slate-200" />
                  <div className="h-4 w-16 rounded bg-slate-200" />
                  <div className="h-4 w-16 rounded bg-slate-200" />
                </div>
              ))}
            </div>
          ) : filteredTrips.length === 0 ? (
            <div className="py-8 text-center text-sm text-muted-foreground">
              {trips.length === 0
                ? 'Aucun trajet trouvé.'
                : `Aucun trajet avec le statut "${statusFilter}".`}
            </div>
          ) : (
            <div className="overflow-x-auto -mx-6">
              <table className="w-full text-sm">
                <thead className="border-b bg-muted/50">
                  <tr>
                    <th className="px-4 py-3 text-center font-medium text-muted-foreground w-12">
                      Mode
                    </th>
                    <th className="px-4 py-3 text-left font-medium text-muted-foreground">
                      Employé
                    </th>
                    <th
                      className="cursor-pointer px-4 py-3 text-left font-medium text-muted-foreground hover:text-foreground"
                      onClick={() => toggleSort('started_at')}
                    >
                      Date {sortIndicator('started_at')}
                    </th>
                    <th className="px-4 py-3 text-left font-medium text-muted-foreground">
                      Itinéraire
                    </th>
                    <th
                      className="cursor-pointer px-4 py-3 text-right font-medium text-muted-foreground hover:text-foreground"
                      onClick={() => toggleSort('distance_km')}
                    >
                      Dist. GPS {sortIndicator('distance_km')}
                    </th>
                    <th
                      className="cursor-pointer px-4 py-3 text-right font-medium text-muted-foreground hover:text-foreground"
                      onClick={() => toggleSort('road_distance_km')}
                    >
                      Dist. route {sortIndicator('road_distance_km')}
                    </th>
                    <th
                      className="cursor-pointer px-4 py-3 text-center font-medium text-muted-foreground hover:text-foreground"
                      onClick={() => toggleSort('match_status')}
                    >
                      Statut {sortIndicator('match_status')}
                    </th>
                    <th className="px-4 py-3 text-right font-medium text-muted-foreground">
                      Confiance
                    </th>
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {filteredTrips.map((trip) => (
                    <TripRow
                      key={trip.id}
                      trip={trip}
                      isExpanded={expandedTrip === trip.id}
                      onToggle={() =>
                        setExpandedTrip(expandedTrip === trip.id ? null : trip.id)
                      }
                      onLocationChanged={fetchTrips}
                    />
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>

      {/* Batch Processing Dialog */}
      <Dialog open={showDialog} onOpenChange={setShowDialog}>
        <DialogContent className="sm:max-w-[480px]">
          <DialogHeader>
            <DialogTitle>
              {dialogMode === 'failed'
                ? 'Retraiter les trajets échoués'
                : 'Retraiter tous les trajets'}
            </DialogTitle>
            <DialogDescription>
              {dialogMode === 'failed'
                ? 'Cela va retenter l\'appariement des itinéraires pour tous les trajets en attente et échoués (jusqu\'à 500).'
                : 'Cela va retraiter TOUS les trajets, y compris ceux déjà appariés (jusqu\'à 500). Les appariements existants seront écrasés.'}
            </DialogDescription>
          </DialogHeader>

          {batchError && (
            <div className="rounded-md bg-red-50 p-3 text-sm text-red-700">
              {batchError}
            </div>
          )}

          {isProcessing && (
            <div className="flex items-center justify-center py-8">
              <div className="text-center space-y-3">
                <Loader2 className="h-8 w-8 animate-spin mx-auto text-blue-500" />
                <p className="text-sm text-muted-foreground">
                  Traitement des trajets en cours... Cela peut prendre quelques minutes.
                </p>
              </div>
            </div>
          )}

          {batchResult && batchResult.summary && (
            <div className="space-y-4">
              <div className="grid grid-cols-2 gap-3">
                <div className="rounded-lg border p-3 text-center">
                  <p className="text-2xl font-bold">{batchResult.summary.total_requested}</p>
                  <p className="text-xs text-muted-foreground">Total trajets</p>
                </div>
                <div className="rounded-lg border p-3 text-center">
                  <p className="text-2xl font-bold">{batchResult.summary.duration_seconds}s</p>
                  <p className="text-xs text-muted-foreground">Durée</p>
                </div>
              </div>

              <div className="flex flex-wrap gap-2">
                <Badge className="bg-green-100 text-green-700 hover:bg-green-100">
                  <CheckCircle className="h-3 w-3 mr-1" />
                  {batchResult.summary.matched} appariés
                </Badge>
                <Badge className="bg-gray-100 text-gray-600 hover:bg-gray-100">
                  {batchResult.summary.skipped} ignorés
                </Badge>
                <Badge className="bg-red-100 text-red-700 hover:bg-red-100">
                  <XCircle className="h-3 w-3 mr-1" />
                  {batchResult.summary.failed} échoués
                </Badge>
                {batchResult.summary.anomalous > 0 && (
                  <Badge className="bg-yellow-100 text-yellow-700 hover:bg-yellow-100">
                    <AlertTriangle className="h-3 w-3 mr-1" />
                    {batchResult.summary.anomalous} anomalies
                  </Badge>
                )}
              </div>

              {batchResult.summary.total_requested === 0 && (
                <p className="text-sm text-muted-foreground text-center py-2">
                  Aucun trajet à traiter.
                </p>
              )}
            </div>
          )}

          <DialogFooter>
            {!batchResult ? (
              <>
                <Button variant="outline" onClick={() => setShowDialog(false)}>
                  Annuler
                </Button>
                <Button onClick={startProcessing} disabled={isProcessing}>
                  {isProcessing ? (
                    <>
                      <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                      Traitement...
                    </>
                  ) : (
                    'Lancer le traitement'
                  )}
                </Button>
              </>
            ) : (
              <Button onClick={() => setShowDialog(false)}>Fermer</Button>
            )}
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

function TripRow({
  trip,
  isExpanded,
  onToggle,
  onLocationChanged,
}: {
  trip: Trip;
  isExpanded: boolean;
  onToggle: () => void;
  onLocationChanged: () => void;
}) {
  const [gpsPoints, setGpsPoints] = useState<TripGpsPoint[]>([]);
  const [isLoadingPoints, setIsLoadingPoints] = useState(false);

  const startLocationName = trip.start_location?.name;
  const endLocationName = trip.end_location?.name;
  const startLoc = startLocationName || formatLocation(trip.start_address, trip.start_latitude, trip.start_longitude);
  const endLoc = endLocationName || formatLocation(trip.end_address, trip.end_latitude, trip.end_longitude);

  // Fetch GPS points when row is expanded
  useEffect(() => {
    if (!isExpanded || gpsPoints.length > 0) return;

    let cancelled = false;
    setIsLoadingPoints(true);

    (async () => {
      const { data } = await supabaseClient
        .from('trip_gps_points')
        .select(`
          sequence_order,
          gps_point:gps_points(latitude, longitude, accuracy, speed, heading, altitude, captured_at)
        `)
        .eq('trip_id', trip.id)
        .order('sequence_order', { ascending: true });

      if (cancelled) return;

      if (data) {
        const points: TripGpsPoint[] = data
          .filter((d: any) => d.gps_point)
          .map((d: any) => ({
            sequence_order: d.sequence_order,
            latitude: d.gps_point.latitude,
            longitude: d.gps_point.longitude,
            accuracy: d.gps_point.accuracy,
            speed: d.gps_point.speed,
            heading: d.gps_point.heading,
            altitude: d.gps_point.altitude,
            captured_at: d.gps_point.captured_at,
          }));
        setGpsPoints(points);
      }
      setIsLoadingPoints(false);
    })();

    return () => { cancelled = true; };
  }, [isExpanded, trip.id, gpsPoints.length]);

  return (
    <>
      <tr
        className="cursor-pointer hover:bg-muted/50 transition-colors"
        onClick={onToggle}
      >
        <td className="px-4 py-3 text-center">
          {trip.transport_mode === 'walking' ? (
            <Footprints className="h-4 w-4 text-orange-500 mx-auto" />
          ) : trip.transport_mode === 'driving' ? (
            <Car className="h-4 w-4 text-blue-500 mx-auto" />
          ) : (
            <Car className="h-4 w-4 text-gray-300 mx-auto" />
          )}
        </td>
        <td className="px-4 py-3 font-medium">
          {(trip.employee as any)?.full_name || (trip.employee as any)?.email || 'Inconnu'}
        </td>
        <td className="px-4 py-3 text-muted-foreground whitespace-nowrap">
          {formatDate(trip.started_at)}
          <br />
          <span className="text-xs">
            {formatTime(trip.started_at)} - {formatTime(trip.ended_at)}
          </span>
        </td>
        <td className="px-4 py-3 max-w-[250px]">
          <div className="flex items-center gap-1 text-xs text-muted-foreground truncate">
            <LocationPickerDropdown
              tripId={trip.id}
              endpoint="start"
              latitude={trip.start_latitude}
              longitude={trip.start_longitude}
              currentLocationId={trip.start_location_id}
              currentLocationName={trip.start_location?.name ?? null}
              displayText={startLoc}
              onLocationChanged={onLocationChanged}
            />
            <ArrowRight className="h-3 w-3 flex-shrink-0" />
            <LocationPickerDropdown
              tripId={trip.id}
              endpoint="end"
              latitude={trip.end_latitude}
              longitude={trip.end_longitude}
              currentLocationId={trip.end_location_id}
              currentLocationName={trip.end_location?.name ?? null}
              displayText={endLoc}
              onLocationChanged={onLocationChanged}
            />
          </div>
        </td>
        <td className="px-4 py-3 text-right tabular-nums">
          {formatDistance(trip.distance_km)}
        </td>
        <td className="px-4 py-3 text-right tabular-nums font-medium">
          {formatDistance(trip.road_distance_km)}
        </td>
        <td className="px-4 py-3 text-center">
          <MatchStatusBadge match_status={trip.match_status} />
        </td>
        <td className="px-4 py-3 text-right tabular-nums text-muted-foreground">
          {formatConfidence(trip.match_confidence)}
        </td>
      </tr>

      {/* Expanded detail row */}
      {isExpanded && (
        <tr className="bg-muted/30">
          <td colSpan={8} className="px-6 py-4">
            <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
              <div className="lg:col-span-2">
                <GoogleTripRouteMap
                  trips={[trip]}
                  gpsPoints={gpsPoints}
                  height={350}
                  showGpsPoints={gpsPoints.length > 0}
                />
                {isLoadingPoints && (
                  <p className="text-xs text-muted-foreground mt-1">Chargement des points GPS...</p>
                )}
              </div>
              <div className="grid grid-cols-2 gap-y-4 text-sm content-start">
                <div>
                  <span className="text-xs text-muted-foreground block">Points GPS</span>
                  <span className="font-medium">{trip.gps_point_count}</span>
                </div>
                <div>
                  <span className="text-xs text-muted-foreground block">Durée</span>
                  <span className="font-medium">{trip.duration_minutes.toFixed(0)} min</span>
                </div>
                <div>
                  <span className="text-xs text-muted-foreground block">Classification</span>

                  <Badge variant="outline" className="text-xs mt-0.5">
                    {trip.classification}
                  </Badge>
                </div>
                <div>
                  <span className="text-xs text-muted-foreground block">Détection</span>
                  <span className="font-medium">{trip.detection_method}</span>
                </div>
                <div>
                  <span className="text-xs text-muted-foreground block">Tentatives d'appariement</span>
                  <span className="font-medium">{trip.match_attempts}</span>
                </div>
                <div>
                  <span className="text-xs text-muted-foreground block">Apparié le</span>
                  <span className="font-medium">
                    {trip.matched_at ? `${formatDate(trip.matched_at)} ${formatTime(trip.matched_at)}` : '—'}
                  </span>
                </div>
                {trip.match_error && (
                  <div className="col-span-2">
                    <span className="text-xs text-muted-foreground block">Erreur</span>
                    <span className="text-sm text-red-600">{trip.match_error}</span>
                  </div>
                )}

                {/* GPS Points Legend */}
                {gpsPoints.length > 0 && (
                  <div className="col-span-2 pt-2 border-t">
                    <span className="text-xs text-muted-foreground block mb-2">Vitesse GPS</span>
                    <div className="flex flex-wrap gap-x-3 gap-y-1">
                      <div className="flex items-center gap-1">
                        <div className="w-2 h-2 rounded-full bg-yellow-500" />
                        <span className="text-[10px] text-muted-foreground">Arrêt</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <div className="w-2 h-2 rounded-full bg-orange-500" />
                        <span className="text-[10px] text-muted-foreground">Marche</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <div className="w-2 h-2 rounded-full bg-blue-500" />
                        <span className="text-[10px] text-muted-foreground">Ville</span>
                      </div>
                      <div className="flex items-center gap-1">
                        <div className="w-2 h-2 rounded-full bg-indigo-500" />
                        <span className="text-[10px] text-muted-foreground">Route</span>
                      </div>
                    </div>
                  </div>
                )}
              </div>
            </div>
          </td>
        </tr>
      )}
    </>
  );
}

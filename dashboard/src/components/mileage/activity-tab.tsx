'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import {
  Loader2,
  Car,
  Footprints,
  MapPin,
  ChevronLeft,
  ChevronRight,
  List,
  Clock,
  ChevronDown,
  ChevronUp,
  ArrowRight,
} from 'lucide-react';
import { supabaseClient } from '@/lib/supabase/client';
import { MatchStatusBadge } from '@/components/trips/match-status-badge';
import { GoogleTripRouteMap } from '@/components/trips/google-trip-route-map';
import { detectTripStops, detectGpsClusters } from '@/lib/utils/detect-trip-stops';
import { LocationPickerDropdown } from '@/components/trips/location-picker-dropdown';
import { StationaryClustersMap } from '@/components/mileage/stationary-clusters-map';
import type { ActivityItem, ActivityTrip, ActivityStop, TripGpsPoint } from '@/types/mileage';
import type { StationaryCluster } from '@/components/mileage/stationary-clusters-map';

type TypeFilter = 'all' | 'trips' | 'stops';
type ViewMode = 'table' | 'timeline';

interface Employee {
  id: string;
  full_name: string;
}

function formatDateISO(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

function formatTime(dateStr: string): string {
  return new Date(dateStr).toLocaleTimeString('fr-CA', {
    hour: '2-digit',
    minute: '2-digit',
  });
}

function formatDuration(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (hours > 0) return `${hours}h ${minutes.toString().padStart(2, '0')}min`;
  return `${minutes} min`;
}

function formatDurationMinutes(minutes: number | string): string {
  const m = Number(minutes) || 0;
  const hours = Math.floor(m / 60);
  const mins = Math.round(m % 60);
  if (hours > 0) return `${hours}h ${mins.toString().padStart(2, '0')}min`;
  return `${mins} min`;
}

function formatDateHeader(dateStr: string): string {
  const date = new Date(dateStr + 'T12:00:00');
  return date.toLocaleDateString('fr-CA', {
    weekday: 'long',
    year: 'numeric',
    month: 'long',
    day: 'numeric',
  });
}

function formatDistance(km: number | string | null): string {
  if (km == null) return '\u2014';
  const n = Number(km);
  if (isNaN(n)) return '\u2014';
  return `${n.toFixed(1)} km`;
}

function formatLocation(address: string | null, lat: number, lng: number): string {
  if (address) return address;
  return `${lat.toFixed(4)}, ${lng.toFixed(4)}`;
}

export function ActivityTab() {
  // Filter state
  const [selectedEmployee, setSelectedEmployee] = useState<string>('');
  const [dateFrom, setDateFrom] = useState<string>(formatDateISO(new Date()));
  const [dateTo, setDateTo] = useState<string>(formatDateISO(new Date()));
  const [isRangeMode, setIsRangeMode] = useState(false);
  const [typeFilter, setTypeFilter] = useState<TypeFilter>('all');
  const [minDuration, setMinDuration] = useState(180);
  const [viewMode, setViewMode] = useState<ViewMode>('table');

  // Data state
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [activities, setActivities] = useState<ActivityItem[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Expand state
  const [expandedId, setExpandedId] = useState<string | null>(null);

  // Fetch employees on mount
  useEffect(() => {
    (async () => {
      const { data } = await supabaseClient
        .from('employee_profiles')
        .select('id, full_name')
        .order('full_name');
      if (data) setEmployees(data as Employee[]);
    })();
  }, []);

  // Effective date range (single day or range)
  const effectiveDateTo = isRangeMode ? dateTo : dateFrom;

  // Fetch activity data
  const fetchActivity = useCallback(async () => {
    if (!selectedEmployee) return;
    setIsLoading(true);
    setError(null);
    try {
      const { data, error: rpcError } = await supabaseClient.rpc(
        'get_employee_activity',
        {
          p_employee_id: selectedEmployee,
          p_date_from: dateFrom,
          p_date_to: effectiveDateTo,
          p_type: typeFilter,
          p_min_duration_seconds: minDuration,
        }
      );

      if (rpcError) {
        setError(rpcError.message);
        setActivities([]);
        return;
      }

      setActivities((data as ActivityItem[]) || []);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Erreur lors du chargement');
      setActivities([]);
    } finally {
      setIsLoading(false);
    }
  }, [selectedEmployee, dateFrom, effectiveDateTo, typeFilter, minDuration]);

  useEffect(() => {
    fetchActivity();
  }, [fetchActivity]);

  // Navigate day by day
  const today = formatDateISO(new Date());
  const navigateDay = (direction: -1 | 1) => {
    const current = new Date(dateFrom + 'T12:00:00');
    current.setDate(current.getDate() + direction);
    const newDate = formatDateISO(current);
    if (direction === 1 && newDate > today) return;
    setDateFrom(newDate);
    if (!isRangeMode) setDateTo(newDate);
  };

  // Stats
  const stats = useMemo(() => {
    const trips = activities.filter((a): a is ActivityTrip => a.activity_type === 'trip');
    const stops = activities.filter((a): a is ActivityStop => a.activity_type === 'stop');
    const totalDistanceGps = trips.reduce((sum, t) => sum + (Number(t.distance_km) || 0), 0);
    const totalDistanceRoute = trips.reduce((sum, t) => sum + (Number(t.road_distance_km) || 0), 0);
    const totalTravelSeconds = trips.reduce((sum, t) => sum + (Number(t.duration_minutes) || 0) * 60, 0);
    const totalStopSeconds = stops.reduce((sum, t) => sum + (Number(t.duration_seconds) || 0), 0);
    return {
      total: activities.length,
      tripCount: trips.length,
      stopCount: stops.length,
      totalDistanceGps,
      totalDistanceRoute,
      totalTravelSeconds,
      totalStopSeconds,
    };
  }, [activities]);

  // Group by day (for range mode + timeline)
  const groupedByDay = useMemo(() => {
    const groups: Record<string, ActivityItem[]> = {};
    for (const item of activities) {
      const day = item.started_at.split('T')[0];
      if (!groups[day]) groups[day] = [];
      groups[day].push(item);
    }
    return Object.entries(groups).sort(([a], [b]) => a.localeCompare(b));
  }, [activities]);

  return (
    <div className="space-y-4">
      {/* Filter bar */}
      <Card>
        <CardContent className="pt-4 pb-4">
          <div className="flex flex-wrap items-end gap-4">
            {/* Employee selector */}
            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-muted-foreground">Employ&eacute;</label>
              <select
                className="border rounded-md px-3 py-1.5 text-sm bg-background"
                value={selectedEmployee}
                onChange={(e) => setSelectedEmployee(e.target.value)}
              >
                <option value="">S&eacute;lectionner un employ&eacute;</option>
                {employees.map((emp) => (
                  <option key={emp.id} value={emp.id}>
                    {emp.full_name || emp.id}
                  </option>
                ))}
              </select>
            </div>

            {/* Date navigation */}
            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-muted-foreground">Date</label>
              <div className="flex items-center gap-1">
                {!isRangeMode && (
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-8 w-8"
                    onClick={() => navigateDay(-1)}
                  >
                    <ChevronLeft className="h-4 w-4" />
                  </Button>
                )}
                <input
                  type="date"
                  className="border rounded-md px-3 py-1.5 text-sm bg-background"
                  value={dateFrom}
                  max={today}
                  onChange={(e) => {
                    setDateFrom(e.target.value);
                    if (!isRangeMode) setDateTo(e.target.value);
                  }}
                />
                {isRangeMode && (
                  <>
                    <span className="text-sm text-muted-foreground px-1">&rarr;</span>
                    <input
                      type="date"
                      className="border rounded-md px-3 py-1.5 text-sm bg-background"
                      value={dateTo}
                      max={today}
                      onChange={(e) => setDateTo(e.target.value)}
                    />
                  </>
                )}
                {!isRangeMode && (
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-8 w-8"
                    onClick={() => navigateDay(1)}
                    disabled={dateFrom >= today}
                  >
                    <ChevronRight className="h-4 w-4" />
                  </Button>
                )}
              </div>
            </div>

            {/* Range toggle */}
            <Button
              variant={isRangeMode ? 'default' : 'outline'}
              size="sm"
              onClick={() => {
                setIsRangeMode(!isRangeMode);
                if (isRangeMode) setDateTo(dateFrom);
              }}
            >
              Plage
            </Button>

            {/* Type filter chips */}
            <div className="flex flex-col gap-1">
              <label className="text-xs font-medium text-muted-foreground">Type</label>
              <div className="flex gap-1">
                {(['all', 'trips', 'stops'] as TypeFilter[]).map((t) => (
                  <Button
                    key={t}
                    variant={typeFilter === t ? 'default' : 'outline'}
                    size="sm"
                    onClick={() => setTypeFilter(t)}
                  >
                    {t === 'all' ? 'Tout' : t === 'trips' ? 'Trajets' : 'Arr\u00eats'}
                  </Button>
                ))}
              </div>
            </div>

            {/* Min duration (only for stops) */}
            {(typeFilter === 'all' || typeFilter === 'stops') && (
              <div className="flex flex-col gap-1">
                <label className="text-xs font-medium text-muted-foreground">
                  Dur&eacute;e min arr&ecirc;ts
                </label>
                <select
                  className="border rounded-md px-3 py-1.5 text-sm bg-background"
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
            )}

            {/* View toggle */}
            <div className="flex flex-col gap-1 ml-auto">
              <label className="text-xs font-medium text-muted-foreground">Vue</label>
              <div className="flex gap-1">
                <Button
                  variant={viewMode === 'table' ? 'default' : 'outline'}
                  size="icon"
                  className="h-8 w-8"
                  onClick={() => setViewMode('table')}
                  title="Tableau"
                >
                  <List className="h-4 w-4" />
                </Button>
                <Button
                  variant={viewMode === 'timeline' ? 'default' : 'outline'}
                  size="icon"
                  className="h-8 w-8"
                  onClick={() => setViewMode('timeline')}
                  title="Timeline"
                >
                  <Clock className="h-4 w-4" />
                </Button>
              </div>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Stats bar */}
      {selectedEmployee && !isLoading && activities.length > 0 && (
        <div className="flex items-center gap-4 text-sm text-muted-foreground px-1">
          <span>{stats.total} &eacute;v&eacute;nements</span>
          <span className="text-blue-600">{stats.tripCount} trajets</span>
          <span className="text-green-600">{stats.stopCount} arr&ecirc;ts</span>
          <span>|</span>
          <span>
            {stats.totalDistanceGps.toFixed(1)} km GPS
            {stats.totalDistanceRoute > 0 &&
              ` / ${stats.totalDistanceRoute.toFixed(1)} km route`}
          </span>
          <span>|</span>
          <span>
            {formatDuration(stats.totalTravelSeconds)} en d&eacute;placement /{' '}
            {formatDuration(stats.totalStopSeconds)} en arr&ecirc;t
          </span>
        </div>
      )}

      {/* Empty state */}
      {!selectedEmployee && (
        <Card>
          <CardContent className="py-12 text-center text-muted-foreground">
            S&eacute;lectionnez un employ&eacute; pour voir son activit&eacute;
          </CardContent>
        </Card>
      )}

      {/* Loading */}
      {isLoading && (
        <div className="flex items-center justify-center py-12">
          <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
        </div>
      )}

      {/* Error */}
      {error && (
        <div className="rounded-md bg-red-50 p-3 text-sm text-red-700">{error}</div>
      )}

      {/* No results */}
      {selectedEmployee && !isLoading && !error && activities.length === 0 && (
        <Card>
          <CardContent className="py-12 text-center text-muted-foreground">
            Aucune activit&eacute; trouv&eacute;e pour le {dateFrom === effectiveDateTo ? dateFrom : `${dateFrom} au ${effectiveDateTo}`}
          </CardContent>
        </Card>
      )}

      {/* Table view */}
      {selectedEmployee && !isLoading && activities.length > 0 && viewMode === 'table' && (
        <ActivityTable
          activities={activities}
          groupedByDay={groupedByDay}
          isRangeMode={isRangeMode}
          expandedId={expandedId}
          onToggleExpand={(id) => setExpandedId(expandedId === id ? null : id)}
          onDataChanged={fetchActivity}
        />
      )}

      {/* Timeline view */}
      {selectedEmployee && !isLoading && activities.length > 0 && viewMode === 'timeline' && (
        <ActivityTimeline
          activities={activities}
          groupedByDay={groupedByDay}
          isRangeMode={isRangeMode}
          expandedId={expandedId}
          onToggleExpand={(id) => setExpandedId(expandedId === id ? null : id)}
          onDataChanged={fetchActivity}
        />
      )}
    </div>
  );
}

// --- Shared expand detail ---

function TripExpandDetail({ trip, onDataChanged }: { trip: ActivityTrip; onDataChanged: () => void }) {
  const [gpsPoints, setGpsPoints] = useState<TripGpsPoint[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  const stops = useMemo(() => detectTripStops(gpsPoints), [gpsPoints]);
  const gpsClusters = useMemo(() => detectGpsClusters(gpsPoints), [gpsPoints]);

  useEffect(() => {
    let cancelled = false;
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
      setIsLoading(false);
    })();
    return () => { cancelled = true; };
  }, [trip.id]);

  const tripForMap = {
    id: trip.id,
    start_latitude: trip.start_latitude,
    start_longitude: trip.start_longitude,
    end_latitude: trip.end_latitude,
    end_longitude: trip.end_longitude,
    match_status: trip.match_status,
    route_geometry: trip.route_geometry,
    distance_km: trip.distance_km,
    road_distance_km: trip.road_distance_km,
    duration_minutes: trip.duration_minutes,
    classification: trip.classification,
    gps_point_count: trip.gps_point_count,
    transport_mode: trip.transport_mode,
  } as any;

  const startLoc = trip.start_location_name || formatLocation(trip.start_address, trip.start_latitude, trip.start_longitude);
  const endLoc = trip.end_location_name || formatLocation(trip.end_address, trip.end_latitude, trip.end_longitude);

  return (
    <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 p-4 bg-muted/30 rounded-lg">
      <div className="lg:col-span-2">
        <GoogleTripRouteMap
          trips={[tripForMap]}
          gpsPoints={gpsPoints}
          stops={stops}
          clusters={gpsClusters}
          height={350}
          showGpsPoints={gpsPoints.length > 0}
        />
        {isLoading && (
          <p className="text-xs text-muted-foreground mt-1">Chargement des points GPS...</p>
        )}
      </div>
      <div className="grid grid-cols-2 gap-y-4 text-sm content-start">
        <div>
          <span className="text-xs text-muted-foreground block">D&eacute;part</span>
          <LocationPickerDropdown
            tripId={trip.id}
            endpoint="start"
            latitude={trip.start_latitude}
            longitude={trip.start_longitude}
            currentLocationId={trip.start_location_id}
            currentLocationName={trip.start_location_name}
            displayText={startLoc}
            onLocationChanged={onDataChanged}
          />
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Arriv&eacute;e</span>
          <LocationPickerDropdown
            tripId={trip.id}
            endpoint="end"
            latitude={trip.end_latitude}
            longitude={trip.end_longitude}
            currentLocationId={trip.end_location_id}
            currentLocationName={trip.end_location_name}
            displayText={endLoc}
            onLocationChanged={onDataChanged}
          />
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Points GPS</span>
          <span className="font-medium">{trip.gps_point_count}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Dur&eacute;e</span>
          <span className="font-medium">{formatDurationMinutes(trip.duration_minutes)}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Distance GPS</span>
          <span className="font-medium">{formatDistance(trip.distance_km)}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Distance route</span>
          <span className="font-medium">{formatDistance(trip.road_distance_km)}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Classification</span>
          <span className="font-medium">{trip.classification}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Statut</span>
          <MatchStatusBadge match_status={trip.match_status} />
        </div>
      </div>
    </div>
  );
}

function StopExpandDetail({ stop }: { stop: ActivityStop }) {
  const cluster: StationaryCluster = {
    id: stop.id,
    shift_id: stop.shift_id,
    employee_id: '',
    employee_name: '',
    centroid_latitude: stop.centroid_latitude,
    centroid_longitude: stop.centroid_longitude,
    centroid_accuracy: stop.centroid_accuracy,
    started_at: stop.started_at,
    ended_at: stop.ended_at,
    duration_seconds: stop.duration_seconds,
    gps_point_count: stop.cluster_gps_point_count,
    matched_location_id: stop.matched_location_id,
    matched_location_name: stop.matched_location_name,
    created_at: stop.started_at,
  };

  return (
    <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 p-4 bg-muted/30 rounded-lg">
      <div className="lg:col-span-2">
        <StationaryClustersMap
          clusters={[cluster]}
          height={350}
          selectedClusterId={stop.id}
        />
      </div>
      <div className="grid grid-cols-2 gap-y-4 text-sm content-start">
        <div className="col-span-2">
          <span className="text-xs text-muted-foreground block">Emplacement</span>
          <span className={`font-medium ${stop.matched_location_name ? 'text-green-600' : 'text-amber-600'}`}>
            {stop.matched_location_name || 'Non associ\u00e9'}
          </span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Dur&eacute;e</span>
          <span className="font-medium">{formatDuration(stop.duration_seconds)}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Points GPS</span>
          <span className="font-medium">{stop.cluster_gps_point_count}</span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Pr&eacute;cision</span>
          <span className="font-medium">
            {stop.centroid_accuracy != null ? `\u00b1${Math.round(stop.centroid_accuracy)}m` : '\u2014'}
          </span>
        </div>
        <div>
          <span className="text-xs text-muted-foreground block">Coordonn&eacute;es</span>
          <span className="font-mono text-xs">
            {stop.centroid_latitude.toFixed(6)}, {stop.centroid_longitude.toFixed(6)}
          </span>
        </div>
      </div>
    </div>
  );
}

// --- Activity row icon helper ---

function ActivityIcon({ item }: { item: ActivityItem }) {
  if (item.activity_type === 'trip') {
    const trip = item as ActivityTrip;
    if (trip.transport_mode === 'walking') return <Footprints className="h-4 w-4 text-orange-500" />;
    if (trip.transport_mode === 'driving') return <Car className="h-4 w-4 text-blue-500" />;
    return <Car className="h-4 w-4 text-gray-300" />;
  }
  const stop = item as ActivityStop;
  if (stop.matched_location_name) return <MapPin className="h-4 w-4 text-green-500" />;
  return <MapPin className="h-4 w-4 text-amber-500" />;
}

function getActivityDetail(item: ActivityItem): string {
  if (item.activity_type === 'trip') {
    const trip = item as ActivityTrip;
    const from = trip.start_location_name || trip.start_address || `${trip.start_latitude.toFixed(4)}, ${trip.start_longitude.toFixed(4)}`;
    const to = trip.end_location_name || trip.end_address || `${trip.end_latitude.toFixed(4)}, ${trip.end_longitude.toFixed(4)}`;
    return `${from} \u2192 ${to}`;
  }
  const stop = item as ActivityStop;
  return stop.matched_location_name || 'Non associ\u00e9';
}

function getActivityDuration(item: ActivityItem): string {
  if (item.activity_type === 'trip') {
    return formatDurationMinutes((item as ActivityTrip).duration_minutes);
  }
  return formatDuration((item as ActivityStop).duration_seconds);
}

// --- Stubs to be replaced in Tasks 4 and 5 ---

interface ActivityViewProps {
  activities: ActivityItem[];
  groupedByDay: [string, ActivityItem[]][];
  isRangeMode: boolean;
  expandedId: string | null;
  onToggleExpand: (id: string) => void;
  onDataChanged: () => void;
}

function ActivityTable({ activities, groupedByDay, isRangeMode, expandedId, onToggleExpand, onDataChanged }: ActivityViewProps) {
  const renderRows = (items: ActivityItem[]) =>
    items.map((item) => (
      <ActivityTableRow
        key={item.id}
        item={item}
        isExpanded={expandedId === item.id}
        onToggle={() => onToggleExpand(item.id)}
        onDataChanged={onDataChanged}
      />
    ));

  return (
    <Card>
      <CardContent className="p-0">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b bg-muted/50">
              <tr>
                <th className="px-4 py-3 text-center font-medium text-muted-foreground w-10">Type</th>
                <th className="px-4 py-3 text-left font-medium text-muted-foreground">D&eacute;but</th>
                <th className="px-4 py-3 text-left font-medium text-muted-foreground">Fin</th>
                <th className="px-4 py-3 text-left font-medium text-muted-foreground">Dur&eacute;e</th>
                <th className="px-4 py-3 text-left font-medium text-muted-foreground">D&eacute;tails</th>
                <th className="px-4 py-3 text-right font-medium text-muted-foreground">Distance</th>
                <th className="px-4 py-3 text-center font-medium text-muted-foreground">Statut</th>
                <th className="px-4 py-3 w-8"></th>
              </tr>
            </thead>
            <tbody className="divide-y">
              {isRangeMode
                ? groupedByDay.map(([day, items]) => (
                    <DayGroup key={day} day={day} colSpan={8}>
                      {renderRows(items)}
                    </DayGroup>
                  ))
                : renderRows(activities)}
            </tbody>
          </table>
        </div>
      </CardContent>
    </Card>
  );
}

function DayGroup({ day, colSpan, children }: { day: string; colSpan: number; children: React.ReactNode }) {
  return (
    <>
      <tr>
        <td colSpan={colSpan} className="px-4 py-2 bg-muted/30">
          <span className="text-xs font-semibold text-muted-foreground capitalize">
            {formatDateHeader(day)}
          </span>
        </td>
      </tr>
      {children}
    </>
  );
}

function ActivityTableRow({
  item,
  isExpanded,
  onToggle,
  onDataChanged,
}: {
  item: ActivityItem;
  isExpanded: boolean;
  onToggle: () => void;
  onDataChanged: () => void;
}) {
  const isTrip = item.activity_type === 'trip';
  const trip = isTrip ? (item as ActivityTrip) : null;
  const stop = !isTrip ? (item as ActivityStop) : null;

  return (
    <>
      <tr
        className="cursor-pointer hover:bg-muted/50 transition-colors"
        onClick={onToggle}
      >
        <td className="px-4 py-3 text-center">
          <ActivityIcon item={item} />
        </td>
        <td className="px-4 py-3 whitespace-nowrap font-medium">
          {formatTime(item.started_at)}
        </td>
        <td className="px-4 py-3 whitespace-nowrap text-muted-foreground">
          {formatTime(item.ended_at)}
        </td>
        <td className="px-4 py-3 whitespace-nowrap tabular-nums">
          {getActivityDuration(item)}
        </td>
        <td className="px-4 py-3 max-w-[350px]">
          {isTrip && trip ? (
            <div className="flex items-center gap-1 text-xs truncate">
              <span className="truncate">{trip.start_location_name || trip.start_address || `${trip.start_latitude.toFixed(4)}, ${trip.start_longitude.toFixed(4)}`}</span>
              <ArrowRight className="h-3 w-3 flex-shrink-0 text-muted-foreground" />
              <span className="truncate">{trip.end_location_name || trip.end_address || `${trip.end_latitude.toFixed(4)}, ${trip.end_longitude.toFixed(4)}`}</span>
            </div>
          ) : stop ? (
            <span className={`text-xs ${stop.matched_location_name ? 'text-green-600 font-medium' : 'text-amber-600'}`}>
              {stop.matched_location_name || 'Non associ\u00e9'}
            </span>
          ) : null}
        </td>
        <td className="px-4 py-3 text-right tabular-nums">
          {isTrip && trip ? formatDistance(trip.road_distance_km ?? trip.distance_km) : '\u2014'}
        </td>
        <td className="px-4 py-3 text-center">
          {isTrip && trip ? (
            <MatchStatusBadge match_status={trip.match_status} />
          ) : (
            <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${
              stop?.matched_location_name
                ? 'bg-green-100 text-green-700'
                : 'bg-amber-100 text-amber-700'
            }`}>
              {stop?.matched_location_name ? 'Associ\u00e9' : 'Non associ\u00e9'}
            </span>
          )}
        </td>
        <td className="px-4 py-3 text-center">
          {isExpanded ? <ChevronUp className="h-4 w-4 text-muted-foreground" /> : <ChevronDown className="h-4 w-4 text-muted-foreground" />}
        </td>
      </tr>

      {isExpanded && (
        <tr>
          <td colSpan={8} className="p-0">
            {isTrip && trip ? (
              <TripExpandDetail trip={trip} onDataChanged={onDataChanged} />
            ) : stop ? (
              <StopExpandDetail stop={stop} />
            ) : null}
          </td>
        </tr>
      )}
    </>
  );
}

function ActivityTimeline({ activities, groupedByDay, isRangeMode, expandedId, onToggleExpand, onDataChanged }: ActivityViewProps) {
  const getColors = (item: ActivityItem) => {
    if (item.activity_type === 'trip') {
      const trip = item as ActivityTrip;
      if (trip.transport_mode === 'walking') return { border: 'border-l-orange-500', dot: 'bg-orange-500' };
      return { border: 'border-l-blue-500', dot: 'bg-blue-500' };
    }
    const stop = item as ActivityStop;
    if (stop.matched_location_name) return { border: 'border-l-green-500', dot: 'bg-green-500' };
    return { border: 'border-l-amber-500', dot: 'bg-amber-500' };
  };

  const renderItem = (item: ActivityItem) => {
    const colors = getColors(item);
    const isExpanded = expandedId === item.id;

    return (
      <div key={item.id} className="relative mb-4">
        {/* Dot on the line */}
        <div className={`absolute left-[-20px] top-4 w-3 h-3 rounded-full border-2 border-background ${colors.dot} z-10`} />

        {/* Card */}
        <Card
          className={`cursor-pointer border-l-4 ${colors.border} hover:shadow-md transition-shadow`}
          onClick={() => onToggleExpand(item.id)}
        >
          <CardContent className="py-3 px-4">
            <div className="flex items-center justify-between gap-4">
              <div className="flex items-center gap-2 min-w-0">
                <ActivityIcon item={item} />
                <span className="font-medium whitespace-nowrap">{formatTime(item.started_at)}</span>
                <span className="text-muted-foreground whitespace-nowrap">&rarr; {formatTime(item.ended_at)}</span>
                <span className="text-muted-foreground text-xs whitespace-nowrap">({getActivityDuration(item)})</span>
              </div>
              <div className="flex items-center gap-3 min-w-0">
                <span className="text-sm truncate max-w-[300px]">{getActivityDetail(item)}</span>
                {item.activity_type === 'trip' && (
                  <span className="text-sm tabular-nums whitespace-nowrap text-muted-foreground">
                    {formatDistance((item as ActivityTrip).road_distance_km ?? (item as ActivityTrip).distance_km)}
                  </span>
                )}
                {isExpanded ? <ChevronUp className="h-4 w-4 flex-shrink-0 text-muted-foreground" /> : <ChevronDown className="h-4 w-4 flex-shrink-0 text-muted-foreground" />}
              </div>
            </div>
          </CardContent>
        </Card>

        {/* Expanded detail */}
        {isExpanded && (
          <div className="mt-2">
            {item.activity_type === 'trip' ? (
              <TripExpandDetail trip={item as ActivityTrip} onDataChanged={onDataChanged} />
            ) : (
              <StopExpandDetail stop={item as ActivityStop} />
            )}
          </div>
        )}
      </div>
    );
  };

  return (
    <div className="relative pl-8">
      {/* Vertical line */}
      <div className="absolute left-3 top-0 bottom-0 w-0.5 bg-border" />

      {isRangeMode
        ? groupedByDay.map(([day, items], idx) => (
            <div key={day}>
              {/* Day separator */}
              <div className={`flex items-center gap-2 mb-3 ${idx > 0 ? 'mt-6' : ''}`}>
                <div className="h-0.5 flex-1 bg-border" />
                <span className="text-sm font-semibold text-muted-foreground capitalize">{formatDateHeader(day)}</span>
                <div className="h-0.5 flex-1 bg-border" />
              </div>
              {items.map(renderItem)}
            </div>
          ))
        : activities.map(renderItem)}
    </div>
  );
}

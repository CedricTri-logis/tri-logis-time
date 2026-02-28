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
  LogIn,
  LogOut,
  AlertTriangle,
  Building2,
  HardHat,
  Truck,
  Home,
  Coffee,
  Fuel,
} from 'lucide-react';
import type { LocationType } from '@/types/location';
import { LOCATION_TYPE_LABELS } from '@/lib/validations/location';
import { supabaseClient } from '@/lib/supabase/client';
import { MatchStatusBadge } from '@/components/trips/match-status-badge';
import { GoogleTripRouteMap } from '@/components/trips/google-trip-route-map';
import { detectTripStops, detectGpsClusters } from '@/lib/utils/detect-trip-stops';
import { LocationPickerDropdown } from '@/components/trips/location-picker-dropdown';
import { StationaryClustersMap } from '@/components/mileage/stationary-clusters-map';
import type { ActivityItem, ActivityTrip, ActivityStop, ActivityClockEvent, TripGpsPoint } from '@/types/mileage';
import type { StationaryCluster } from '@/components/mileage/stationary-clusters-map';

type TypeFilter = 'all' | 'trips' | 'stops';
type ViewMode = 'table' | 'timeline';

// Processed activity item: original item + optional merged clock flags
interface ProcessedActivity {
  item: ActivityItem;
  hasClockIn?: boolean;
  hasClockOut?: boolean;
}

/**
 * Merge clock events into stops only when the clock event time falls
 * within the stop's time range (i.e., the clock happened inside that cluster).
 * Unmatched clock events (outside any stop) stay as standalone rows.
 * Micro-shifts (clock-in + clock-out < 30s apart on same shift) are hidden entirely.
 */
function mergeClockEvents(items: ActivityItem[]): ProcessedActivity[] {
  // Step 1: Detect micro-shifts (< 30s) and collect their shift_ids to hide
  const microShiftIds = new Set<string>();
  const clockInByShift = new Map<string, ActivityClockEvent>();
  const clockOutByShift = new Map<string, ActivityClockEvent>();
  for (const item of items) {
    if (item.activity_type === 'clock_in') clockInByShift.set(item.shift_id, item as ActivityClockEvent);
    if (item.activity_type === 'clock_out') clockOutByShift.set(item.shift_id, item as ActivityClockEvent);
  }
  for (const [shiftId, clockIn] of clockInByShift) {
    const clockOut = clockOutByShift.get(shiftId);
    if (!clockOut) continue;
    const durationMs = new Date(clockOut.started_at).getTime() - new Date(clockIn.started_at).getTime();
    if (durationMs >= 0 && durationMs < 30_000) {
      microShiftIds.add(shiftId);
    }
  }

  // Step 2: Filter out clock events from micro-shifts
  const filtered = items.filter((item) => {
    if (item.activity_type !== 'clock_in' && item.activity_type !== 'clock_out') return true;
    return !microShiftIds.has(item.shift_id);
  });

  // Step 3: Temporal merge of remaining clock events into stops
  const mergedIndices = new Set<number>();
  const clockFlags = new Map<number, { clockIn?: boolean; clockOut?: boolean }>();

  for (let i = 0; i < filtered.length; i++) {
    const item = filtered[i];
    if (item.activity_type !== 'clock_in' && item.activity_type !== 'clock_out') continue;

    const clockTime = new Date(item.started_at).getTime();

    for (let j = 0; j < filtered.length; j++) {
      if (filtered[j].activity_type !== 'stop') continue;
      const stopStart = new Date(filtered[j].started_at).getTime();
      const stopEnd = new Date(filtered[j].ended_at).getTime();
      if (clockTime >= stopStart && clockTime <= stopEnd) {
        mergedIndices.add(i);
        const existing = clockFlags.get(j) || {};
        if (item.activity_type === 'clock_in') existing.clockIn = true;
        if (item.activity_type === 'clock_out') existing.clockOut = true;
        clockFlags.set(j, existing);
        break;
      }
    }
  }

  const result: ProcessedActivity[] = [];
  for (let i = 0; i < filtered.length; i++) {
    if (mergedIndices.has(i)) continue;
    const flags = clockFlags.get(i);
    result.push({
      item: filtered[i],
      hasClockIn: flags?.clockIn,
      hasClockOut: flags?.clockOut,
    });
  }
  return result;
}

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

  // Reverse-geocoded addresses for clock events without a matched location
  const [geocodedAddresses, setGeocodedAddresses] = useState<Record<string, string>>({});

  // Location type lookup (location_id → location_type) for stop icons
  const [locationTypes, setLocationTypes] = useState<Record<string, LocationType>>({});

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

    // Group stop time by location type
    const stopByType: Record<string, number> = {};
    for (const stop of stops) {
      const locType = stop.matched_location_id ? locationTypes[stop.matched_location_id] : undefined;
      const key = locType || '_unmatched';
      stopByType[key] = (stopByType[key] || 0) + (Number(stop.duration_seconds) || 0);
    }

    return {
      total: activities.length,
      tripCount: trips.length,
      stopCount: stops.length,
      totalDistanceGps,
      totalDistanceRoute,
      totalTravelSeconds,
      totalStopSeconds,
      stopByType,
    };
  }, [activities, locationTypes]);

  // Merge clock events into temporally overlapping stops
  const processedActivities = useMemo(() => mergeClockEvents(activities), [activities]);

  // Fetch location types for matched stops
  useEffect(() => {
    const ids = new Set<string>();
    for (const a of activities) {
      if (a.activity_type === 'stop') {
        const stop = a as ActivityStop;
        if (stop.matched_location_id) ids.add(stop.matched_location_id);
      }
    }
    if (ids.size === 0) return;
    (async () => {
      const { data } = await supabaseClient
        .from('locations')
        .select('id, location_type')
        .in('id', Array.from(ids));
      if (data) {
        const map: Record<string, LocationType> = {};
        for (const loc of data) map[loc.id] = loc.location_type as LocationType;
        setLocationTypes(map);
      }
    })();
  }, [activities]);

  // Reverse-geocode all coordinates that have no address (trips, clock events)
  useEffect(() => {
    const toGeocode = new Map<string, { lat: number; lng: number }>();
    const addCoord = (lat: number | null, lng: number | null) => {
      if (lat == null || lng == null) return;
      const key = `${Number(lat).toFixed(5)},${Number(lng).toFixed(5)}`;
      if (!toGeocode.has(key) && !geocodedAddresses[key]) {
        toGeocode.set(key, { lat: Number(lat), lng: Number(lng) });
      }
    };

    for (const pa of processedActivities) {
      const { item } = pa;
      if (item.activity_type === 'trip') {
        const trip = item as ActivityTrip;
        if (!trip.start_location_name && !trip.start_address) addCoord(trip.start_latitude, trip.start_longitude);
        if (!trip.end_location_name && !trip.end_address) addCoord(trip.end_latitude, trip.end_longitude);
      }
      if (item.activity_type === 'clock_in' || item.activity_type === 'clock_out') {
        const ce = item as ActivityClockEvent;
        if (!ce.matched_location_name) addCoord(ce.clock_latitude, ce.clock_longitude);
      }
    }

    if (toGeocode.size === 0) return;
    const apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY;
    if (!apiKey) return;

    Promise.all(
      Array.from(toGeocode.entries()).map(async ([key, { lat, lng }]) => {
        try {
          const res = await fetch(
            `https://maps.googleapis.com/maps/api/geocode/json?latlng=${lat},${lng}&key=${apiKey}&language=fr`
          );
          const data = await res.json();
          if (data.results?.[0]) {
            // Shorten: remove postal code + country suffix
            const full = data.results[0].formatted_address as string;
            const short = full
              .replace(/, [A-Z]\d[A-Z] \d[A-Z]\d, Canada$/, '')
              .replace(/, Canada$/, '');
            return [key, short] as const;
          }
        } catch { /* ignore geocoding errors */ }
        return null;
      })
    ).then(results => {
      const newAddresses: Record<string, string> = {};
      for (const r of results) {
        if (r) newAddresses[r[0]] = r[1];
      }
      if (Object.keys(newAddresses).length > 0) {
        setGeocodedAddresses(prev => ({ ...prev, ...newAddresses }));
      }
    });
  }, [processedActivities]); // eslint-disable-line react-hooks/exhaustive-deps

  // Group by day (for range mode + timeline)
  const processedGroupedByDay = useMemo(() => {
    const groups: Record<string, ProcessedActivity[]> = {};
    for (const pa of processedActivities) {
      const day = pa.item.started_at.split('T')[0];
      if (!groups[day]) groups[day] = [];
      groups[day].push(pa);
    }
    return Object.entries(groups).sort(([a], [b]) => a.localeCompare(b));
  }, [processedActivities]);

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
        <div className="flex flex-wrap items-center gap-4 text-sm text-muted-foreground px-1">
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
          {(stats.totalTravelSeconds > 0 || Object.keys(stats.stopByType).length > 0) && (
            <span className="flex items-center gap-1.5">
              {stats.totalTravelSeconds > 0 && (
                <span
                  className="inline-flex items-center gap-0.5 rounded-md bg-slate-100 px-1.5 py-0.5 text-xs font-medium text-slate-700"
                  title="D&eacute;placement"
                >
                  <Car className="h-3.5 w-3.5 text-blue-500" />
                  {formatDuration(stats.totalTravelSeconds)}
                </span>
              )}
              {Object.entries(stats.stopByType)
                .filter(([, secs]) => secs > 0)
                .sort(([a], [b]) => {
                  if (a === '_unmatched') return 1;
                  if (b === '_unmatched') return -1;
                  return (stats.stopByType[b] || 0) - (stats.stopByType[a] || 0);
                })
                .map(([type, secs]) => {
                  const isUnmatched = type === '_unmatched';
                  const iconEntry = isUnmatched ? null : LOCATION_TYPE_ICON_MAP[type as LocationType];
                  const Icon = iconEntry ? iconEntry.icon : MapPin;
                  const colorClass = iconEntry ? iconEntry.className : 'h-3.5 w-3.5 text-gray-400';
                  const label = isUnmatched ? 'Autre' : (LOCATION_TYPE_LABELS[type as LocationType] || type);
                  return (
                    <span
                      key={type}
                      className="inline-flex items-center gap-0.5 rounded-md bg-slate-100 px-1.5 py-0.5 text-xs font-medium text-slate-700"
                      title={label}
                    >
                      <Icon className={colorClass.replace('h-4 w-4', 'h-3.5 w-3.5')} />
                      {formatDuration(secs)}
                    </span>
                  );
                })}
            </span>
          )}
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
      {selectedEmployee && !isLoading && !error && processedActivities.length === 0 && (
        <Card>
          <CardContent className="py-12 text-center text-muted-foreground">
            Aucune activit&eacute; trouv&eacute;e pour le {dateFrom === effectiveDateTo ? dateFrom : `${dateFrom} au ${effectiveDateTo}`}
          </CardContent>
        </Card>
      )}

      {/* Table view */}
      {selectedEmployee && !isLoading && processedActivities.length > 0 && viewMode === 'table' && (
        <ActivityTable
          activities={processedActivities}
          groupedByDay={processedGroupedByDay}
          isRangeMode={isRangeMode}
          expandedId={expandedId}
          onToggleExpand={(id) => setExpandedId(expandedId === id ? null : id)}
          onDataChanged={fetchActivity}
          geocodedAddresses={geocodedAddresses}
          locationTypes={locationTypes}
        />
      )}

      {/* Timeline view */}
      {selectedEmployee && !isLoading && processedActivities.length > 0 && viewMode === 'timeline' && (
        <ActivityTimeline
          activities={processedActivities}
          groupedByDay={processedGroupedByDay}
          isRangeMode={isRangeMode}
          expandedId={expandedId}
          onToggleExpand={(id) => setExpandedId(expandedId === id ? null : id)}
          onDataChanged={fetchActivity}
          geocodedAddresses={geocodedAddresses}
          locationTypes={locationTypes}
        />
      )}
    </div>
  );
}

// --- Shared expand detail ---

function TripExpandDetail({ trip, onDataChanged, geocodedAddresses }: { trip: ActivityTrip; onDataChanged: () => void; geocodedAddresses: Record<string, string> }) {
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

  const startLoc = resolveLocation(trip.start_location_name, trip.start_address, trip.start_latitude, trip.start_longitude, geocodedAddresses);
  const endLoc = resolveLocation(trip.end_location_name, trip.end_address, trip.end_latitude, trip.end_longitude, geocodedAddresses);

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
        {trip.has_gps_gap && (
          <div className="col-span-2 flex items-center gap-2 p-2 mb-2 bg-amber-50 border border-amber-200 rounded text-xs text-amber-700">
            <AlertTriangle className="h-4 w-4 flex-shrink-0" />
            <span>Trajet sans trace GPS &mdash; aucune donn&eacute;e de parcours disponible</span>
          </div>
        )}
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
        {stop.gps_gap_seconds > 0 && (
          <div className="col-span-2 flex items-center gap-2 p-2 mb-2 bg-amber-50 border border-amber-200 rounded text-xs text-amber-700">
            <AlertTriangle className="h-4 w-4 flex-shrink-0" />
            <span>
              Signal GPS perdu pendant {Math.round(stop.gps_gap_seconds / 60)} min
              ({stop.gps_gap_count} interruption{stop.gps_gap_count > 1 ? 's' : ''})
            </span>
          </div>
        )}
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

const LOCATION_TYPE_ICON_MAP: Record<LocationType, { icon: React.ElementType; className: string }> = {
  office: { icon: Building2, className: 'h-4 w-4 text-blue-500' },
  building: { icon: HardHat, className: 'h-4 w-4 text-amber-500' },
  vendor: { icon: Truck, className: 'h-4 w-4 text-violet-500' },
  home: { icon: Home, className: 'h-4 w-4 text-green-500' },
  cafe_restaurant: { icon: Coffee, className: 'h-4 w-4 text-pink-500' },
  gaz: { icon: Fuel, className: 'h-4 w-4 text-red-500' },
  other: { icon: MapPin, className: 'h-4 w-4 text-gray-500' },
};

function ActivityIcon({ item, locationType }: { item: ActivityItem; locationType?: LocationType }) {
  if (item.activity_type === 'clock_in') return <LogIn className="h-4 w-4 text-emerald-600" />;
  if (item.activity_type === 'clock_out') return <LogOut className="h-4 w-4 text-red-500" />;
  if (item.activity_type === 'trip') {
    const trip = item as ActivityTrip;
    if (trip.transport_mode === 'walking') return <Footprints className="h-4 w-4 text-orange-500" />;
    if (trip.transport_mode === 'driving') return <Car className="h-4 w-4 text-blue-500" />;
    return <Car className="h-4 w-4 text-gray-300" />;
  }
  const stop = item as ActivityStop;
  if (stop.matched_location_name && locationType) {
    const entry = LOCATION_TYPE_ICON_MAP[locationType];
    if (entry) {
      const Icon = entry.icon;
      return <Icon className={entry.className} />;
    }
  }
  if (stop.matched_location_name) return <MapPin className="h-4 w-4 text-green-500" />;
  return <MapPin className="h-4 w-4 text-amber-500" />;
}

/** Resolve a location label: known name > address > geocoded address > never raw coords */
function resolveLocation(
  name: string | null | undefined,
  address: string | null | undefined,
  lat: number,
  lng: number,
  geocodedAddresses: Record<string, string>,
): string {
  if (name) return name;
  if (address) return address;
  const key = `${Number(lat).toFixed(5)},${Number(lng).toFixed(5)}`;
  return geocodedAddresses[key] || `${Number(lat).toFixed(4)}, ${Number(lng).toFixed(4)}`;
}

function getClockLocationLabel(item: ActivityClockEvent, geocodedAddresses?: Record<string, string>): string | null {
  if (item.matched_location_name) return item.matched_location_name;
  if (item.clock_latitude != null && item.clock_longitude != null) {
    return resolveLocation(null, null, item.clock_latitude, item.clock_longitude, geocodedAddresses || {});
  }
  return null;
}

function getActivityDetail(item: ActivityItem, geocodedAddresses: Record<string, string>): string {
  if (item.activity_type === 'clock_in' || item.activity_type === 'clock_out') {
    return getClockLocationLabel(item as ActivityClockEvent, geocodedAddresses) || '';
  }
  if (item.activity_type === 'trip') {
    const trip = item as ActivityTrip;
    const from = resolveLocation(trip.start_location_name, trip.start_address, trip.start_latitude, trip.start_longitude, geocodedAddresses);
    const to = resolveLocation(trip.end_location_name, trip.end_address, trip.end_latitude, trip.end_longitude, geocodedAddresses);
    return `${from} \u2192 ${to}`;
  }
  const stop = item as ActivityStop;
  return stop.matched_location_name || 'Non associ\u00e9';
}

function getActivityDuration(item: ActivityItem): string {
  if (item.activity_type === 'clock_in' || item.activity_type === 'clock_out') return '\u2014';
  if (item.activity_type === 'trip') {
    return formatDurationMinutes((item as ActivityTrip).duration_minutes);
  }
  return formatDuration((item as ActivityStop).duration_seconds);
}

// --- Stubs to be replaced in Tasks 4 and 5 ---

interface ActivityViewProps {
  activities: ProcessedActivity[];
  groupedByDay: [string, ProcessedActivity[]][];
  isRangeMode: boolean;
  expandedId: string | null;
  onToggleExpand: (id: string) => void;
  onDataChanged: () => void;
  geocodedAddresses: Record<string, string>;
  locationTypes: Record<string, LocationType>;
}

function ActivityTable({ activities, groupedByDay, isRangeMode, expandedId, onToggleExpand, onDataChanged, geocodedAddresses, locationTypes }: ActivityViewProps) {
  const renderRows = (items: ProcessedActivity[]) =>
    items.map((pa) => (
      <ActivityTableRow
        key={pa.item.id}
        pa={pa}
        isExpanded={expandedId === pa.item.id}
        onToggle={() => onToggleExpand(pa.item.id)}
        onDataChanged={onDataChanged}
        geocodedAddresses={geocodedAddresses}
        locationTypes={locationTypes}
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
  pa,
  isExpanded,
  onToggle,
  onDataChanged,
  geocodedAddresses,
  locationTypes,
}: {
  pa: ProcessedActivity;
  isExpanded: boolean;
  onToggle: () => void;
  onDataChanged: () => void;
  geocodedAddresses: Record<string, string>;
  locationTypes: Record<string, LocationType>;
}) {
  const { item, hasClockIn, hasClockOut } = pa;
  const isTrip = item.activity_type === 'trip';
  const isStop = item.activity_type === 'stop';
  const isClock = item.activity_type === 'clock_in' || item.activity_type === 'clock_out';
  const trip = isTrip ? (item as ActivityTrip) : null;
  const stop = isStop ? (item as ActivityStop) : null;
  const canExpand = !isClock;
  const stopLocationType = stop?.matched_location_id ? locationTypes[stop.matched_location_id] : undefined;

  return (
    <>
      <tr
        className={`${canExpand ? 'cursor-pointer' : ''} hover:bg-muted/50 transition-colors ${isClock ? 'bg-muted/20' : ''}`}
        onClick={canExpand ? onToggle : undefined}
      >
        <td className="px-4 py-3 text-center">
          <div className="flex items-center justify-center gap-1">
            {hasClockIn && <LogIn className="h-3.5 w-3.5 text-emerald-600" />}
            <ActivityIcon item={item} locationType={stopLocationType} />
            {hasClockOut && <LogOut className="h-3.5 w-3.5 text-red-500" />}
          </div>
        </td>
        <td className="px-4 py-3 whitespace-nowrap font-medium">
          {formatTime(item.started_at)}
        </td>
        <td className="px-4 py-3 whitespace-nowrap text-muted-foreground">
          {isClock ? '\u2014' : formatTime(item.ended_at)}
        </td>
        <td className="px-4 py-3 whitespace-nowrap tabular-nums">
          <div className="flex items-center gap-1">
            {getActivityDuration(item)}
            {isStop && stop && stop.gps_gap_seconds > 0 && (
              <span title={`${Math.round(stop.gps_gap_seconds / 60)} min sans signal GPS (${stop.gps_gap_count} interruption${stop.gps_gap_count > 1 ? 's' : ''})`}>
                <AlertTriangle className="h-3.5 w-3.5 text-amber-500" />
              </span>
            )}
            {isTrip && trip && trip.has_gps_gap && (
              <span title="Trajet sans trace GPS">
                <AlertTriangle className="h-3.5 w-3.5 text-amber-500" />
              </span>
            )}
          </div>
        </td>
        <td className="px-4 py-3 max-w-[350px]">
          {isClock ? (
            <span className="text-xs text-muted-foreground truncate">
              {getClockLocationLabel(item as ActivityClockEvent, geocodedAddresses) || ''}
            </span>
          ) : isTrip && trip ? (
            <div className="flex items-center gap-1 text-xs truncate">
              <span className="truncate">{resolveLocation(trip.start_location_name, trip.start_address, trip.start_latitude, trip.start_longitude, geocodedAddresses)}</span>
              <ArrowRight className="h-3 w-3 flex-shrink-0 text-muted-foreground" />
              <span className="truncate">{resolveLocation(trip.end_location_name, trip.end_address, trip.end_latitude, trip.end_longitude, geocodedAddresses)}</span>
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
          {isClock ? (
            '\u2014'
          ) : isTrip && trip ? (
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
          {canExpand && (
            isExpanded ? <ChevronUp className="h-4 w-4 text-muted-foreground" /> : <ChevronDown className="h-4 w-4 text-muted-foreground" />
          )}
        </td>
      </tr>

      {isExpanded && canExpand && (
        <tr>
          <td colSpan={8} className="p-0">
            {isTrip && trip ? (
              <TripExpandDetail trip={trip} onDataChanged={onDataChanged} geocodedAddresses={geocodedAddresses} />
            ) : stop ? (
              <StopExpandDetail stop={stop} />
            ) : null}
          </td>
        </tr>
      )}
    </>
  );
}

function ActivityTimeline({ activities, groupedByDay, isRangeMode, expandedId, onToggleExpand, onDataChanged, geocodedAddresses, locationTypes }: ActivityViewProps) {
  const getColors = (pa: ProcessedActivity) => {
    const { item } = pa;
    if (item.activity_type === 'clock_in') return { border: 'border-l-emerald-600', dot: 'bg-emerald-600' };
    if (item.activity_type === 'clock_out') return { border: 'border-l-red-500', dot: 'bg-red-500' };
    if (item.activity_type === 'trip') {
      const trip = item as ActivityTrip;
      if (trip.transport_mode === 'walking') return { border: 'border-l-orange-500', dot: 'bg-orange-500' };
      return { border: 'border-l-blue-500', dot: 'bg-blue-500' };
    }
    const stop = item as ActivityStop;
    if (stop.matched_location_name) return { border: 'border-l-green-500', dot: 'bg-green-500' };
    return { border: 'border-l-amber-500', dot: 'bg-amber-500' };
  };

  const renderItem = (pa: ProcessedActivity) => {
    const { item } = pa;
    const colors = getColors(pa);
    const isClock = item.activity_type === 'clock_in' || item.activity_type === 'clock_out';
    const isStop = item.activity_type === 'stop';
    const stop = isStop ? (item as ActivityStop) : null;
    const canExpand = !isClock;
    const isExpanded = canExpand && expandedId === item.id;
    const stopLocationType = stop?.matched_location_id ? locationTypes[stop.matched_location_id] : undefined;

    return (
      <div key={item.id} className="relative mb-4">
        {/* Dot on the line */}
        <div className={`absolute left-[-20px] top-4 w-3 h-3 rounded-full border-2 border-background ${colors.dot} z-10`} />

        {/* Card */}
        <Card
          className={`${canExpand ? 'cursor-pointer' : ''} border-l-4 ${colors.border} hover:shadow-md transition-shadow`}
          onClick={canExpand ? () => onToggleExpand(item.id) : undefined}
        >
          <CardContent className="py-3 px-4">
            <div className="flex items-center justify-between gap-4">
              <div className="flex items-center gap-2 min-w-0">
                <ActivityIcon item={item} locationType={stopLocationType} />
                <span className="font-medium whitespace-nowrap">{formatTime(item.started_at)}</span>
                {!isClock && (
                  <>
                    <span className="text-muted-foreground whitespace-nowrap">&rarr; {formatTime(item.ended_at)}</span>
                    <span className="text-muted-foreground text-xs whitespace-nowrap">({getActivityDuration(item)})</span>
                    {item.activity_type === 'stop' && (item as ActivityStop).gps_gap_seconds > 0 && (
                      <AlertTriangle className="h-3.5 w-3.5 text-amber-500 flex-shrink-0" />
                    )}
                    {item.activity_type === 'trip' && (item as ActivityTrip).has_gps_gap && (
                      <AlertTriangle className="h-3.5 w-3.5 text-amber-500 flex-shrink-0" />
                    )}
                  </>
                )}
              </div>
              <div className="flex items-center gap-3 min-w-0">
                {isClock ? (
                  <span className="text-sm truncate max-w-[300px] text-muted-foreground">
                    {getClockLocationLabel(item as ActivityClockEvent, geocodedAddresses) || ''}
                  </span>
                ) : (
                  <span className="text-sm truncate max-w-[300px]">{getActivityDetail(item, geocodedAddresses)}</span>
                )}
                {item.activity_type === 'trip' && (
                  <span className="text-sm tabular-nums whitespace-nowrap text-muted-foreground">
                    {formatDistance((item as ActivityTrip).road_distance_km ?? (item as ActivityTrip).distance_km)}
                  </span>
                )}
                {canExpand && (
                  isExpanded ? <ChevronUp className="h-4 w-4 flex-shrink-0 text-muted-foreground" /> : <ChevronDown className="h-4 w-4 flex-shrink-0 text-muted-foreground" />
                )}
              </div>
            </div>
          </CardContent>
        </Card>

        {/* Expanded detail */}
        {isExpanded && (
          <div className="mt-2">
            {item.activity_type === 'trip' ? (
              <TripExpandDetail trip={item as ActivityTrip} onDataChanged={onDataChanged} geocodedAddresses={geocodedAddresses} />
            ) : item.activity_type === 'stop' ? (
              <StopExpandDetail stop={item as ActivityStop} />
            ) : null}
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

'use client';

import { useMemo, useState, useEffect } from 'react';
import {
  APIProvider,
  Map,
  useMap,
  AdvancedMarker,
  InfoWindow,
} from '@vis.gl/react-google-maps';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import { DurationCounter } from './duration-counter';
import { getStalenessLevel } from '@/types/monitoring';
import type { MonitoredEmployee, StalenessLevel } from '@/types/monitoring';
import Link from 'next/link';
import { Users } from 'lucide-react';

const DEFAULT_CENTER = { lat: 45.5017, lng: -73.5673 }; // Montreal
const DEFAULT_ZOOM = 12;
const QUEBEC_BOUNDS = {
  minLat: 44.0,
  maxLat: 63.0,
  minLng: -80.0,
  maxLng: -57.0,
};

const markerColors: Record<StalenessLevel, string> = {
  fresh: '#22c55e', // green-500
  stale: '#eab308', // yellow-500
  'very-stale': '#ef4444', // red-500
  unknown: '#94a3b8', // slate-400
};

interface TeamMapProps {
  team: MonitoredEmployee[];
  isLoading?: boolean;
  apiKey?: string;
}

export function GoogleTeamMap({ 
  team, 
  isLoading, 
  apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY || '' 
}: TeamMapProps) {
  const [selectedEmployeeId, setSelectedEmployeeId] = useState<string | null>(null);

  const employeesWithLocation = useMemo(
    () =>
      team.filter(
        (e) =>
          e.shiftStatus === 'on-shift' &&
          e.currentLocation !== null &&
          e.currentLocation.latitude !== null &&
          e.currentLocation.longitude !== null
      ),
    [team]
  );

  const selectedEmployee = useMemo(
    () => team.find(e => e.id === selectedEmployeeId),
    [team, selectedEmployeeId]
  );

  if (isLoading) return <MapSkeleton />;

  return (
    <Card className="overflow-hidden border-slate-200 shadow-xl">
      <CardHeader className="bg-white/80 backdrop-blur-md border-b border-slate-100 py-3">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <div className="bg-blue-50 p-1.5 rounded-lg">
              <Users className="h-4 w-4 text-blue-600" />
            </div>
            <div>
              <CardTitle className="text-sm font-semibold text-slate-900">
                Vue d&apos;ensemble de l&apos;équipe
              </CardTitle>
              <p className="text-[10px] text-slate-500 font-medium">
                {employeesWithLocation.length} employés actifs sur la carte
              </p>
            </div>
          </div>
        </div>
      </CardHeader>

      <CardContent className="p-0 relative">
        <div className="h-[500px] w-full">
          <APIProvider apiKey={apiKey}>
            <Map
              defaultCenter={DEFAULT_CENTER}
              defaultZoom={DEFAULT_ZOOM}
              mapId="team_overview_map"
              disableDefaultUI={true}
              zoomControl={true}
            >
              {employeesWithLocation.map((employee) => (
                <EmployeeMarker 
                  key={employee.id} 
                  employee={employee} 
                  onClick={() => setSelectedEmployeeId(employee.id)}
                />
              ))}

              {selectedEmployee && selectedEmployee.currentLocation && (
                <InfoWindow
                  position={{ 
                    lat: selectedEmployee.currentLocation.latitude, 
                    lng: selectedEmployee.currentLocation.longitude 
                  }}
                  onCloseClick={() => setSelectedEmployeeId(null)}
                >
                   <MarkerPopupContent employee={selectedEmployee} />
                </InfoWindow>
              )}

              <AutoFitBounds employees={employeesWithLocation} />
            </Map>
          </APIProvider>
        </div>
      </CardContent>
    </Card>
  );
}

function EmployeeMarker({ employee, onClick }: { employee: MonitoredEmployee, onClick: () => void }) {
  const location = employee.currentLocation!;
  const staleness = getStalenessLevel(location.capturedAt);
  const color = markerColors[staleness];

  return (
    <AdvancedMarker
      position={{ lat: location.latitude, lng: location.longitude }}
      onClick={onClick}
    >
      <div className="relative group cursor-pointer">
        {/* Shadow/Glow */}
        <div className="absolute -inset-1 rounded-full blur-sm opacity-50 group-hover:opacity-100 transition-opacity" style={{ backgroundColor: color }} />
        
        {/* Main Pin */}
        <div className="relative flex flex-col items-center">
            <div 
              className="w-8 h-8 rounded-full border-2 border-white shadow-lg flex items-center justify-center text-white font-bold text-[10px]"
              style={{ backgroundColor: color }}
            >
              {employee.displayName.charAt(0)}
            </div>
            <div 
              className="w-2 h-2 -mt-1 rotate-45 border-r-2 border-b-2 border-white"
              style={{ backgroundColor: color }}
            />
        </div>

        {/* Name Label (Visible on Hover) */}
        <div className="absolute left-1/2 -translate-x-1/2 -top-8 bg-slate-900 text-white text-[10px] px-2 py-1 rounded whitespace-nowrap opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none shadow-xl">
           {employee.displayName}
        </div>
      </div>
    </AdvancedMarker>
  );
}

function MarkerPopupContent({ employee }: { employee: MonitoredEmployee }) {
  const location = employee.currentLocation!;
  const staleness = getStalenessLevel(location.capturedAt);

  return (
    <div className="p-1 min-w-[200px]">
      <div className="flex items-center gap-3 mb-3">
        <div className="w-10 h-10 rounded-full bg-slate-100 flex items-center justify-center text-slate-600 font-bold text-lg">
          {employee.displayName.charAt(0)}
        </div>
        <div>
           <h4 className="font-bold text-slate-900 text-sm leading-none mb-1">{employee.displayName}</h4>
           <p className="text-[10px] text-slate-500">ID: {employee.employeeId || 'N/A'}</p>
        </div>
      </div>

      <div className="space-y-2 mb-3">
        <div className="flex items-center justify-between text-[11px]">
          <span className="text-slate-500">Service en cours</span>
          <span className="font-semibold text-slate-700">
            {employee.currentShift ? (
              <DurationCounter startTime={employee.currentShift.clockedInAt} format="hm" />
            ) : '---'}
          </span>
        </div>
        <div className="flex items-center justify-between text-[11px]">
          <span className="text-slate-500">Statut GPS</span>
          <StalenessBadge level={staleness} />
        </div>
      </div>

      <Link
        href={`/dashboard/monitoring/${employee.id}`}
        className="block w-full text-center bg-blue-600 hover:bg-blue-700 text-white text-[11px] font-bold py-2 rounded transition-colors"
      >
        Voir les détails du trajet
      </Link>
    </div>
  );
}

function StalenessBadge({ level }: { level: StalenessLevel }) {
  const config: Record<StalenessLevel, { bg: string; text: string; label: string }> = {
    fresh: { bg: 'bg-green-100', text: 'text-green-700', label: 'En direct' },
    stale: { bg: 'bg-yellow-100', text: 'text-yellow-700', label: 'Retard léger' },
    'very-stale': { bg: 'bg-red-100', text: 'text-red-700', label: 'Hors-ligne' },
    unknown: { bg: 'bg-slate-100', text: 'text-slate-600', label: 'Inconnu' },
  };

  const { bg, text, label } = config[level];
  return (
    <span className={`px-1.5 py-0.5 rounded-full text-[9px] font-bold uppercase tracking-wider ${bg} ${text}`}>
      {label}
    </span>
  );
}

function AutoFitBounds({ employees }: { employees: MonitoredEmployee[] }) {
  const map = useMap();
  useEffect(() => {
    if (!map || employees.length === 0) return;

    const employeesInQuebec = employees.filter((employee) => {
      const location = employee.currentLocation;
      if (!location) return false;
      return (
        location.latitude >= QUEBEC_BOUNDS.minLat &&
        location.latitude <= QUEBEC_BOUNDS.maxLat &&
        location.longitude >= QUEBEC_BOUNDS.minLng &&
        location.longitude <= QUEBEC_BOUNDS.maxLng
      );
    });

    if (employeesInQuebec.length === 0) return;

    const bounds = new google.maps.LatLngBounds();
    employeesInQuebec.forEach(e => {
      if (e.currentLocation) {
        bounds.extend({ lat: e.currentLocation.latitude, lng: e.currentLocation.longitude });
      }
    });
    if (employeesInQuebec.length === 1) {
      map.setCenter(bounds.getCenter());
      map.setZoom(15);
    } else {
      map.fitBounds(bounds, { top: 70, right: 70, bottom: 70, left: 70 });
    }
  }, [map, employees]);
  return null;
}

function MapSkeleton() {
  return <Skeleton className="h-[500px] w-full rounded-xl" />;
}

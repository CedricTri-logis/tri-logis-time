'use client';

import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Badge } from '@/components/ui/badge';
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip';
import { Users, CheckCircle, XCircle, AlertCircle } from 'lucide-react';
import type { MileageTripDetail } from '@/types/mileage';
import { resolveGeocodedName, type GeocodeResult } from '@/lib/hooks/use-reverse-geocode';

interface MileageTripRowProps {
  trip: MileageTripDetail;
  disabled: boolean;
  onVehicleChange: (tripId: string, vehicleType: string) => void;
  onRoleChange: (tripId: string, role: string) => void;
  geocodedAddresses?: Map<string, GeocodeResult>;
}

const STATUS_CONFIG = {
  approved: {
    icon: CheckCircle,
    label: 'Approuvé',
    borderColor: 'border-l-green-500',
    iconColor: 'text-green-600',
    bgColor: '',
  },
  rejected: {
    icon: XCircle,
    label: 'Refusé',
    borderColor: 'border-l-red-400',
    iconColor: 'text-red-500',
    bgColor: 'bg-red-50/30',
  },
  needs_review: {
    icon: AlertCircle,
    label: 'À vérifier',
    borderColor: 'border-l-yellow-500',
    iconColor: 'text-yellow-600',
    bgColor: 'bg-yellow-50/30',
  },
} as const;

export function MileageTripRow({ trip, disabled, onVehicleChange, onRoleChange, geocodedAddresses }: MileageTripRowProps) {
  const isResolved = trip.vehicle_type !== null && trip.role !== null;
  const isReimbursable = trip.vehicle_type === 'personal' && trip.role === 'driver' && trip.trip_status === 'approved';
  const isRejected = trip.trip_status === 'rejected';

  const startName = trip.start_address
    || resolveGeocodedName(trip.start_latitude ? Number(trip.start_latitude) : null, trip.start_longitude ? Number(trip.start_longitude) : null, geocodedAddresses, 'Inconnu');
  const endName = trip.end_address
    || resolveGeocodedName(trip.end_latitude ? Number(trip.end_latitude) : null, trip.end_longitude ? Number(trip.end_longitude) : null, geocodedAddresses, 'Inconnu');

  const status = STATUS_CONFIG[trip.trip_status];
  const StatusIcon = status.icon;

  // Border: trip_status takes priority for color
  const borderColor = isRejected
    ? status.borderColor
    : isResolved
      ? isReimbursable ? 'border-l-green-500' : 'border-l-slate-400'
      : 'border-l-yellow-500';

  return (
    <div className={`flex items-center justify-between gap-2 px-3 py-2 rounded-r border-l-[3px] ${borderColor} ${
      isRejected ? 'opacity-60 ' + status.bgColor : ''
    } ${isReimbursable ? 'bg-green-50/50' : ''}`}>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2 text-sm">
          <TooltipProvider>
            <Tooltip>
              <TooltipTrigger>
                <StatusIcon className={`h-4 w-4 shrink-0 ${status.iconColor}`} />
              </TooltipTrigger>
              <TooltipContent>{status.label}</TooltipContent>
            </Tooltip>
          </TooltipProvider>
          <span className={`truncate ${isRejected ? 'line-through text-muted-foreground' : ''}`}>
            {startName} → {endName}
          </span>
          <span className="text-muted-foreground text-xs whitespace-nowrap">
            {trip.distance_km.toFixed(1)} km
          </span>
        </div>
        {trip.carpool_members && trip.carpool_members.length > 0 && (
          <div className="flex items-center gap-1 mt-1 ml-6">
            <Users className="h-3 w-3 text-yellow-600" />
            <span className="text-xs text-yellow-700">
              Covoit. avec {trip.carpool_members.map(m => m.employee_name.split(' ')[0]).join(', ')}
            </span>
          </div>
        )}
        {trip.has_gps_gap && (
          <Badge variant="outline" className="text-xs mt-1 ml-6 text-orange-600 border-orange-300">
            Écart GPS
          </Badge>
        )}
      </div>
      <div className="flex items-center gap-2 shrink-0">
        {isRejected ? (
          <Badge variant="outline" className="text-xs text-red-600 border-red-300">
            Refusé
          </Badge>
        ) : (
          <>
            <Select
              value={trip.vehicle_type ?? ''}
              onValueChange={(v) => onVehicleChange(trip.trip_id, v)}
              disabled={disabled}
            >
              <SelectTrigger className="h-7 w-[110px] text-xs">
                <SelectValue placeholder="Véhicule..." />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="personal">Personnel</SelectItem>
                <SelectItem value="company">Compagnie</SelectItem>
              </SelectContent>
            </Select>
            <Select
              value={trip.role ?? ''}
              onValueChange={(v) => onRoleChange(trip.trip_id, v)}
              disabled={disabled}
            >
              <SelectTrigger className="h-7 w-[110px] text-xs">
                <SelectValue placeholder="Rôle..." />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="driver">Conducteur</SelectItem>
                <SelectItem value="passenger">Passager</SelectItem>
              </SelectContent>
            </Select>
          </>
        )}
      </div>
    </div>
  );
}

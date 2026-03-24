'use client';

import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Badge } from '@/components/ui/badge';
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip';
import { Users } from 'lucide-react';
import type { MileageTripDetail } from '@/types/mileage';

interface MileageTripRowProps {
  trip: MileageTripDetail;
  disabled: boolean;
  onVehicleChange: (tripId: string, vehicleType: string) => void;
  onRoleChange: (tripId: string, role: string) => void;
}

export function MileageTripRow({ trip, disabled, onVehicleChange, onRoleChange }: MileageTripRowProps) {
  const isResolved = trip.vehicle_type !== null && trip.role !== null;
  const isReimbursable = trip.vehicle_type === 'personal' && trip.role === 'driver';

  const borderColor = isResolved
    ? isReimbursable ? 'border-l-green-500' : 'border-l-slate-400'
    : 'border-l-yellow-500';

  return (
    <div className={`flex items-center justify-between gap-2 px-3 py-2 rounded-r border-l-[3px] ${borderColor} ${
      !trip.eligible ? 'opacity-50' : ''
    } ${isReimbursable ? 'bg-green-50/50' : 'bg-white'}`}>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2 text-sm">
          <span className="truncate">
            {trip.start_address ?? 'Inconnu'} → {trip.end_address ?? 'Inconnu'}
          </span>
          <span className="text-muted-foreground text-xs whitespace-nowrap">
            {trip.distance_km.toFixed(1)} km
          </span>
        </div>
        {trip.carpool_members && trip.carpool_members.length > 0 && (
          <div className="flex items-center gap-1 mt-1">
            <Users className="h-3 w-3 text-yellow-600" />
            <span className="text-xs text-yellow-700">
              Covoit. avec {trip.carpool_members.map(m => m.employee_name.split(' ')[0]).join(', ')}
            </span>
          </div>
        )}
        {trip.has_gps_gap && (
          <Badge variant="outline" className="text-xs mt-1 text-orange-600 border-orange-300">
            Écart GPS
          </Badge>
        )}
      </div>
      <div className="flex items-center gap-2 shrink-0">
        {!trip.eligible ? (
          <TooltipProvider>
            <Tooltip>
              <TooltipTrigger>
                <Badge variant="outline" className="text-xs text-muted-foreground">
                  Non éligible
                </Badge>
              </TooltipTrigger>
              <TooltipContent>
                Stops de départ ou d&apos;arrivée non approuvés
              </TooltipContent>
            </Tooltip>
          </TooltipProvider>
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

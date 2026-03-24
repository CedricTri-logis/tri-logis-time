'use client';

import { useState } from 'react';
import { format, parseISO } from 'date-fns';
import { fr } from 'date-fns/locale';
import { Button } from '@/components/ui/button';
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from '@/components/ui/dropdown-menu';
import { ChevronDown, Loader2 } from 'lucide-react';
import { toast } from 'sonner';
import type { PayPeriod } from '@/types/payroll';
import { useMileageApprovalDetail } from '@/lib/hooks/use-mileage-approval';
import {
  updateTripVehicle,
  batchUpdateTripVehicles,
  approveMileage,
  reopenMileageApproval,
  prefillMileageDefaults,
} from '@/lib/api/mileage-approval';
import { MileageTripRow } from './mileage-trip-row';
import { MileageApprovalSummaryFooter } from './mileage-approval-summary';

interface MileageEmployeeDetailProps {
  employeeId: string;
  employeeName: string;
  period: PayPeriod;
  onChanged: () => void;
}

export function MileageEmployeeDetail({
  employeeId,
  employeeName,
  period,
  onChanged,
}: MileageEmployeeDetailProps) {
  const { detail, tripsByDay, isLoading, error, refetch } = useMileageApprovalDetail(
    employeeId,
    period
  );
  const [isSaving, setIsSaving] = useState(false);
  const isApproved = detail?.approval?.status === 'approved';

  const handleVehicleChange = async (tripId: string, vehicleType: string) => {
    setIsSaving(true);
    try {
      await updateTripVehicle(tripId, vehicleType, null);
      await refetch();
      onChanged();
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : 'Erreur lors de la mise à jour');
    } finally {
      setIsSaving(false);
    }
  };

  const handleRoleChange = async (tripId: string, role: string) => {
    setIsSaving(true);
    try {
      await updateTripVehicle(tripId, null, role);
      await refetch();
      onChanged();
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : 'Erreur lors de la mise à jour');
    } finally {
      setIsSaving(false);
    }
  };

  const handleBatchUpdate = async (vehicleType: string | null, role: string | null, tripIds?: string[]) => {
    setIsSaving(true);
    try {
      const ids = tripIds ?? detail!.trips.filter(t => t.trip_status !== 'rejected').map(t => t.trip_id);
      await batchUpdateTripVehicles(ids, vehicleType, role);
      await refetch();
      onChanged();
      toast.success('Trajets mis à jour');
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : 'Erreur lors de la mise à jour en lot');
    } finally {
      setIsSaving(false);
    }
  };

  const handleResetDefaults = async () => {
    setIsSaving(true);
    try {
      // Clear vehicle_type and role on all trips first
      const tripIds = detail!.trips.filter(t => t.trip_status !== 'rejected').map(t => t.trip_id);
      await batchUpdateTripVehicles(tripIds, null, null);
      // Re-prefill
      await prefillMileageDefaults(employeeId, period.start, period.end);
      await refetch();
      onChanged();
      toast.success('Valeurs par défaut réappliquées');
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : 'Erreur lors du reset');
    } finally {
      setIsSaving(false);
    }
  };

  const handleApprove = async () => {
    setIsSaving(true);
    try {
      await approveMileage(employeeId, period.start, period.end);
      await refetch();
      onChanged();
      toast.success('Kilométrage approuvé');
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "Erreur lors de l'approbation");
    } finally {
      setIsSaving(false);
    }
  };

  const handleReopen = async () => {
    setIsSaving(true);
    try {
      await reopenMileageApproval(employeeId, period.start, period.end);
      await refetch();
      onChanged();
      toast.success('Kilométrage rouvert');
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : 'Erreur lors de la réouverture');
    } finally {
      setIsSaving(false);
    }
  };

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-full">
        <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (error) {
    return <div className="p-4 text-red-600 text-sm">{error}</div>;
  }

  if (!detail) return null;

  return (
    <div className="flex flex-col h-full">
      {/* Header */}
      <div className="flex items-center justify-between p-4 border-b">
        <h3 className="font-semibold">{employeeName}</h3>
        <div className="flex gap-2">
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="outline" size="sm" disabled={isApproved || isSaving}>
                Actions en lot <ChevronDown className="h-3 w-3 ml-1" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent>
              <DropdownMenuItem onClick={() => handleBatchUpdate('personal', 'driver')}>
                Tout = Personnel + Conducteur
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => handleBatchUpdate('personal', null)}>
                Tout = Personnel
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => handleBatchUpdate('company', null)}>
                Tout = Compagnie
              </DropdownMenuItem>
              <DropdownMenuItem onClick={handleResetDefaults}>
                Réinitialiser aux valeurs par défaut
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>

      {/* Trip list grouped by day */}
      <div className="flex-1 overflow-y-auto p-4 space-y-4">
        {Array.from(tripsByDay.entries()).map(([date, trips]) => (
          <div key={date}>
            <div className="text-xs font-semibold text-muted-foreground uppercase mb-2">
              {format(parseISO(date), 'EEEE d MMMM', { locale: fr })}
            </div>
            <div className="space-y-1">
              {trips.map((trip) => (
                <MileageTripRow
                  key={trip.trip_id}
                  trip={trip}
                  disabled={isApproved || isSaving}
                  onVehicleChange={handleVehicleChange}
                  onRoleChange={handleRoleChange}
                />
              ))}
            </div>
          </div>
        ))}
        {detail.trips.length === 0 && (
          <div className="text-center text-muted-foreground py-8">
            Aucun trajet en véhicule pour cette période
          </div>
        )}
      </div>

      {/* Summary footer */}
      {detail.trips.length > 0 && (
        <MileageApprovalSummaryFooter
          summary={detail.summary}
          approval={detail.approval}
          onApprove={handleApprove}
          onReopen={handleReopen}
          isSaving={isSaving}
        />
      )}
    </div>
  );
}

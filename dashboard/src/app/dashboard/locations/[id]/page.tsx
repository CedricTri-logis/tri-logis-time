'use client';

import { useCallback, use } from 'react';
import { useRouter } from 'next/navigation';
import { MapPin, ArrowLeft, Trash2, ToggleLeft, ToggleRight } from 'lucide-react';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog';
import { LocationForm } from '@/components/locations/location-form';
import { useLocation, useLocationMutations } from '@/lib/hooks/use-locations';
import { LOCATION_TYPE_COLORS } from '@/lib/utils/segment-colors';
import type { LocationFormInput } from '@/lib/validations/location';
import { format } from 'date-fns';

// Add AlertDialog components if not already present
// For now using basic confirmation

interface LocationDetailPageProps {
  params: Promise<{ id: string }>;
}

export default function LocationDetailPage({ params }: LocationDetailPageProps) {
  const { id } = use(params);
  const router = useRouter();
  const { location, isLoading, error, refetch } = useLocation(id);
  const { updateLocation, deleteLocation, isUpdating, isDeleting } = useLocationMutations();

  const handleUpdate = useCallback(
    async (data: LocationFormInput) => {
      try {
        await updateLocation(id, {
          name: data.name,
          locationType: data.location_type,
          latitude: data.latitude,
          longitude: data.longitude,
          radiusMeters: data.radius_meters,
          address: data.address ?? null,
          notes: data.notes ?? null,
          isActive: data.is_active,
        });
        toast.success('Location updated successfully');
        refetch();
      } catch (error) {
        toast.error('Failed to update location');
      }
    },
    [id, updateLocation, refetch]
  );

  const handleDelete = useCallback(async () => {
    try {
      await deleteLocation(id);
      toast.success('Location deleted successfully');
      router.push('/dashboard/locations');
    } catch (error) {
      toast.error('Failed to delete location');
    }
  }, [id, deleteLocation, router]);

  const handleToggleActive = useCallback(async () => {
    if (!location) return;
    try {
      await updateLocation(id, { isActive: !location.isActive });
      toast.success(
        location.isActive
          ? 'Location deactivated'
          : 'Location activated'
      );
      refetch();
    } catch (error) {
      toast.error('Failed to update location status');
    }
  }, [id, location, updateLocation, refetch]);

  if (isLoading) {
    return <LocationDetailSkeleton />;
  }

  if (error || !location) {
    return (
      <div className="space-y-6">
        <Button variant="ghost" onClick={() => router.push('/dashboard/locations')}>
          <ArrowLeft className="h-4 w-4 mr-2" />
          Back to Locations
        </Button>
        <Card>
          <CardContent className="flex flex-col items-center justify-center py-12">
            <MapPin className="h-12 w-12 text-slate-300 mb-4" />
            <h3 className="text-lg font-medium text-slate-900 mb-1">
              Location not found
            </h3>
            <p className="text-sm text-slate-500">
              {error || 'The location you are looking for does not exist.'}
            </p>
          </CardContent>
        </Card>
      </div>
    );
  }

  const typeConfig = LOCATION_TYPE_COLORS[location.locationType];

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-4">
          <Button
            variant="ghost"
            size="icon"
            onClick={() => router.push('/dashboard/locations')}
          >
            <ArrowLeft className="h-5 w-5" />
          </Button>
          <div
            className="h-12 w-12 rounded-full flex items-center justify-center text-white"
            style={{ backgroundColor: typeConfig.color }}
          >
            <MapPin className="h-6 w-6" />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-2xl font-semibold text-slate-900">
                {location.name}
              </h1>
              {!location.isActive && (
                <span className="text-xs px-2 py-0.5 bg-slate-100 text-slate-500 rounded">
                  Inactive
                </span>
              )}
            </div>
            <div className="flex items-center gap-3 text-sm text-slate-500">
              <span
                className="px-2 py-0.5 rounded"
                style={{
                  backgroundColor: `${typeConfig.color}15`,
                  color: typeConfig.color,
                }}
              >
                {typeConfig.label}
              </span>
              <span>
                Created {format(location.createdAt, 'MMM d, yyyy')}
              </span>
            </div>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <Button
            variant="outline"
            onClick={handleToggleActive}
            disabled={isUpdating}
          >
            {location.isActive ? (
              <>
                <ToggleRight className="h-4 w-4 mr-2" />
                Deactivate
              </>
            ) : (
              <>
                <ToggleLeft className="h-4 w-4 mr-2" />
                Activate
              </>
            )}
          </Button>
          <AlertDialog>
            <AlertDialogTrigger asChild>
              <Button variant="destructive" disabled={isDeleting}>
                <Trash2 className="h-4 w-4 mr-2" />
                Delete
              </Button>
            </AlertDialogTrigger>
            <AlertDialogContent>
              <AlertDialogHeader>
                <AlertDialogTitle>Delete Location</AlertDialogTitle>
                <AlertDialogDescription>
                  Are you sure you want to delete "{location.name}"? This action
                  cannot be undone. Any existing GPS matches to this location will
                  also be deleted.
                </AlertDialogDescription>
              </AlertDialogHeader>
              <AlertDialogFooter>
                <AlertDialogCancel>Cancel</AlertDialogCancel>
                <AlertDialogAction
                  onClick={handleDelete}
                  className="bg-red-600 hover:bg-red-700"
                >
                  Delete
                </AlertDialogAction>
              </AlertDialogFooter>
            </AlertDialogContent>
          </AlertDialog>
        </div>
      </div>

      {/* Edit Form */}
      <LocationForm
        location={location}
        onSubmit={handleUpdate}
        onCancel={() => router.push('/dashboard/locations')}
        isSubmitting={isUpdating}
      />
    </div>
  );
}

function LocationDetailSkeleton() {
  return (
    <div className="space-y-6">
      <div className="flex items-center gap-4">
        <Skeleton className="h-10 w-10 rounded" />
        <Skeleton className="h-12 w-12 rounded-full" />
        <div className="space-y-2">
          <Skeleton className="h-7 w-48" />
          <Skeleton className="h-4 w-32" />
        </div>
      </div>
      <Card>
        <CardContent className="pt-6 space-y-4">
          <Skeleton className="h-10 w-full" />
          <Skeleton className="h-10 w-full" />
          <Skeleton className="h-[300px] w-full" />
        </CardContent>
      </Card>
    </div>
  );
}

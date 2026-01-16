'use client';

import { format } from 'date-fns';
import { Clock, MapPin, Navigation } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Skeleton } from '@/components/ui/skeleton';
import { DurationCounter } from './duration-counter';
import { StalenessIndicator } from './staleness-indicator';
import type { EmployeeCurrentShift } from '@/types/monitoring';

interface ShiftDetailCardProps {
  employeeName: string;
  employeeId: string | null;
  shift: EmployeeCurrentShift | null;
  isLoading?: boolean;
}

/**
 * Card displaying detailed shift information for an employee.
 */
export function ShiftDetailCard({
  employeeName,
  employeeId,
  shift,
  isLoading,
}: ShiftDetailCardProps) {
  if (isLoading) {
    return <ShiftDetailCardSkeleton />;
  }

  if (!shift) {
    return <OffShiftCard employeeName={employeeName} employeeId={employeeId} />;
  }

  return (
    <Card>
      <CardHeader className="pb-3">
        <div className="flex items-center justify-between">
          <CardTitle className="text-lg font-semibold">{employeeName}</CardTitle>
          <Badge className="bg-green-100 text-green-700 border-green-200">
            <span className="mr-1 h-1.5 w-1.5 rounded-full bg-green-500 animate-pulse" />
            On Shift
          </Badge>
        </div>
        {employeeId && (
          <p className="text-sm text-slate-500">Employee ID: {employeeId}</p>
        )}
      </CardHeader>

      <CardContent className="space-y-6">
        {/* Shift Duration */}
        <div className="flex items-center gap-4">
          <div className="flex h-10 w-10 items-center justify-center rounded-full bg-blue-100">
            <Clock className="h-5 w-5 text-blue-600" />
          </div>
          <div>
            <p className="text-sm text-slate-500">Current Shift Duration</p>
            <DurationCounter
              startTime={shift.clockedInAt}
              format="hms"
              className="text-2xl font-bold text-slate-900"
              showPulse
            />
          </div>
        </div>

        {/* Shift Start Time */}
        <div className="grid grid-cols-2 gap-4">
          <div>
            <p className="text-xs text-slate-500 uppercase tracking-wide mb-1">
              Clocked In At
            </p>
            <p className="text-sm font-medium text-slate-900">
              {format(shift.clockedInAt, 'MMM d, yyyy')}
            </p>
            <p className="text-lg font-semibold text-slate-900">
              {format(shift.clockedInAt, 'h:mm a')}
            </p>
          </div>

          <div>
            <p className="text-xs text-slate-500 uppercase tracking-wide mb-1">
              GPS Points
            </p>
            <p className="text-lg font-semibold text-slate-900">
              {shift.gpsPointCount}
            </p>
            <p className="text-sm text-slate-500">recorded</p>
          </div>
        </div>

        {/* Clock-in Location */}
        {shift.clockInLocation && (
          <div className="pt-4 border-t border-slate-100">
            <div className="flex items-center gap-2 mb-2">
              <MapPin className="h-4 w-4 text-slate-400" />
              <p className="text-sm font-medium text-slate-700">Clock-in Location</p>
            </div>
            <p className="text-xs text-slate-500 font-mono">
              {shift.clockInLocation.latitude.toFixed(6)}, {shift.clockInLocation.longitude.toFixed(6)}
            </p>
            {shift.clockInAccuracy && (
              <p className="text-xs text-slate-400 mt-1">
                Accuracy: ~{Math.round(shift.clockInAccuracy)}m
              </p>
            )}
          </div>
        )}

        {/* Current Location */}
        {shift.latestLocation && (
          <div className="pt-4 border-t border-slate-100">
            <div className="flex items-center justify-between mb-2">
              <div className="flex items-center gap-2">
                <Navigation className="h-4 w-4 text-slate-400" />
                <p className="text-sm font-medium text-slate-700">Current Location</p>
              </div>
              <StalenessIndicator
                capturedAt={shift.latestLocation.capturedAt}
                size="sm"
              />
            </div>
            <p className="text-xs text-slate-500 font-mono">
              {shift.latestLocation.latitude.toFixed(6)}, {shift.latestLocation.longitude.toFixed(6)}
            </p>
            {shift.latestLocation.accuracy > 100 && (
              <p className="text-xs text-yellow-600 mt-1">
                Low accuracy: ~{Math.round(shift.latestLocation.accuracy)}m
              </p>
            )}
          </div>
        )}
      </CardContent>
    </Card>
  );
}

interface OffShiftCardProps {
  employeeName: string;
  employeeId: string | null;
}

function OffShiftCard({ employeeName, employeeId }: OffShiftCardProps) {
  return (
    <Card>
      <CardHeader>
        <div className="flex items-center justify-between">
          <CardTitle className="text-lg font-semibold">{employeeName}</CardTitle>
          <Badge variant="outline" className="text-slate-500">
            Off Shift
          </Badge>
        </div>
        {employeeId && (
          <p className="text-sm text-slate-500">Employee ID: {employeeId}</p>
        )}
      </CardHeader>

      <CardContent>
        <div className="flex flex-col items-center justify-center py-8 text-center">
          <div className="rounded-full bg-slate-100 p-4 mb-4">
            <Clock className="h-8 w-8 text-slate-400" />
          </div>
          <p className="text-slate-600 font-medium">No active shift</p>
          <p className="text-sm text-slate-500 mt-1">
            This employee is not currently clocked in.
          </p>
        </div>
      </CardContent>
    </Card>
  );
}

function ShiftDetailCardSkeleton() {
  return (
    <Card>
      <CardHeader className="pb-3">
        <div className="flex items-center justify-between">
          <Skeleton className="h-6 w-40" />
          <Skeleton className="h-5 w-20" />
        </div>
        <Skeleton className="h-4 w-32 mt-2" />
      </CardHeader>

      <CardContent className="space-y-6">
        <div className="flex items-center gap-4">
          <Skeleton className="h-10 w-10 rounded-full" />
          <div>
            <Skeleton className="h-3 w-24 mb-2" />
            <Skeleton className="h-8 w-32" />
          </div>
        </div>

        <div className="grid grid-cols-2 gap-4">
          <div>
            <Skeleton className="h-3 w-20 mb-2" />
            <Skeleton className="h-4 w-28 mb-1" />
            <Skeleton className="h-6 w-20" />
          </div>
          <div>
            <Skeleton className="h-3 w-16 mb-2" />
            <Skeleton className="h-6 w-12" />
          </div>
        </div>
      </CardContent>
    </Card>
  );
}

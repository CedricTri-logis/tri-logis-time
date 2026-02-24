'use client';

import { User, Clock } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Skeleton } from '@/components/ui/skeleton';
import type { ActiveEmployee } from '@/types/dashboard';
import { formatDuration } from '@/types/dashboard';

interface ActivityFeedProps {
  data?: ActiveEmployee[];
  isLoading?: boolean;
}

export function ActivityFeed({ data, isLoading }: ActivityFeedProps) {
  if (isLoading) {
    return <ActivityFeedSkeleton />;
  }

  const activeEmployees = data?.filter((e) => e.is_active) ?? [];

  if (activeEmployees.length === 0) {
    return (
      <Card>
        <CardHeader>
          <CardTitle className="text-base font-semibold">Active Employees</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="flex flex-col items-center justify-center py-8 text-center">
            <User className="h-12 w-12 text-slate-300 mb-4" />
            <p className="text-sm text-slate-500">No employees currently clocked in</p>
          </div>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center justify-between text-base font-semibold">
          Active Employees
          <Badge variant="secondary" className="ml-2">
            {activeEmployees.length} active
          </Badge>
        </CardTitle>
      </CardHeader>
      <CardContent>
        <div className="space-y-4 max-h-[400px] overflow-y-auto">
          {activeEmployees.map((employee) => (
            <div
              key={employee.employee_id}
              className="flex items-center justify-between rounded-lg border border-slate-100 bg-slate-50 p-3"
            >
              <div className="flex items-center gap-3">
                <div className="flex h-10 w-10 items-center justify-center rounded-full bg-green-100">
                  <User className="h-5 w-5 text-green-600" />
                </div>
                <div>
                  <p className="text-sm font-medium text-slate-900">
                    {employee.display_name}
                  </p>
                  <p className="text-xs text-slate-500">{employee.email}</p>
                </div>
              </div>
              <div className="text-right">
                <div className="flex items-center gap-1 text-sm text-green-600">
                  <Clock className="h-3.5 w-3.5" />
                  <span>{formatDuration(employee.today_hours_seconds)}</span>
                </div>
                {employee.current_shift_started_at && (
                  <p className="text-xs text-slate-400">
                    Since {formatShiftStartTime(employee.current_shift_started_at)}
                  </p>
                )}
              </div>
            </div>
          ))}
        </div>
      </CardContent>
    </Card>
  );
}

function formatShiftStartTime(isoString: string): string {
  const date = new Date(isoString);
  return date.toLocaleTimeString('en-US', {
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
  });
}

function ActivityFeedSkeleton() {
  return (
    <Card>
      <CardHeader>
        <Skeleton className="h-5 w-32" />
      </CardHeader>
      <CardContent>
        <div className="space-y-4">
          {Array.from({ length: 5 }).map((_, i) => (
            <div
              key={i}
              className="flex items-center justify-between rounded-lg border border-slate-100 bg-slate-50 p-3"
            >
              <div className="flex items-center gap-3">
                <Skeleton className="h-10 w-10 rounded-full" />
                <div>
                  <Skeleton className="h-4 w-24 mb-1" />
                  <Skeleton className="h-3 w-32" />
                </div>
              </div>
              <div className="text-right">
                <Skeleton className="h-4 w-16 mb-1" />
                <Skeleton className="h-3 w-20" />
              </div>
            </div>
          ))}
        </div>
      </CardContent>
    </Card>
  );
}

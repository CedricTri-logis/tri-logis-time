'use client';

/**
 * Report Schedules Management Page
 * Spec: 013-reports-export - User Story 5
 *
 * Allows administrators to create, view, edit, and manage
 * recurring report schedules.
 */

import { useState } from 'react';
import { format } from 'date-fns';
import {
  Calendar,
  Plus,
  Play,
  Pause,
  Trash2,
  Clock,
  RefreshCw,
  AlertCircle,
  CheckCircle,
  XCircle,
} from 'lucide-react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from '@/components/ui/dialog';
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
import { ScheduleForm } from '@/components/reports/schedule-form';
import { useReportSchedules, CreateScheduleParams } from '@/lib/hooks/use-report-schedules';
import type { ReportSchedule, FREQUENCY_INFO, REPORT_TYPE_INFO } from '@/types/reports';

/**
 * Get status badge variant
 */
function getStatusBadge(status: string) {
  switch (status) {
    case 'active':
      return <Badge className="bg-green-100 text-green-800">Active</Badge>;
    case 'paused':
      return <Badge className="bg-yellow-100 text-yellow-800">Paused</Badge>;
    default:
      return <Badge variant="secondary">{status}</Badge>;
  }
}

/**
 * Get last run status icon
 */
function getLastRunIcon(status?: string) {
  switch (status) {
    case 'success':
      return <CheckCircle className="h-4 w-4 text-green-500" />;
    case 'failed':
      return <XCircle className="h-4 w-4 text-red-500" />;
    default:
      return null;
  }
}

/**
 * Format frequency display
 */
function formatFrequency(schedule: ReportSchedule): string {
  const { frequency, schedule_config } = schedule;

  if (frequency === 'monthly') {
    const day = schedule_config.day_of_month || 1;
    return `Monthly on the ${day}${getOrdinalSuffix(day)}`;
  }

  if (frequency === 'bi_weekly') {
    const dayName = getDayName(schedule_config.day_of_week || 0);
    return `Every other ${dayName}`;
  }

  const dayName = getDayName(schedule_config.day_of_week || 0);
  return `Every ${dayName}`;
}

function getOrdinalSuffix(n: number): string {
  if (n >= 11 && n <= 13) return 'th';
  switch (n % 10) {
    case 1:
      return 'st';
    case 2:
      return 'nd';
    case 3:
      return 'rd';
    default:
      return 'th';
  }
}

function getDayName(day: number): string {
  const days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  return days[day] || 'Day';
}

/**
 * Format report type display
 */
function formatReportType(type: string): string {
  switch (type) {
    case 'timesheet':
      return 'Timesheet';
    case 'activity_summary':
      return 'Activity Summary';
    case 'attendance':
      return 'Attendance';
    default:
      return type;
  }
}

export default function ReportSchedulesPage() {
  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [isCreating, setIsCreating] = useState(false);

  const {
    schedules,
    isLoading,
    error,
    totalCount,
    fetch,
    create,
    pause,
    resume,
    remove,
  } = useReportSchedules();

  /**
   * Handle create schedule
   */
  const handleCreate = async (data: CreateScheduleParams) => {
    setIsCreating(true);
    try {
      const result = await create(data);
      if (result) {
        setIsCreateOpen(false);
      }
    } finally {
      setIsCreating(false);
    }
  };

  /**
   * Handle pause/resume
   */
  const handleToggleStatus = async (schedule: ReportSchedule) => {
    if (schedule.status === 'active') {
      await pause(schedule.id);
    } else {
      await resume(schedule.id);
    }
  };

  /**
   * Handle delete
   */
  const handleDelete = async (scheduleId: string) => {
    await remove(scheduleId);
  };

  return (
    <div className="space-y-6">
      {/* Page header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-900 flex items-center gap-2">
            <Calendar className="h-6 w-6" />
            Scheduled Reports
          </h1>
          <p className="text-sm text-slate-500 mt-1">
            Automate recurring report generation
          </p>
        </div>

        <Dialog open={isCreateOpen} onOpenChange={setIsCreateOpen}>
          <DialogTrigger asChild>
            <Button>
              <Plus className="mr-2 h-4 w-4" />
              New Schedule
            </Button>
          </DialogTrigger>
          <DialogContent className="max-w-md">
            <DialogHeader>
              <DialogTitle>Create Report Schedule</DialogTitle>
              <DialogDescription>
                Set up automatic report generation on a recurring schedule.
              </DialogDescription>
            </DialogHeader>
            <ScheduleForm onSubmit={handleCreate} isLoading={isCreating} mode="create" />
          </DialogContent>
        </Dialog>
      </div>

      {/* Error state */}
      {error && (
        <Alert variant="destructive">
          <AlertCircle className="h-4 w-4" />
          <AlertTitle>Error</AlertTitle>
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}

      {/* Loading state */}
      {isLoading && (
        <Card>
          <CardContent className="flex items-center justify-center py-12">
            <RefreshCw className="h-8 w-8 text-slate-400 animate-spin" />
          </CardContent>
        </Card>
      )}

      {/* Empty state */}
      {!isLoading && schedules.length === 0 && (
        <Card className="border-dashed">
          <CardContent className="flex flex-col items-center justify-center py-12 text-center">
            <Calendar className="h-12 w-12 text-slate-300 mb-4" />
            <h3 className="text-lg font-medium text-slate-900 mb-1">No Schedules</h3>
            <p className="text-sm text-slate-500 max-w-sm mb-4">
              Create a schedule to automatically generate reports on a recurring basis.
            </p>
            <Button onClick={() => setIsCreateOpen(true)}>
              <Plus className="mr-2 h-4 w-4" />
              Create Your First Schedule
            </Button>
          </CardContent>
        </Card>
      )}

      {/* Schedule list */}
      {!isLoading && schedules.length > 0 && (
        <div className="space-y-4">
          {schedules.map((schedule) => (
            <Card key={schedule.id}>
              <CardContent className="p-6">
                <div className="flex items-start justify-between">
                  <div className="space-y-2">
                    <div className="flex items-center gap-3">
                      <h3 className="text-lg font-medium text-slate-900">
                        {schedule.name}
                      </h3>
                      {getStatusBadge(schedule.status)}
                    </div>

                    <div className="flex flex-wrap gap-4 text-sm text-slate-600">
                      <div className="flex items-center gap-1">
                        <span className="font-medium">Type:</span>
                        {formatReportType(schedule.report_type)}
                      </div>
                      <div className="flex items-center gap-1">
                        <Clock className="h-4 w-4" />
                        {formatFrequency(schedule)} at {schedule.schedule_config.time}
                      </div>
                    </div>

                    <div className="flex flex-wrap gap-4 text-sm text-slate-500">
                      <div>
                        <span className="font-medium">Next run:</span>{' '}
                        {schedule.next_run_at
                          ? format(new Date(schedule.next_run_at), 'MMM d, yyyy h:mm a')
                          : 'Not scheduled'}
                      </div>
                      {schedule.last_run_at && (
                        <div className="flex items-center gap-1">
                          <span className="font-medium">Last run:</span>
                          {format(new Date(schedule.last_run_at), 'MMM d, yyyy h:mm a')}
                          {getLastRunIcon(schedule.last_run_status)}
                        </div>
                      )}
                      <div>
                        <span className="font-medium">Runs:</span> {schedule.run_count}
                        {schedule.failure_count > 0 && (
                          <span className="text-red-500"> ({schedule.failure_count} failed)</span>
                        )}
                      </div>
                    </div>
                  </div>

                  <div className="flex items-center gap-2">
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => handleToggleStatus(schedule)}
                    >
                      {schedule.status === 'active' ? (
                        <>
                          <Pause className="mr-1 h-4 w-4" />
                          Pause
                        </>
                      ) : (
                        <>
                          <Play className="mr-1 h-4 w-4" />
                          Resume
                        </>
                      )}
                    </Button>

                    <AlertDialog>
                      <AlertDialogTrigger asChild>
                        <Button variant="outline" size="sm" className="text-red-600 hover:text-red-700">
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      </AlertDialogTrigger>
                      <AlertDialogContent>
                        <AlertDialogHeader>
                          <AlertDialogTitle>Delete Schedule</AlertDialogTitle>
                          <AlertDialogDescription>
                            Are you sure you want to delete &quot;{schedule.name}&quot;? This action
                            cannot be undone.
                          </AlertDialogDescription>
                        </AlertDialogHeader>
                        <AlertDialogFooter>
                          <AlertDialogCancel>Cancel</AlertDialogCancel>
                          <AlertDialogAction
                            onClick={() => handleDelete(schedule.id)}
                            className="bg-red-600 hover:bg-red-700"
                          >
                            Delete
                          </AlertDialogAction>
                        </AlertDialogFooter>
                      </AlertDialogContent>
                    </AlertDialog>
                  </div>
                </div>
              </CardContent>
            </Card>
          ))}
        </div>
      )}

      {/* Help text */}
      <Alert>
        <Calendar className="h-4 w-4" />
        <AlertTitle>About Scheduled Reports</AlertTitle>
        <AlertDescription>
          <ul className="list-disc list-inside mt-2 space-y-1 text-sm">
            <li>Scheduled reports run automatically at the specified time</li>
            <li>Reports cover the previous period (last week/month) based on frequency</li>
            <li>Generated reports appear in your Report History</li>
            <li>You&apos;ll receive a notification when scheduled reports are ready</li>
          </ul>
        </AlertDescription>
      </Alert>
    </div>
  );
}

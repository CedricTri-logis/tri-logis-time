'use client';

/**
 * Schedule Form Component
 * Spec: 013-reports-export
 *
 * Form for creating/editing report schedules with frequency,
 * day/time, and timezone selection.
 */

import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { Clock, Calendar, Globe } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from '@/components/ui/form';
import type {
  ReportType,
  ScheduleFrequency,
  ReportConfig,
  ScheduleConfig,
} from '@/types/reports';

// Form validation schema
const scheduleFormSchema = z.object({
  name: z.string().min(3, 'Name must be at least 3 characters').max(100),
  report_type: z.enum(['timesheet', 'activity_summary', 'attendance']),
  frequency: z.enum(['weekly', 'bi_weekly', 'monthly']),
  day_of_week: z.number().min(0).max(6).optional(),
  day_of_month: z.number().min(1).max(28).optional(),
  time: z.string().regex(/^\d{2}:\d{2}$/, 'Time must be in HH:MM format'),
  timezone: z.string().min(1, 'Timezone is required'),
});

type ScheduleFormValues = z.infer<typeof scheduleFormSchema>;

interface ScheduleFormProps {
  onSubmit: (data: {
    name: string;
    report_type: ReportType;
    config: ReportConfig;
    frequency: ScheduleFrequency;
    schedule_config: ScheduleConfig;
  }) => Promise<void>;
  isLoading?: boolean;
  initialValues?: Partial<ScheduleFormValues>;
  mode?: 'create' | 'edit';
}

// Day of week options
const DAYS_OF_WEEK = [
  { value: 0, label: 'Sunday' },
  { value: 1, label: 'Monday' },
  { value: 2, label: 'Tuesday' },
  { value: 3, label: 'Wednesday' },
  { value: 4, label: 'Thursday' },
  { value: 5, label: 'Friday' },
  { value: 6, label: 'Saturday' },
];

// Day of month options (1-28 to avoid month-end issues)
const DAYS_OF_MONTH = Array.from({ length: 28 }, (_, i) => ({
  value: i + 1,
  label: `${i + 1}${getOrdinalSuffix(i + 1)}`,
}));

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

// Common timezone options
const TIMEZONES = [
  { value: 'America/New_York', label: 'Eastern Time (ET)' },
  { value: 'America/Chicago', label: 'Central Time (CT)' },
  { value: 'America/Denver', label: 'Mountain Time (MT)' },
  { value: 'America/Los_Angeles', label: 'Pacific Time (PT)' },
  { value: 'America/Anchorage', label: 'Alaska Time (AKT)' },
  { value: 'Pacific/Honolulu', label: 'Hawaii Time (HT)' },
  { value: 'UTC', label: 'UTC' },
  { value: 'Europe/London', label: 'London (GMT/BST)' },
  { value: 'Europe/Paris', label: 'Paris (CET/CEST)' },
  { value: 'Asia/Tokyo', label: 'Tokyo (JST)' },
  { value: 'Australia/Sydney', label: 'Sydney (AEST/AEDT)' },
];

// Report type options
const REPORT_TYPES: { value: ReportType; label: string }[] = [
  { value: 'timesheet', label: 'Timesheet Report' },
  { value: 'activity_summary', label: 'Activity Summary' },
  { value: 'attendance', label: 'Attendance Report' },
];

// Frequency options
const FREQUENCIES: { value: ScheduleFrequency; label: string; description: string }[] = [
  { value: 'weekly', label: 'Weekly', description: 'Every week on the selected day' },
  { value: 'bi_weekly', label: 'Bi-weekly', description: 'Every two weeks' },
  { value: 'monthly', label: 'Monthly', description: 'Once per month on the selected day' },
];

export function ScheduleForm({
  onSubmit,
  isLoading = false,
  initialValues,
  mode = 'create',
}: ScheduleFormProps) {
  const [frequency, setFrequency] = useState<ScheduleFrequency>(
    initialValues?.frequency || 'weekly'
  );

  const form = useForm<ScheduleFormValues>({
    resolver: zodResolver(scheduleFormSchema),
    defaultValues: {
      name: initialValues?.name || '',
      report_type: initialValues?.report_type || 'timesheet',
      frequency: initialValues?.frequency || 'weekly',
      day_of_week: initialValues?.day_of_week ?? 1, // Monday
      day_of_month: initialValues?.day_of_month ?? 1,
      time: initialValues?.time || '08:00',
      timezone: initialValues?.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone,
    },
  });

  const handleSubmit = async (values: ScheduleFormValues) => {
    // Build schedule config
    const schedule_config: ScheduleConfig = {
      time: values.time,
      timezone: values.timezone,
    };

    if (values.frequency === 'monthly') {
      schedule_config.day_of_month = values.day_of_month;
    } else {
      schedule_config.day_of_week = values.day_of_week as 0 | 1 | 2 | 3 | 4 | 5 | 6;
    }

    // Build default report config (last period)
    const config: ReportConfig = {
      date_range: {
        preset: values.frequency === 'weekly' ? 'last_week' : 'last_month',
      },
      employee_filter: 'all',
      format: 'pdf',
    };

    await onSubmit({
      name: values.name,
      report_type: values.report_type as ReportType,
      config,
      frequency: values.frequency,
      schedule_config,
    });
  };

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit(handleSubmit)} className="space-y-6">
        {/* Schedule Name */}
        <FormField
          control={form.control}
          name="name"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Schedule Name</FormLabel>
              <FormControl>
                <Input placeholder="Weekly Timesheet Report" {...field} />
              </FormControl>
              <FormDescription>A descriptive name for this schedule</FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        {/* Report Type */}
        <FormField
          control={form.control}
          name="report_type"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Report Type</FormLabel>
              <Select onValueChange={field.onChange} defaultValue={field.value}>
                <FormControl>
                  <SelectTrigger>
                    <SelectValue placeholder="Select report type" />
                  </SelectTrigger>
                </FormControl>
                <SelectContent>
                  {REPORT_TYPES.map((type) => (
                    <SelectItem key={type.value} value={type.value}>
                      {type.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <FormMessage />
            </FormItem>
          )}
        />

        {/* Frequency */}
        <FormField
          control={form.control}
          name="frequency"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Frequency</FormLabel>
              <Select
                onValueChange={(value) => {
                  field.onChange(value);
                  setFrequency(value as ScheduleFrequency);
                }}
                defaultValue={field.value}
              >
                <FormControl>
                  <SelectTrigger>
                    <SelectValue placeholder="Select frequency" />
                  </SelectTrigger>
                </FormControl>
                <SelectContent>
                  {FREQUENCIES.map((freq) => (
                    <SelectItem key={freq.value} value={freq.value}>
                      <div>
                        <div>{freq.label}</div>
                        <div className="text-xs text-slate-500">{freq.description}</div>
                      </div>
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <FormMessage />
            </FormItem>
          )}
        />

        {/* Day Selection */}
        {frequency === 'monthly' ? (
          <FormField
            control={form.control}
            name="day_of_month"
            render={({ field }) => (
              <FormItem>
                <FormLabel className="flex items-center gap-2">
                  <Calendar className="h-4 w-4" />
                  Day of Month
                </FormLabel>
                <Select
                  onValueChange={(value) => field.onChange(parseInt(value, 10))}
                  defaultValue={field.value?.toString()}
                >
                  <FormControl>
                    <SelectTrigger>
                      <SelectValue placeholder="Select day" />
                    </SelectTrigger>
                  </FormControl>
                  <SelectContent>
                    {DAYS_OF_MONTH.map((day) => (
                      <SelectItem key={day.value} value={day.value.toString()}>
                        {day.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <FormDescription>Report will run on this day each month</FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />
        ) : (
          <FormField
            control={form.control}
            name="day_of_week"
            render={({ field }) => (
              <FormItem>
                <FormLabel className="flex items-center gap-2">
                  <Calendar className="h-4 w-4" />
                  Day of Week
                </FormLabel>
                <Select
                  onValueChange={(value) => field.onChange(parseInt(value, 10))}
                  defaultValue={field.value?.toString()}
                >
                  <FormControl>
                    <SelectTrigger>
                      <SelectValue placeholder="Select day" />
                    </SelectTrigger>
                  </FormControl>
                  <SelectContent>
                    {DAYS_OF_WEEK.map((day) => (
                      <SelectItem key={day.value} value={day.value.toString()}>
                        {day.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <FormDescription>Report will run on this day each week</FormDescription>
                <FormMessage />
              </FormItem>
            )}
          />
        )}

        {/* Time */}
        <FormField
          control={form.control}
          name="time"
          render={({ field }) => (
            <FormItem>
              <FormLabel className="flex items-center gap-2">
                <Clock className="h-4 w-4" />
                Time
              </FormLabel>
              <FormControl>
                <Input type="time" {...field} />
              </FormControl>
              <FormDescription>Time of day to generate the report</FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        {/* Timezone */}
        <FormField
          control={form.control}
          name="timezone"
          render={({ field }) => (
            <FormItem>
              <FormLabel className="flex items-center gap-2">
                <Globe className="h-4 w-4" />
                Timezone
              </FormLabel>
              <Select onValueChange={field.onChange} defaultValue={field.value}>
                <FormControl>
                  <SelectTrigger>
                    <SelectValue placeholder="Select timezone" />
                  </SelectTrigger>
                </FormControl>
                <SelectContent>
                  {TIMEZONES.map((tz) => (
                    <SelectItem key={tz.value} value={tz.value}>
                      {tz.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <FormMessage />
            </FormItem>
          )}
        />

        {/* Submit Button */}
        <Button type="submit" className="w-full" disabled={isLoading}>
          {isLoading
            ? mode === 'create'
              ? 'Creating Schedule...'
              : 'Saving Changes...'
            : mode === 'create'
              ? 'Create Schedule'
              : 'Save Changes'}
        </Button>
      </form>
    </Form>
  );
}

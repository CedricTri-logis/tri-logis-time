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
  name: z.string().min(3, 'Le nom doit contenir au moins 3 caractères').max(100),
  report_type: z.enum(['timesheet', 'activity_summary', 'attendance']),
  frequency: z.enum(['weekly', 'bi_weekly', 'monthly']),
  day_of_week: z.number().min(0).max(6).optional(),
  day_of_month: z.number().min(1).max(28).optional(),
  time: z.string().regex(/^\d{2}:\d{2}$/, 'L\'heure doit être au format HH:MM'),
  timezone: z.string().min(1, 'Le fuseau horaire est requis'),
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
  { value: 0, label: 'Dimanche' },
  { value: 1, label: 'Lundi' },
  { value: 2, label: 'Mardi' },
  { value: 3, label: 'Mercredi' },
  { value: 4, label: 'Jeudi' },
  { value: 5, label: 'Vendredi' },
  { value: 6, label: 'Samedi' },
];

// Day of month options (1-28 to avoid month-end issues)
const DAYS_OF_MONTH = Array.from({ length: 28 }, (_, i) => ({
  value: i + 1,
  label: i === 0 ? '1er' : `${i + 1}`,
}));

// Common timezone options
const TIMEZONES = [
  { value: 'America/New_York', label: 'Heure de l\'Est (HE)' },
  { value: 'America/Chicago', label: 'Heure du Centre (HC)' },
  { value: 'America/Denver', label: 'Heure des Rocheuses (HR)' },
  { value: 'America/Los_Angeles', label: 'Heure du Pacifique (HP)' },
  { value: 'America/Anchorage', label: 'Heure de l\'Alaska (HA)' },
  { value: 'Pacific/Honolulu', label: 'Heure d\'Hawaï (HH)' },
  { value: 'UTC', label: 'UTC' },
  { value: 'Europe/London', label: 'London (GMT/BST)' },
  { value: 'Europe/Paris', label: 'Paris (CET/CEST)' },
  { value: 'Asia/Tokyo', label: 'Tokyo (JST)' },
  { value: 'Australia/Sydney', label: 'Sydney (AEST/AEDT)' },
];

// Report type options
const REPORT_TYPES: { value: ReportType; label: string }[] = [
  { value: 'timesheet', label: 'Rapport de feuille de temps' },
  { value: 'activity_summary', label: 'Résumé d\'activité' },
  { value: 'attendance', label: 'Rapport de présence' },
];

// Frequency options
const FREQUENCIES: { value: ScheduleFrequency; label: string; description: string }[] = [
  { value: 'weekly', label: 'Hebdomadaire', description: 'Chaque semaine le jour sélectionné' },
  { value: 'bi_weekly', label: 'Bihebdomadaire', description: 'Toutes les deux semaines' },
  { value: 'monthly', label: 'Mensuel', description: 'Une fois par mois le jour sélectionné' },
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
              <FormLabel>Nom de la programmation</FormLabel>
              <FormControl>
                <Input placeholder="Rapport hebdomadaire de feuille de temps" {...field} />
              </FormControl>
              <FormDescription>Un nom descriptif pour cette programmation</FormDescription>
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
              <FormLabel>Type de rapport</FormLabel>
              <Select onValueChange={field.onChange} defaultValue={field.value}>
                <FormControl>
                  <SelectTrigger>
                    <SelectValue placeholder="Sélectionner le type de rapport" />
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
              <FormLabel>Fréquence</FormLabel>
              <Select
                onValueChange={(value) => {
                  field.onChange(value);
                  setFrequency(value as ScheduleFrequency);
                }}
                defaultValue={field.value}
              >
                <FormControl>
                  <SelectTrigger>
                    <SelectValue placeholder="Sélectionner la fréquence" />
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
                  Jour du mois
                </FormLabel>
                <Select
                  onValueChange={(value) => field.onChange(parseInt(value, 10))}
                  defaultValue={field.value?.toString()}
                >
                  <FormControl>
                    <SelectTrigger>
                      <SelectValue placeholder="Sélectionner le jour" />
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
                <FormDescription>Le rapport sera exécuté ce jour chaque mois</FormDescription>
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
                  Jour de la semaine
                </FormLabel>
                <Select
                  onValueChange={(value) => field.onChange(parseInt(value, 10))}
                  defaultValue={field.value?.toString()}
                >
                  <FormControl>
                    <SelectTrigger>
                      <SelectValue placeholder="Sélectionner le jour" />
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
                <FormDescription>Le rapport sera exécuté ce jour chaque semaine</FormDescription>
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
                Heure
              </FormLabel>
              <FormControl>
                <Input type="time" {...field} />
              </FormControl>
              <FormDescription>Heure de la journée pour générer le rapport</FormDescription>
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
                Fuseau horaire
              </FormLabel>
              <Select onValueChange={field.onChange} defaultValue={field.value}>
                <FormControl>
                  <SelectTrigger>
                    <SelectValue placeholder="Sélectionner le fuseau horaire" />
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
              ? 'Création en cours...'
              : 'Enregistrement...'
            : mode === 'create'
              ? 'Créer la programmation'
              : 'Enregistrer les modifications'}
        </Button>
      </form>
    </Form>
  );
}

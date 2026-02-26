'use client';

/**
 * Report Configuration Form Component
 * Spec: 013-reports-export
 *
 * Provides date range selection, employee filtering, and format options
 */

import { useState, useEffect } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { format, subDays, subMonths, startOfWeek, endOfWeek, startOfMonth, endOfMonth } from 'date-fns';
import { CalendarIcon, Users, FileText, Download } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Calendar } from '@/components/ui/calendar';
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from '@/components/ui/form';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from '@/components/ui/popover';
import { Checkbox } from '@/components/ui/checkbox';
import { cn } from '@/lib/utils';
import { reportConfigSchema, type ReportConfigInput, type ReportConfigFormInput } from '@/lib/validations/reports';
import type { ReportFormat, DateRangePreset, EmployeeOption } from '@/types/reports';

interface ReportConfigFormProps {
  onSubmit: (config: ReportConfigInput) => void;
  isLoading?: boolean;
  employees?: EmployeeOption[];
  showEmployeeFilter?: boolean;
  showIncompleteOption?: boolean;
  showGroupByOption?: boolean;
  defaultFormat?: ReportFormat;
  submitLabel?: string;
}

const DATE_PRESETS: { value: DateRangePreset | 'custom'; label: string }[] = [
  { value: 'this_week', label: 'Cette semaine' },
  { value: 'last_week', label: 'Semaine dernière' },
  { value: 'this_month', label: 'Ce mois-ci' },
  { value: 'last_month', label: 'Mois dernier' },
  { value: 'custom', label: 'Plage personnalisée' },
];

export function ReportConfigForm({
  onSubmit,
  isLoading = false,
  employees = [],
  showEmployeeFilter = true,
  showIncompleteOption = false,
  showGroupByOption = false,
  defaultFormat = 'pdf',
  submitLabel = 'Générer le rapport',
}: ReportConfigFormProps) {
  const [datePreset, setDatePreset] = useState<DateRangePreset | 'custom'>('last_month');
  const [dateRange, setDateRange] = useState<{ from: Date; to: Date }>(() => {
    const now = new Date();
    return {
      from: startOfMonth(subMonths(now, 1)),
      to: endOfMonth(subMonths(now, 1)),
    };
  });

  const form = useForm<ReportConfigFormInput>({
    resolver: zodResolver(reportConfigSchema),
    defaultValues: {
      date_range: {
        preset: 'last_month',
      },
      employee_filter: 'all',
      format: defaultFormat,
      options: {
        include_incomplete_shifts: false,
        group_by: 'employee',
      },
    },
  });

  // Update date range when preset changes
  useEffect(() => {
    const now = new Date();
    let from: Date;
    let to: Date;

    switch (datePreset) {
      case 'this_week':
        from = startOfWeek(now, { weekStartsOn: 1 });
        to = endOfWeek(now, { weekStartsOn: 1 });
        break;
      case 'last_week':
        from = startOfWeek(subDays(now, 7), { weekStartsOn: 1 });
        to = endOfWeek(subDays(now, 7), { weekStartsOn: 1 });
        break;
      case 'this_month':
        from = startOfMonth(now);
        to = endOfMonth(now);
        break;
      case 'last_month':
        from = startOfMonth(subMonths(now, 1));
        to = endOfMonth(subMonths(now, 1));
        break;
      case 'custom':
      default:
        return; // Keep current custom range
    }

    setDateRange({ from, to });
    form.setValue('date_range', { preset: datePreset });
  }, [datePreset, form]);

  // Update form when custom date range changes
  useEffect(() => {
    if (datePreset === 'custom') {
      form.setValue('date_range', {
        start: format(dateRange.from, 'yyyy-MM-dd'),
        end: format(dateRange.to, 'yyyy-MM-dd'),
      });
    }
  }, [dateRange, datePreset, form]);

  const handleSubmit = (data: ReportConfigFormInput) => {
    // Ensure date range is properly set
    const finalData: ReportConfigInput = {
      date_range:
        datePreset === 'custom'
          ? {
              start: format(dateRange.from, 'yyyy-MM-dd'),
              end: format(dateRange.to, 'yyyy-MM-dd'),
            }
          : { preset: datePreset as DateRangePreset },
      employee_filter: data.employee_filter ?? 'all',
      format: data.format ?? 'pdf',
      options: data.options ? {
        include_incomplete_shifts: data.options.include_incomplete_shifts ?? false,
        include_gps_summary: data.options.include_gps_summary ?? false,
        group_by: data.options.group_by,
      } : undefined,
    };

    onSubmit(finalData);
  };

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit(handleSubmit)} className="space-y-6">
        {/* Date Range Section */}
        <div className="space-y-4">
          <div className="flex items-center gap-2 text-sm font-medium text-slate-700">
            <CalendarIcon className="h-4 w-4" />
            Plage de dates
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            {/* Preset selector */}
            <FormField
              control={form.control}
              name="date_range"
              render={() => (
                <FormItem>
                  <FormLabel>Période</FormLabel>
                  <Select
                    value={datePreset}
                    onValueChange={(v) => setDatePreset(v as DateRangePreset | 'custom')}
                  >
                    <SelectTrigger>
                      <SelectValue placeholder="Sélectionner une période" />
                    </SelectTrigger>
                    <SelectContent>
                      {DATE_PRESETS.map((preset) => (
                        <SelectItem key={preset.value} value={preset.value}>
                          {preset.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <FormMessage />
                </FormItem>
              )}
            />

            {/* Custom date picker */}
            {datePreset === 'custom' && (
              <FormItem className="flex flex-col">
                <FormLabel>Plage de dates</FormLabel>
                <Popover>
                  <PopoverTrigger asChild>
                    <Button
                      variant="outline"
                      className={cn(
                        'justify-start text-left font-normal',
                        !dateRange && 'text-muted-foreground'
                      )}
                    >
                      <CalendarIcon className="mr-2 h-4 w-4" />
                      {format(dateRange.from, 'MMM d, yyyy')} -{' '}
                      {format(dateRange.to, 'MMM d, yyyy')}
                    </Button>
                  </PopoverTrigger>
                  <PopoverContent className="w-auto p-0" align="start">
                    <Calendar
                      mode="range"
                      selected={{ from: dateRange.from, to: dateRange.to }}
                      onSelect={(range) => {
                        if (range?.from && range?.to) {
                          setDateRange({ from: range.from, to: range.to });
                        }
                      }}
                      numberOfMonths={2}
                    />
                  </PopoverContent>
                </Popover>
              </FormItem>
            )}
          </div>

          {/* Display selected range */}
          <div className="text-sm text-slate-500">
            Sélection : {format(dateRange.from, 'MMMM d, yyyy')} au{' '}
            {format(dateRange.to, 'MMMM d, yyyy')}
          </div>
        </div>

        {/* Employee Filter Section */}
        {showEmployeeFilter && (
          <div className="space-y-4">
            <div className="flex items-center gap-2 text-sm font-medium text-slate-700">
              <Users className="h-4 w-4" />
              Employés
            </div>

            <FormField
              control={form.control}
              name="employee_filter"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Inclure les employés</FormLabel>
                  <Select
                    value={typeof field.value === 'string' ? field.value : 'all'}
                    onValueChange={field.onChange}
                  >
                    <SelectTrigger>
                      <SelectValue placeholder="Sélectionner les employés" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="all">Tous les employés</SelectItem>
                      {employees.map((emp) => (
                        <SelectItem key={emp.id} value={`employee:${emp.id}`}>
                          {emp.full_name}
                          {emp.employee_id && ` (${emp.employee_id})`}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <FormDescription>
                    Choisissez tous les employés ou sélectionnez des individus spécifiques
                  </FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />
          </div>
        )}

        {/* Format Selection */}
        <div className="space-y-4">
          <div className="flex items-center gap-2 text-sm font-medium text-slate-700">
            <FileText className="h-4 w-4" />
            Format d&apos;export
          </div>

          <FormField
            control={form.control}
            name="format"
            render={({ field }) => (
              <FormItem>
                <FormLabel>Format</FormLabel>
                <Select value={field.value} onValueChange={field.onChange}>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="pdf">
                      PDF - Document formaté pour impression
                    </SelectItem>
                    <SelectItem value="csv">
                      CSV - Format tableur pour Excel/Sheets
                    </SelectItem>
                  </SelectContent>
                </Select>
                <FormMessage />
              </FormItem>
            )}
          />
        </div>

        {/* Options Section */}
        {(showIncompleteOption || showGroupByOption) && (
          <div className="space-y-4">
            <div className="text-sm font-medium text-slate-700">Options</div>

            {showIncompleteOption && (
              <FormField
                control={form.control}
                name="options.include_incomplete_shifts"
                render={({ field }) => (
                  <FormItem className="flex flex-row items-start space-x-3 space-y-0 rounded-md border p-4">
                    <FormControl>
                      <Checkbox
                        checked={field.value}
                        onCheckedChange={field.onChange}
                      />
                    </FormControl>
                    <div className="space-y-1 leading-none">
                      <FormLabel>Inclure les quarts incomplets</FormLabel>
                      <FormDescription>
                        Inclure les quarts encore en cours (sans pointage de sortie)
                      </FormDescription>
                    </div>
                  </FormItem>
                )}
              />
            )}

            {showGroupByOption && (
              <FormField
                control={form.control}
                name="options.group_by"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Regrouper par</FormLabel>
                    <Select value={field.value || 'employee'} onValueChange={field.onChange}>
                      <SelectTrigger>
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="employee">Employé</SelectItem>
                        <SelectItem value="date">Date</SelectItem>
                      </SelectContent>
                    </Select>
                    <FormDescription>
                      Comment organiser les données dans le rapport
                    </FormDescription>
                    <FormMessage />
                  </FormItem>
                )}
              />
            )}
          </div>
        )}

        {/* Submit Button */}
        <Button type="submit" disabled={isLoading} className="w-full">
          {isLoading ? (
            <>
              <span className="animate-spin mr-2">⏳</span>
              Génération en cours...
            </>
          ) : (
            <>
              <Download className="mr-2 h-4 w-4" />
              {submitLabel}
            </>
          )}
        </Button>
      </form>
    </Form>
  );
}

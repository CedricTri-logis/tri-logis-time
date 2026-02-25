'use client';

import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { AlertTriangle } from 'lucide-react';
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from '@/components/ui/form';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { employeeEditExtendedSchema, type EmployeeEditExtendedInput } from '@/lib/validations/employee';

interface EmployeeFormProps {
  defaultValues: EmployeeEditExtendedInput;
  onSubmit: (data: EmployeeEditExtendedInput) => Promise<void>;
  isSubmitting?: boolean;
  isDisabled?: boolean;
  showEmailWarning?: boolean;
}

/**
 * Format phone for display: +18195551234 → (819) 555-1234
 */
function formatPhoneDisplay(phone: string | null | undefined): string {
  if (!phone) return '';
  const digits = phone.replace(/\D/g, '');
  // Remove leading 1 for Canadian numbers
  const local = digits.startsWith('1') ? digits.slice(1) : digits;
  if (local.length === 10) {
    return `(${local.slice(0, 3)}) ${local.slice(3, 6)}-${local.slice(6)}`;
  }
  return phone;
}

/**
 * Parse display phone to E.164: (819) 555-1234 → +18195551234
 */
export function parsePhoneToE164(display: string): string | null {
  if (!display.trim()) return null;
  const digits = display.replace(/\D/g, '');
  const local = digits.startsWith('1') ? digits.slice(1) : digits;
  if (local.length === 10) {
    return `+1${local}`;
  }
  return null;
}

export function EmployeeForm({
  defaultValues,
  onSubmit,
  isSubmitting = false,
  isDisabled = false,
  showEmailWarning = false,
}: EmployeeFormProps) {
  const form = useForm<EmployeeEditExtendedInput>({
    resolver: zodResolver(employeeEditExtendedSchema),
    defaultValues: {
      ...defaultValues,
      phone_number: formatPhoneDisplay(defaultValues.phone_number),
    },
  });

  const handleSubmit = form.handleSubmit(async (data) => {
    await onSubmit(data);
  });

  return (
    <Form {...form}>
      <form onSubmit={handleSubmit} className="space-y-6">
        <FormField
          control={form.control}
          name="full_name"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Full Name</FormLabel>
              <FormControl>
                <Input
                  placeholder="Enter full name"
                  {...field}
                  value={field.value ?? ''}
                  disabled={isDisabled}
                />
              </FormControl>
              <FormDescription>
                The display name shown throughout the system.
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="employee_id"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Employee ID</FormLabel>
              <FormControl>
                <Input
                  placeholder="Enter employee ID"
                  {...field}
                  value={field.value ?? ''}
                  disabled={isDisabled}
                />
              </FormControl>
              <FormDescription>
                A unique identifier (letters, numbers, and dashes only).
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="email"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Email</FormLabel>
              <FormControl>
                <Input
                  type="email"
                  placeholder="employee@example.com"
                  {...field}
                  value={field.value ?? ''}
                  disabled={isDisabled}
                />
              </FormControl>
              {showEmailWarning && (
                <div className="flex items-center gap-2 rounded-md bg-amber-50 p-2 text-xs text-amber-800">
                  <AlertTriangle className="h-3 w-3 flex-shrink-0" />
                  Changing the email will change this employee&apos;s login credentials.
                </div>
              )}
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="phone_number"
          render={({ field }) => (
            <FormItem>
              <FormLabel>Phone Number</FormLabel>
              <FormControl>
                <Input
                  type="tel"
                  placeholder="(XXX) XXX-XXXX"
                  {...field}
                  value={field.value ?? ''}
                  disabled={isDisabled}
                />
              </FormControl>
              <FormDescription>
                Canadian format. Used for SMS authentication.
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        {!isDisabled && (
          <div className="flex justify-end">
            <Button type="submit" disabled={isSubmitting}>
              {isSubmitting ? 'Saving...' : 'Save Changes'}
            </Button>
          </div>
        )}
      </form>
    </Form>
  );
}

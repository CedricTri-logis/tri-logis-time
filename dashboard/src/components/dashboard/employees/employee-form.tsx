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
import { PhoneInput } from '@/components/ui/phone-input';
import { Button } from '@/components/ui/button';
import { employeeEditExtendedSchema, type EmployeeEditExtendedInput } from '@/lib/validations/employee';

interface EmployeeFormProps {
  defaultValues: EmployeeEditExtendedInput;
  onSubmit: (data: EmployeeEditExtendedInput) => Promise<void>;
  isSubmitting?: boolean;
  isDisabled?: boolean;
  showEmailWarning?: boolean;
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
    defaultValues,
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
                <PhoneInput
                  value={field.value ?? ''}
                  onChange={field.onChange}
                  onBlur={field.onBlur}
                  disabled={isDisabled}
                  placeholder="(514) 555-1234"
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

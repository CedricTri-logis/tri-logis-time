'use client';

import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
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
import { employeeEditSchema, type EmployeeEditInput } from '@/lib/validations/employee';

interface EmployeeFormProps {
  defaultValues: EmployeeEditInput;
  onSubmit: (data: EmployeeEditInput) => Promise<void>;
  isSubmitting?: boolean;
  isDisabled?: boolean;
}

export function EmployeeForm({
  defaultValues,
  onSubmit,
  isSubmitting = false,
  isDisabled = false,
}: EmployeeFormProps) {
  const form = useForm<EmployeeEditInput>({
    resolver: zodResolver(employeeEditSchema),
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

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
              <FormLabel>Nom complet</FormLabel>
              <FormControl>
                <Input
                  placeholder="Entrer le nom complet"
                  {...field}
                  value={field.value ?? ''}
                  disabled={isDisabled}
                />
              </FormControl>
              <FormDescription>
                Le nom affiché dans tout le système.
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
              <FormLabel>ID employé</FormLabel>
              <FormControl>
                <Input
                  placeholder="Entrer l'ID employé"
                  {...field}
                  value={field.value ?? ''}
                  disabled={isDisabled}
                />
              </FormControl>
              <FormDescription>
                Un identifiant unique (lettres, chiffres et tirets seulement).
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
              <FormLabel>Courriel</FormLabel>
              <FormControl>
                <Input
                  type="email"
                  placeholder="employe@exemple.com"
                  {...field}
                  value={field.value ?? ''}
                  disabled={isDisabled}
                />
              </FormControl>
              {showEmailWarning && (
                <div className="flex items-center gap-2 rounded-md bg-amber-50 p-2 text-xs text-amber-800">
                  <AlertTriangle className="h-3 w-3 flex-shrink-0" />
                  Changer le courriel modifiera les identifiants de connexion de cet employé.
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
              <FormLabel>Numéro de téléphone</FormLabel>
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
                Format canadien. Utilisé pour l&apos;authentification par SMS.
              </FormDescription>
              <FormMessage />
            </FormItem>
          )}
        />

        {!isDisabled && (
          <div className="flex justify-end">
            <Button type="submit" disabled={isSubmitting}>
              {isSubmitting ? 'Enregistrement...' : 'Enregistrer les modifications'}
            </Button>
          </div>
        )}
      </form>
    </Form>
  );
}

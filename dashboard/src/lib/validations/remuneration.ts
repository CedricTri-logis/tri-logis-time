import { z } from 'zod';

export const hourlyRateFormSchema = z.object({
  rate: z
    .number({ message: 'Le taux horaire est requis' })
    .positive('Le taux doit être supérieur à 0')
    .multipleOf(0.01, 'Maximum 2 décimales'),
  effective_from: z
    .string({ message: 'La date est requise' })
    .regex(/^\d{4}-\d{2}-\d{2}$/, 'Format de date invalide (AAAA-MM-JJ)'),
});

export type HourlyRateFormValues = z.infer<typeof hourlyRateFormSchema>;

export const weekendPremiumFormSchema = z.object({
  amount: z
    .number({ message: 'Le montant est requis' })
    .min(0, 'Le montant ne peut pas être négatif')
    .multipleOf(0.01, 'Maximum 2 décimales'),
});

export type WeekendPremiumFormValues = z.infer<typeof weekendPremiumFormSchema>;

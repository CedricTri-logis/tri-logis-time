import { z } from "zod";

export const rateConfigSchema = z.object({
  rate_per_km: z.number().positive().max(5),
  threshold_km: z.number().int().positive().optional(),
  rate_after_threshold: z.number().positive().max(5).optional(),
  effective_from: z.string().date(),
  rate_source: z.enum(["cra", "custom"]),
  notes: z.string().max(500).optional(),
});

export type RateConfigFormValues = z.infer<typeof rateConfigSchema>;

export const mileageFiltersSchema = z.object({
  period_start: z.string().date(),
  period_end: z.string().date(),
  employee_id: z.string().uuid().optional(),
  classification: z.enum(["all", "business", "personal"]).default("all"),
});

export type MileageFiltersValues = z.infer<typeof mileageFiltersSchema>;

export const reportGenerationSchema = z.object({
  period_start: z.string().date(),
  period_end: z.string().date(),
  format: z.enum(["pdf", "csv"]).default("pdf"),
  include_personal: z.boolean().default(false),
});

export type ReportGenerationValues = z.infer<typeof reportGenerationSchema>;

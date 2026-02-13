/**
 * CSV Parser utility for location bulk import
 * Uses PapaParse for parsing with Zod for validation
 */

import Papa from 'papaparse';
import {
  locationCsvRowSchema,
  validateCsvHeaders,
  CSV_EXPECTED_HEADERS,
  type LocationCsvRowInput,
} from '@/lib/validations/location';
import type { CsvValidationResult, CsvImportSummary, LocationFormData } from '@/types/location';

/**
 * Parse result from CSV file
 */
export interface CsvParseResult {
  success: boolean;
  headers: string[];
  rows: Record<string, string | number | boolean | null>[];
  errors: string[];
}

/**
 * Parse a CSV file and return raw data
 */
export async function parseCsvFile(file: File): Promise<CsvParseResult> {
  return new Promise((resolve) => {
    Papa.parse(file, {
      header: true,
      dynamicTyping: true,
      skipEmptyLines: true,
      transformHeader: (header) => header.toLowerCase().trim(),
      complete: (results) => {
        const errors: string[] = [];

        // Check for parsing errors
        if (results.errors.length > 0) {
          for (const error of results.errors) {
            if (error.row !== undefined) {
              errors.push(`Row ${error.row + 2}: ${error.message}`);
            } else {
              errors.push(error.message);
            }
          }
        }

        resolve({
          success: errors.length === 0,
          headers: results.meta.fields ?? [],
          rows: results.data as Record<string, string | number | boolean | null>[],
          errors,
        });
      },
      error: (error) => {
        resolve({
          success: false,
          headers: [],
          rows: [],
          errors: [error.message],
        });
      },
    });
  });
}

/**
 * Validate CSV headers and return validation result
 */
export function validateHeaders(headers: string[]): {
  valid: boolean;
  errors: string[];
} {
  const result = validateCsvHeaders(headers);
  const errors: string[] = [];

  if (!result.valid) {
    errors.push(
      `Missing required columns: ${result.missingRequired.join(', ')}`
    );
  }

  if (result.unknownHeaders.length > 0) {
    // Just a warning, not an error
    console.warn(`Unknown columns will be ignored: ${result.unknownHeaders.join(', ')}`);
  }

  return {
    valid: result.valid,
    errors,
  };
}

/**
 * Validate a single CSV row and return validation result
 */
export function validateCsvRow(
  row: Record<string, unknown>,
  rowIndex: number
): CsvValidationResult {
  const result = locationCsvRowSchema.safeParse(row);

  if (result.success) {
    const data = result.data;
    return {
      valid: true,
      row: row as unknown as Record<string, string>,
      rowIndex,
      errors: [],
      data: {
        name: data.name,
        locationType: data.location_type,
        latitude: data.latitude,
        longitude: data.longitude,
        radiusMeters: data.radius_meters,
        address: data.address ?? null,
        notes: data.notes ?? null,
        isActive: data.is_active,
      },
    };
  }

  const errors = result.error.errors.map((err) => {
    const path = err.path.join('.');
    return path ? `${path}: ${err.message}` : err.message;
  });

  return {
    valid: false,
    row: row as unknown as Record<string, string>,
    rowIndex,
    errors,
  };
}

/**
 * Validate all rows in a CSV file
 */
export function validateCsvRows(
  rows: Record<string, unknown>[]
): CsvValidationResult[] {
  return rows.map((row, index) => validateCsvRow(row, index));
}

/**
 * Parse and validate a complete CSV file
 */
export async function parseAndValidateCsv(file: File): Promise<{
  success: boolean;
  validRows: CsvValidationResult[];
  invalidRows: CsvValidationResult[];
  headerErrors: string[];
  parseErrors: string[];
}> {
  // Parse the file
  const parseResult = await parseCsvFile(file);

  if (!parseResult.success && parseResult.rows.length === 0) {
    return {
      success: false,
      validRows: [],
      invalidRows: [],
      headerErrors: [],
      parseErrors: parseResult.errors,
    };
  }

  // Validate headers
  const headerValidation = validateHeaders(parseResult.headers);
  if (!headerValidation.valid) {
    return {
      success: false,
      validRows: [],
      invalidRows: [],
      headerErrors: headerValidation.errors,
      parseErrors: parseResult.errors,
    };
  }

  // Validate each row
  const validationResults = validateCsvRows(parseResult.rows);
  const validRows = validationResults.filter((r) => r.valid);
  const invalidRows = validationResults.filter((r) => !r.valid);

  return {
    success: invalidRows.length === 0 && parseResult.errors.length === 0,
    validRows,
    invalidRows,
    headerErrors: [],
    parseErrors: parseResult.errors,
  };
}

/**
 * Convert validated rows to bulk insert format for RPC
 */
export function prepareForBulkInsert(
  validatedRows: CsvValidationResult[]
): LocationCsvRowInput[] {
  return validatedRows
    .filter((row) => row.valid && row.data)
    .map((row) => ({
      name: row.data!.name,
      location_type: row.data!.locationType,
      latitude: row.data!.latitude,
      longitude: row.data!.longitude,
      radius_meters: row.data!.radiusMeters,
      address: row.data!.address,
      notes: row.data!.notes,
      is_active: row.data!.isActive,
    }));
}

/**
 * Generate a sample CSV template for download
 */
export function generateCsvTemplate(): string {
  const headers = [
    'name',
    'location_type',
    'latitude',
    'longitude',
    'radius_meters',
    'address',
    'notes',
    'is_active',
  ];

  const sampleRows = [
    [
      'Head Office',
      'office',
      '45.5017',
      '-73.5673',
      '100',
      '123 Main St, Montreal, QC',
      'Main headquarters',
      'true',
    ],
    [
      'Construction Site A',
      'building',
      '45.5025',
      '-73.5680',
      '150',
      '456 Work Rd, Montreal, QC',
      'Active construction project',
      'true',
    ],
    [
      'Vendor - ABC Supplies',
      'vendor',
      '45.5100',
      '-73.5700',
      '50',
      '789 Supply Ave',
      '',
      'true',
    ],
  ];

  return [headers.join(','), ...sampleRows.map((row) => row.join(','))].join(
    '\n'
  );
}

/**
 * Trigger download of CSV template
 */
export function downloadCsvTemplate(): void {
  const csvContent = generateCsvTemplate();
  const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);

  const link = document.createElement('a');
  link.href = url;
  link.download = 'locations-template.csv';
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
}

/**
 * Get file size in human-readable format
 */
export function formatFileSize(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/**
 * Validate file type and size
 */
export function validateFile(file: File): {
  valid: boolean;
  error?: string;
} {
  const maxSize = 5 * 1024 * 1024; // 5MB
  const allowedTypes = ['text/csv', 'application/vnd.ms-excel'];
  const allowedExtensions = ['.csv'];

  // Check file extension
  const extension = file.name.toLowerCase().slice(file.name.lastIndexOf('.'));
  if (!allowedExtensions.includes(extension)) {
    return {
      valid: false,
      error: 'File must be a CSV file (.csv)',
    };
  }

  // Check file size
  if (file.size > maxSize) {
    return {
      valid: false,
      error: `File size must be less than ${formatFileSize(maxSize)}`,
    };
  }

  // Check if file is empty
  if (file.size === 0) {
    return {
      valid: false,
      error: 'File is empty',
    };
  }

  return { valid: true };
}

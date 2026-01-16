/**
 * Edge Function: generate-report
 * Spec: 013-reports-export
 *
 * Generates PDF/CSV reports using Browserless for PDF rendering.
 * Invoked by the dashboard or pg_cron for scheduled reports.
 */

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import puppeteer from "npm:puppeteer-core@21.5.0";
import { createClient } from "npm:@supabase/supabase-js@2.39.0";

// Types
interface ReportConfig {
  date_range: {
    preset?: string;
    start?: string;
    end?: string;
  };
  employee_filter: string | string[];
  format: "pdf" | "csv";
  options?: {
    include_incomplete_shifts?: boolean;
    include_gps_summary?: boolean;
    group_by?: "employee" | "date";
  };
}

interface GenerateReportRequest {
  job_id: string;
  report_type: "timesheet" | "activity_summary" | "attendance" | "shift_history";
  config: ReportConfig;
  user_id: string;
}

interface ReportData {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  rows: any[];
  summary?: Record<string, unknown>;
  metadata: {
    generated_at: string;
    date_range: string;
    total_records: number;
    report_type: string;
  };
}

// Supabase client with service role
const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const browserlessToken = Deno.env.get("BROWSERLESS_TOKEN");

const supabase = createClient(supabaseUrl, supabaseServiceKey);

// Main handler
Deno.serve(async (req: Request) => {
  // CORS headers
  const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  };

  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const body: GenerateReportRequest = await req.json();
    const { job_id, report_type, config, user_id } = body;

    if (!job_id || !report_type || !config || !user_id) {
      return new Response(
        JSON.stringify({ error: "Missing required fields" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Update job status to processing
    await supabase
      .from("report_jobs")
      .update({
        status: "processing",
        started_at: new Date().toISOString(),
      })
      .eq("id", job_id);

    // Fetch report data based on type
    const reportData = await fetchReportData(report_type, config);

    if (!reportData || reportData.rows.length === 0) {
      await updateJobFailed(job_id, "No data found for the specified criteria");
      return new Response(
        JSON.stringify({ success: false, error: "No data found" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    let filePath: string;
    let fileSize: number;

    if (config.format === "csv") {
      // Generate CSV
      const csvContent = generateCsv(reportData, report_type);
      const csvBuffer = new TextEncoder().encode(csvContent);
      filePath = `${user_id}/${report_type}/${Date.now()}_report.csv`;
      fileSize = csvBuffer.byteLength;

      const { error: uploadError } = await supabase.storage
        .from("reports")
        .upload(filePath, csvBuffer, {
          contentType: "text/csv",
          cacheControl: "3600",
        });

      if (uploadError) {
        throw new Error(`Storage upload failed: ${uploadError.message}`);
      }
    } else {
      // Generate PDF using Browserless
      if (!browserlessToken) {
        throw new Error("BROWSERLESS_TOKEN not configured");
      }

      const html = await renderHtmlTemplate(report_type, reportData);
      const pdfBuffer = await generatePdf(html);

      filePath = `${user_id}/${report_type}/${Date.now()}_report.pdf`;
      fileSize = pdfBuffer.byteLength;

      const { error: uploadError } = await supabase.storage
        .from("reports")
        .upload(filePath, pdfBuffer, {
          contentType: "application/pdf",
          cacheControl: "3600",
        });

      if (uploadError) {
        throw new Error(`Storage upload failed: ${uploadError.message}`);
      }
    }

    // Update job as completed
    await supabase
      .from("report_jobs")
      .update({
        status: "completed",
        completed_at: new Date().toISOString(),
        file_path: filePath,
        file_size_bytes: fileSize,
        record_count: reportData.rows.length,
      })
      .eq("id", job_id);

    return new Response(
      JSON.stringify({
        success: true,
        file_path: filePath,
        file_size_bytes: fileSize,
        record_count: reportData.rows.length,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("Report generation error:", error);

    // Try to update job status if we have job_id
    try {
      const body = await req.clone().json();
      if (body.job_id) {
        await updateJobFailed(body.job_id, error instanceof Error ? error.message : "Unknown error");
      }
    } catch {
      // Ignore parsing errors
    }

    return new Response(
      JSON.stringify({ success: false, error: error instanceof Error ? error.message : "Unknown error" }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }
});

/**
 * Update job status to failed
 */
async function updateJobFailed(jobId: string, errorMessage: string): Promise<void> {
  await supabase
    .from("report_jobs")
    .update({
      status: "failed",
      error_message: errorMessage,
      completed_at: new Date().toISOString(),
    })
    .eq("id", jobId);
}

/**
 * Fetch report data from database
 */
async function fetchReportData(
  reportType: string,
  config: ReportConfig
): Promise<ReportData> {
  const startDate = config.date_range.start;
  const endDate = config.date_range.end;

  // Parse employee IDs from filter
  let employeeIds: string[] | null = null;
  if (config.employee_filter !== "all" && Array.isArray(config.employee_filter)) {
    employeeIds = config.employee_filter;
  }

  let rpcName: string;
  let rpcParams: Record<string, unknown>;

  switch (reportType) {
    case "timesheet":
      rpcName = "get_timesheet_report_data";
      rpcParams = {
        p_start_date: startDate,
        p_end_date: endDate,
        p_employee_ids: employeeIds,
        p_include_incomplete: config.options?.include_incomplete_shifts ?? false,
      };
      break;
    case "shift_history":
      rpcName = "get_shift_history_export_data";
      rpcParams = {
        p_start_date: startDate,
        p_end_date: endDate,
        p_employee_ids: employeeIds,
      };
      break;
    case "activity_summary":
      rpcName = "get_team_activity_summary";
      rpcParams = {
        p_start_date: startDate,
        p_end_date: endDate,
        p_team_id: null,
      };
      break;
    case "attendance":
      rpcName = "get_attendance_report_data";
      rpcParams = {
        p_start_date: startDate,
        p_end_date: endDate,
        p_employee_ids: employeeIds,
      };
      break;
    default:
      throw new Error(`Unknown report type: ${reportType}`);
  }

  const { data, error } = await supabase.rpc(rpcName, rpcParams);

  if (error) {
    throw new Error(`Failed to fetch report data: ${error.message}`);
  }

  return {
    rows: data || [],
    metadata: {
      generated_at: new Date().toISOString(),
      date_range: `${startDate} to ${endDate}`,
      total_records: (data || []).length,
      report_type: reportType,
    },
  };
}

/**
 * Generate CSV content from report data
 */
function generateCsv(reportData: ReportData, reportType: string): string {
  const rows = reportData.rows;
  if (rows.length === 0) return "";

  // Build metadata header
  const metadataLines = [
    `# ${reportType.replace("_", " ").toUpperCase()} Report`,
    `# Generated: ${reportData.metadata.generated_at}`,
    `# Date Range: ${reportData.metadata.date_range}`,
    `# Total Records: ${reportData.metadata.total_records}`,
    "#",
  ];

  // Get column headers from first row
  const headers = Object.keys(rows[0]);
  const headerLine = headers.join(",");

  // Build data rows
  const dataLines = rows.map((row) => {
    return headers
      .map((h) => {
        const value = row[h];
        if (value === null || value === undefined) return "";
        if (typeof value === "string" && (value.includes(",") || value.includes('"'))) {
          return `"${value.replace(/"/g, '""')}"`;
        }
        return String(value);
      })
      .join(",");
  });

  return [...metadataLines, headerLine, ...dataLines].join("\n");
}

/**
 * Render HTML template for PDF generation
 */
async function renderHtmlTemplate(
  reportType: string,
  reportData: ReportData
): Promise<string> {
  // Base template with inline styles
  const baseStyles = `
    <style>
      * { margin: 0; padding: 0; box-sizing: border-box; }
      body { font-family: Arial, sans-serif; font-size: 12px; line-height: 1.4; color: #1e293b; }
      .container { max-width: 100%; padding: 20px; }
      .header { margin-bottom: 20px; border-bottom: 2px solid #e2e8f0; padding-bottom: 15px; }
      .header h1 { font-size: 24px; font-weight: bold; color: #0f172a; margin-bottom: 5px; }
      .header .subtitle { color: #64748b; font-size: 14px; }
      .meta { display: flex; gap: 20px; margin-bottom: 20px; background: #f8fafc; padding: 10px; border-radius: 4px; }
      .meta-item { }
      .meta-item .label { font-weight: bold; color: #64748b; font-size: 10px; text-transform: uppercase; }
      .meta-item .value { color: #0f172a; }
      table { width: 100%; border-collapse: collapse; margin-bottom: 20px; }
      th { background: #f1f5f9; color: #475569; font-weight: 600; text-align: left; padding: 8px 12px; border-bottom: 2px solid #e2e8f0; font-size: 11px; text-transform: uppercase; }
      td { padding: 8px 12px; border-bottom: 1px solid #e2e8f0; }
      tr:nth-child(even) { background: #fafafa; }
      .footer { margin-top: 20px; padding-top: 15px; border-top: 1px solid #e2e8f0; color: #94a3b8; font-size: 10px; text-align: center; }
      .summary { background: #f0f9ff; padding: 15px; border-radius: 4px; margin-bottom: 20px; }
      .summary h3 { font-size: 14px; margin-bottom: 10px; color: #0369a1; }
      .summary-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; }
      .summary-item .label { font-size: 10px; color: #64748b; text-transform: uppercase; }
      .summary-item .value { font-size: 18px; font-weight: bold; color: #0f172a; }
      @media print { body { -webkit-print-color-adjust: exact; print-color-adjust: exact; } }
    </style>
  `;

  const { rows, metadata } = reportData;

  // Generate table content based on report type
  let tableHeaders: string[] = [];
  let tableRows: string[][] = [];

  switch (reportType) {
    case "timesheet":
      tableHeaders = ["Employee", "ID", "Date", "Clock In", "Clock Out", "Hours", "Status"];
      tableRows = rows.map((row) => [
        row.employee_name || "-",
        row.employee_identifier || "-",
        row.shift_date || "-",
        row.clocked_in_at ? new Date(row.clocked_in_at).toLocaleTimeString() : "-",
        row.clocked_out_at ? new Date(row.clocked_out_at).toLocaleTimeString() : "-",
        row.duration_minutes ? (row.duration_minutes / 60).toFixed(2) : "-",
        row.status || "-",
      ]);
      break;

    case "shift_history":
      tableHeaders = ["Employee", "ID", "Shift ID", "Clock In", "Clock Out", "Hours", "GPS Points"];
      tableRows = rows.map((row) => [
        row.employee_name || "-",
        row.employee_identifier || "-",
        row.shift_id ? row.shift_id.substring(0, 8) : "-",
        row.clocked_in_at ? new Date(row.clocked_in_at).toLocaleString() : "-",
        row.clocked_out_at ? new Date(row.clocked_out_at).toLocaleString() : "-",
        row.duration_minutes ? (row.duration_minutes / 60).toFixed(2) : "-",
        row.gps_point_count?.toString() || "0",
      ]);
      break;

    case "activity_summary":
      tableHeaders = ["Period", "Total Hours", "Total Shifts", "Avg Hours/Employee", "Active Employees"];
      tableRows = rows.map((row) => [
        row.period || "-",
        row.total_hours?.toString() || "0",
        row.total_shifts?.toString() || "0",
        row.avg_hours_per_employee?.toString() || "0",
        row.employees_active?.toString() || "0",
      ]);
      break;

    case "attendance":
      tableHeaders = ["Employee", "Working Days", "Days Worked", "Days Absent", "Attendance Rate"];
      tableRows = rows.map((row) => [
        row.employee_name || "-",
        row.total_working_days?.toString() || "0",
        row.days_worked?.toString() || "0",
        row.days_absent?.toString() || "0",
        row.attendance_rate ? `${row.attendance_rate}%` : "0%",
      ]);
      break;
  }

  const reportTitle = reportType.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());

  const html = `
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="UTF-8">
        <title>${reportTitle} Report</title>
        ${baseStyles}
      </head>
      <body>
        <div class="container">
          <div class="header">
            <h1>${reportTitle} Report</h1>
            <div class="subtitle">GPS Tracker Management Dashboard</div>
          </div>

          <div class="meta">
            <div class="meta-item">
              <div class="label">Date Range</div>
              <div class="value">${metadata.date_range}</div>
            </div>
            <div class="meta-item">
              <div class="label">Generated</div>
              <div class="value">${new Date(metadata.generated_at).toLocaleString()}</div>
            </div>
            <div class="meta-item">
              <div class="label">Total Records</div>
              <div class="value">${metadata.total_records}</div>
            </div>
          </div>

          <table>
            <thead>
              <tr>
                ${tableHeaders.map((h) => `<th>${h}</th>`).join("")}
              </tr>
            </thead>
            <tbody>
              ${tableRows.map((row) => `<tr>${row.map((cell) => `<td>${cell}</td>`).join("")}</tr>`).join("")}
            </tbody>
          </table>

          <div class="footer">
            Generated by GPS Tracker Dashboard &bull; ${new Date().toISOString()}
          </div>
        </div>
      </body>
    </html>
  `;

  return html;
}

/**
 * Sleep utility for retry backoff
 */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Generate PDF using Browserless with retry logic
 */
async function generatePdf(html: string, maxRetries = 3): Promise<Uint8Array> {
  let lastError: Error | null = null;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    let browser = null;

    try {
      browser = await puppeteer.connect({
        browserWSEndpoint: `wss://chrome.browserless.io?token=${browserlessToken}`,
      });

      const page = await browser.newPage();

      // Set a timeout for content loading
      await page.setContent(html, {
        waitUntil: "networkidle0",
        timeout: 30000,
      });

      const pdfBuffer = await page.pdf({
        format: "A4",
        printBackground: true,
        margin: {
          top: "20mm",
          right: "15mm",
          bottom: "20mm",
          left: "15mm",
        },
        timeout: 30000,
      });

      return new Uint8Array(pdfBuffer);
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      console.error(`PDF generation attempt ${attempt}/${maxRetries} failed:`, lastError.message);

      if (attempt < maxRetries) {
        // Exponential backoff: 1s, 2s, 4s
        const delay = Math.pow(2, attempt - 1) * 1000;
        console.log(`Retrying in ${delay}ms...`);
        await sleep(delay);
      }
    } finally {
      if (browser) {
        try {
          await browser.close();
        } catch {
          // Ignore close errors
        }
      }
    }
  }

  throw lastError || new Error("PDF generation failed after retries");
}

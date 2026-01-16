# Feature Specification: Reports & Export

**Feature Branch**: `013-reports-export`
**Created**: 2026-01-15
**Status**: Draft
**Input**: User description: "Spec 013: Reports & Export"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Generate Organization Timesheet Report (Priority: P1)

As an administrator, I need to generate a comprehensive timesheet report for all employees or specific teams for a given pay period so I can submit accurate work hours to payroll processing and maintain compliance records.

**Why this priority**: Timesheet reports are the most critical reporting need for organizations with hourly workers. Accurate, timely timesheet data directly impacts payroll accuracy and employee compensation. This is a high-frequency, high-stakes operation that administrators perform every pay cycle.

**Independent Test**: Can be fully tested by logging in as an admin, selecting a date range and employee group, generating a timesheet report, and verifying the report contains accurate shift data with total hours that match individual shift records.

**Acceptance Scenarios**:

1. **Given** I am an administrator, **When** I navigate to reports and select "Timesheet Report", **Then** I see options to select date range, employee group (all, by team, individual employees), and output format.
2. **Given** I have selected report parameters, **When** I generate the report, **Then** I receive a downloadable file containing each employee's shifts with date, clock-in time, clock-out time, total hours, and break deductions (if applicable).
3. **Given** the report is generated, **When** I review the summary section, **Then** I see total hours per employee and grand total for the selected period.
4. **Given** an employee worked across multiple teams during the period, **When** I generate a team-specific report, **Then** only shifts worked under that team's supervision appear in that report.
5. **Given** I generate a timesheet report, **When** an employee has incomplete shifts (clocked in but not out), **Then** those shifts are flagged with a warning and excluded from hour totals.

---

### User Story 2 - Export Employee Shift History (Priority: P2)

As a supervisor or administrator, I need to export detailed shift history for individual employees or my team so I can share records with HR, respond to employee inquiries, or maintain external records.

**Why this priority**: Shift history exports support day-to-day operational needs such as responding to employee questions about their hours, providing records for performance reviews, or sharing data with HR systems. This is a frequent need that empowers supervisors to self-serve.

**Independent Test**: Can be fully tested by selecting an employee, specifying a date range, exporting their shift history, and verifying the export contains all shifts within the range with complete details.

**Acceptance Scenarios**:

1. **Given** I am a supervisor viewing an employee's history, **When** I select export, **Then** I can choose a date range and output format (CSV, PDF).
2. **Given** I request a CSV export, **When** the export completes, **Then** I receive a file with columns for date, shift start, shift end, duration, location summary, and notes.
3. **Given** I request a PDF export, **When** the export completes, **Then** I receive a formatted document with employee name, period covered, shift details table, and summary statistics.
4. **Given** I am an administrator, **When** I access bulk export, **Then** I can select multiple employees and receive individual export files or a combined report.

---

### User Story 3 - Generate Team Activity Summary Report (Priority: P2)

As a manager or administrator, I need to generate a summary report showing team activity metrics (total hours, shift counts, averages) for a period so I can assess team productivity, plan resources, and report to leadership.

**Why this priority**: Managers and administrators need aggregate views for planning and reporting purposes. This complements the detailed timesheet data with high-level insights that support management decisions.

**Independent Test**: Can be fully tested by selecting a team and date range, generating a summary report, and verifying aggregate metrics match the sum of individual employee data.

**Acceptance Scenarios**:

1. **Given** I am a manager, **When** I generate a team activity summary, **Then** I see total hours, total shifts, average hours per employee, and hours by day of week.
2. **Given** I am an administrator, **When** I generate an organization-wide summary, **Then** I see the same metrics aggregated across all teams with a breakdown by team.
3. **Given** the summary is generated, **When** I export it, **Then** I receive a formatted report suitable for sharing with leadership.
4. **Given** I select a custom date range spanning multiple months, **When** the report generates, **Then** I see month-by-month breakdowns within the report.

---

### User Story 4 - Generate Attendance Report (Priority: P3)

As an administrator, I need to generate an attendance report showing employee presence, absences, and patterns for compliance and HR purposes.

**Why this priority**: Attendance tracking supports compliance requirements and HR processes. While less frequent than timesheet reports, this is essential for organizations with attendance policies or regulatory requirements.

**Independent Test**: Can be fully tested by generating an attendance report for a period and verifying it shows working days, days with shifts, days without shifts, and attendance patterns.

**Acceptance Scenarios**:

1. **Given** I am an administrator, **When** I generate an attendance report, **Then** I see each employee's attendance record showing days worked, days absent, and total working days in the period.
2. **Given** the report covers a calendar month, **When** I review an employee's record, **Then** I see a calendar-style view indicating which days they worked.
3. **Given** an employee has perfect attendance, **When** the report is generated, **Then** their record shows 100% attendance rate for scheduled working days.
4. **Given** an employee was inactive (deactivated) during part of the period, **When** the report is generated, **Then** their attendance is calculated only for their active period.

---

### User Story 5 - Schedule and Automate Reports (Priority: P4)

As an administrator, I need to schedule recurring reports to be automatically generated and delivered so I can ensure timely availability of reports for regular business processes like payroll.

**Why this priority**: Automation reduces manual effort and ensures reports are available when needed. This is an efficiency enhancement that builds on core report generation capabilities.

**Independent Test**: Can be fully tested by scheduling a weekly timesheet report, waiting for the scheduled time, and verifying the report is generated and available.

**Acceptance Scenarios**:

1. **Given** I have generated a report manually, **When** I choose to schedule it, **Then** I can select frequency (weekly, bi-weekly, monthly) and delivery day/time.
2. **Given** I have scheduled a report, **When** the scheduled time arrives, **Then** the report is automatically generated and available in my reports history.
3. **Given** scheduled reports are available, **When** I view my scheduled reports list, **Then** I see all active schedules with next run date and can edit or delete them.
4. **Given** a scheduled report fails to generate, **When** the system detects the failure, **Then** I receive a notification with the error and option to retry.

---

### Edge Cases

- What happens when an employee has no shifts in the selected period? The employee appears in the report with zero hours and a clear indication of "No shifts recorded."
- What happens when generating a report for a very large date range (e.g., 1 year)? The system warns about processing time and generates the report asynchronously, notifying the user when complete.
- How does the system handle shifts that span midnight (overnight shifts)? Shifts are reported on the date they started, with duration correctly calculated across the date boundary.
- What happens when a supervisor requests a report for employees they don't supervise? The system returns only data for authorized employees; other employees are excluded without error.
- How are time zones handled in reports? All times are displayed in the organization's configured timezone with clear timezone labels.
- What happens when exporting data with special characters in employee names? The export correctly handles unicode characters and escapes special characters appropriately for the format.
- How does the system handle concurrent report generation requests? Requests are queued and processed in order; users see a "generating" status and are notified when complete.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide a reports section accessible to managers (for their team) and administrators (for all employees).
- **FR-002**: System MUST support generation of Timesheet Reports containing shift details, hours worked, and period totals.
- **FR-003**: System MUST support generation of Team Activity Summary Reports with aggregate metrics.
- **FR-004**: System MUST support generation of Attendance Reports showing presence/absence records.
- **FR-005**: System MUST allow users to select date ranges using presets (This Week, Last Week, This Month, Last Month, Custom Range) and custom date pickers.
- **FR-006**: System MUST allow filtering reports by employee group: all employees, specific team, or individual employees.
- **FR-007**: System MUST support export formats: CSV (for data processing), PDF (for sharing and printing).
- **FR-008**: System MUST include report metadata: generation timestamp, generated by, date range, and filter criteria.
- **FR-009**: System MUST calculate and display summary statistics: total hours, total shifts, average hours per employee.
- **FR-010**: System MUST handle incomplete shifts (missing clock-out) by flagging them and excluding from totals.
- **FR-011**: System MUST generate reports asynchronously when dataset exceeds 1,000 shift records; smaller reports generate synchronously with immediate download.
- **FR-012**: System MUST provide a report history showing previously generated reports available for re-download.
- **FR-013**: System MUST support scheduling reports for automatic generation on recurring schedules.
- **FR-013a**: System MUST notify users of completed scheduled reports via in-app notification (dashboard badge/alert); email delivery is out of scope for initial implementation.
- **FR-014**: System MUST respect Row-Level Security, only including data the requesting user is authorized to view.
- **FR-014a**: System MUST log report generation events (user ID, timestamp, report type, parameters) for audit purposes.
- **FR-015**: System MUST support bulk export of shift history for multiple employees.
- **FR-016**: System MUST provide PDF reports with professional formatting including headers, footers, and page numbers.
- **FR-017**: System MUST include employee identification (name, employee ID) in all report outputs.
- **FR-018**: System MUST calculate attendance rates based on actual working days, accounting for employee active/inactive periods.

### Key Entities

- **Report**: A generated document containing shift, attendance, or summary data for a specified period and employee group. Has attributes: report type, date range, filter criteria, generation timestamp, generated by, file format, file location.
- **Report Template**: A predefined report structure defining included fields, calculations, and formatting. Has attributes: template name, report type, field configuration, summary calculations.
- **Report Schedule**: A recurring schedule for automatic report generation. Has attributes: report configuration, frequency, next run date, last run date, status (active/paused).
- **Report History**: A record of generated reports available for re-download. Has attributes: report reference, generation date, expiration date, download count.
- **Timesheet Entry**: A single shift record as it appears in a timesheet report. Has attributes: employee reference, date, start time, end time, duration, status (complete/incomplete), notes.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Administrators can generate a monthly timesheet report for up to 100 employees within 30 seconds.
- **SC-002**: Report data accuracy matches source shift records with zero discrepancies.
- **SC-003**: 90% of users can successfully generate and download their first report without documentation or training.
- **SC-004**: Scheduled reports are generated within 5 minutes of their scheduled time.
- **SC-005**: PDF reports render correctly and are printable on standard letter/A4 paper.
- **SC-006**: CSV exports are compatible with common spreadsheet applications (Excel, Google Sheets) without formatting issues.
- **SC-007**: Report generation for datasets up to 10,000 shift records completes within 2 minutes.
- **SC-008**: Reports remain available for re-download for at least 30 days after generation.

## Clarifications

### Session 2026-01-15

- Q: How should PDF reports be generated? → A: Server-rendered HTML converted to PDF via Puppeteer/Playwright
- Q: How should users be notified when scheduled reports are ready? → A: In-app notification only (badge/alert in dashboard)
- Q: At what threshold should report generation switch to async? → A: >1,000 shift records triggers async processing
- Q: Where should generated report files be stored? → A: Supabase Storage bucket with signed URLs for secure download
- Q: Should report generation be audit logged? → A: Log report generation events (user, timestamp, report type, parameters)

## Assumptions

- PDF reports are generated by rendering HTML templates server-side and converting to PDF using Puppeteer or Playwright, enabling pixel-perfect output matching web preview.
- Generated report files are stored in a Supabase Storage bucket with time-limited signed URLs for secure, authorized download.
- The existing shifts and gps_points tables contain all necessary data for report generation.
- The existing supervisor relationships (employee_supervisors table) define data access boundaries for managers.
- The Next.js admin dashboard (Specs 009-010) provides the interface foundation for the reports section.
- Server-side report generation will use Supabase Edge Functions for PDF generation and data aggregation.
- Users have modern browsers capable of downloading files and viewing PDFs.
- Organizations operate in a single timezone or have a configured default timezone for reporting.

## Dependencies

- Spec 009 (Dashboard Foundation): Provides admin interface structure and authentication.
- Spec 010 (Employee Management): Provides employee directory and supervisor relationship data.
- Spec 011 (Shift Monitoring): Provides shift data access patterns.
- Spec 003 (Shift Management): Provides shift data models and clock in/out records.

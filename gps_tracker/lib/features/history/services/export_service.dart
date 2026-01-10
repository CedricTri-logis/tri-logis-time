import 'dart:io';

import 'package:csv/csv.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../shifts/models/shift.dart';

/// Service for exporting shift history data to CSV and PDF formats
class ExportService {
  /// Export shifts to CSV format
  ///
  /// Returns the path to the generated CSV file.
  Future<String> exportToCsv({
    required List<Shift> shifts,
    required String employeeName,
    String? employeeId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final dateFormat = DateFormat('yyyy-MM-dd');
    final timeFormat = DateFormat('HH:mm:ss');
    final dateTimeFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

    // Build header
    final headers = [
      'Date',
      'Clock In',
      'Clock Out',
      'Duration (hours)',
      'Clock In Location',
      'Clock Out Location',
      'GPS Points',
      'Status',
    ];

    // Build rows
    final rows = shifts.map((shift) {
      final duration = shift.duration;
      final durationHours = duration.inMinutes / 60;

      return [
        dateFormat.format(shift.clockedInAt.toLocal()),
        timeFormat.format(shift.clockedInAt.toLocal()),
        shift.clockedOutAt != null
            ? timeFormat.format(shift.clockedOutAt!.toLocal())
            : 'Active',
        durationHours.toStringAsFixed(2),
        shift.clockInLocation != null
            ? '${shift.clockInLocation!.latitude.toStringAsFixed(6)}, ${shift.clockInLocation!.longitude.toStringAsFixed(6)}'
            : '',
        shift.clockOutLocation != null
            ? '${shift.clockOutLocation!.latitude.toStringAsFixed(6)}, ${shift.clockOutLocation!.longitude.toStringAsFixed(6)}'
            : '',
        shift.gpsPointCount?.toString() ?? '0',
        shift.status.toString().split('.').last,
      ];
    }).toList();

    // Create CSV
    final csvData = const ListToCsvConverter().convert([headers, ...rows]);

    // Generate filename
    final timestamp = dateTimeFormat.format(DateTime.now()).replaceAll(':', '-');
    final sanitizedName = employeeName.replaceAll(RegExp(r'[^\w\s]'), '').replaceAll(' ', '_');
    final filename = 'shifts_${sanitizedName}_$timestamp.csv';

    // Save file
    final directory = await getApplicationDocumentsDirectory();
    final filePath = '${directory.path}/$filename';
    final file = File(filePath);
    await file.writeAsString(csvData);

    return filePath;
  }

  /// Export shifts to PDF format
  ///
  /// Returns the path to the generated PDF file.
  Future<String> exportToPdf({
    required List<Shift> shifts,
    required String employeeName,
    String? employeeId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final dateFormat = DateFormat('MMM d, yyyy');
    final timeFormat = DateFormat('h:mm a');
    final dateTimeFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

    final pdf = pw.Document();

    // Calculate totals
    var totalDuration = Duration.zero;
    for (final shift in shifts) {
      totalDuration += shift.duration;
    }

    // Build PDF
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'Shift History Report',
              style: pw.TextStyle(
                fontSize: 24,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Text(
              'Employee: $employeeName',
              style: const pw.TextStyle(fontSize: 14),
            ),
            if (startDate != null && endDate != null)
              pw.Text(
                'Period: ${dateFormat.format(startDate)} - ${dateFormat.format(endDate)}',
                style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey700),
              ),
            pw.Text(
              'Generated: ${dateFormat.format(DateTime.now())}',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
            ),
            pw.Divider(thickness: 1),
            pw.SizedBox(height: 10),
          ],
        ),
        footer: (context) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'GPS Clock-In Tracker',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
            ),
            pw.Text(
              'Page ${context.pageNumber} of ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
            ),
          ],
        ),
        build: (context) => [
          // Summary card
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              color: PdfColors.blue50,
              borderRadius: pw.BorderRadius.circular(8),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
              children: [
                _buildSummaryItem('Total Shifts', shifts.length.toString()),
                _buildSummaryItem('Total Hours', _formatDuration(totalDuration)),
                _buildSummaryItem(
                  'Avg Duration',
                  shifts.isNotEmpty
                      ? _formatDuration(
                          Duration(
                            microseconds:
                                totalDuration.inMicroseconds ~/ shifts.length,
                          ),
                        )
                      : '0h',
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 20),
          // Shifts table
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300),
            columnWidths: {
              0: const pw.FlexColumnWidth(1.5),
              1: const pw.FlexColumnWidth(1),
              2: const pw.FlexColumnWidth(1),
              3: const pw.FlexColumnWidth(1),
            },
            children: [
              // Header row
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                children: [
                  _buildTableCell('Date', isHeader: true),
                  _buildTableCell('Clock In', isHeader: true),
                  _buildTableCell('Clock Out', isHeader: true),
                  _buildTableCell('Duration', isHeader: true),
                ],
              ),
              // Data rows
              ...shifts.map((shift) {
                return pw.TableRow(
                  children: [
                    _buildTableCell(dateFormat.format(shift.clockedInAt.toLocal())),
                    _buildTableCell(timeFormat.format(shift.clockedInAt.toLocal())),
                    _buildTableCell(
                      shift.clockedOutAt != null
                          ? timeFormat.format(shift.clockedOutAt!.toLocal())
                          : 'Active',
                    ),
                    _buildTableCell(_formatDuration(shift.duration)),
                  ],
                );
              }),
            ],
          ),
        ],
      ),
    );

    // Generate filename
    final timestamp = dateTimeFormat.format(DateTime.now()).replaceAll(':', '-');
    final sanitizedName = employeeName.replaceAll(RegExp(r'[^\w\s]'), '').replaceAll(' ', '_');
    final filename = 'shifts_${sanitizedName}_$timestamp.pdf';

    // Save file
    final directory = await getApplicationDocumentsDirectory();
    final filePath = '${directory.path}/$filename';
    final file = File(filePath);
    await file.writeAsBytes(await pdf.save());

    return filePath;
  }

  /// Share an exported file
  Future<void> shareFile(String filePath) async {
    await Share.shareXFiles([XFile(filePath)]);
  }

  pw.Widget _buildSummaryItem(String label, String value) {
    return pw.Column(
      children: [
        pw.Text(
          value,
          style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          label,
          style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
        ),
      ],
    );
  }

  pw.Widget _buildTableCell(String text, {bool isHeader = false}) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(8),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: isHeader ? 10 : 9,
          fontWeight: isHeader ? pw.FontWeight.bold : null,
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);

    if (hours == 0 && minutes == 0) return '0h';
    if (hours == 0) return '${minutes}m';
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }
}

/// Exception for export operations
class ExportException implements Exception {
  final String message;

  const ExportException(this.message);

  @override
  String toString() => 'ExportException: $message';
}

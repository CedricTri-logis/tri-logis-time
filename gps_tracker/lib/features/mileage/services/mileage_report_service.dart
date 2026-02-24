import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../models/reimbursement_rate.dart';
import '../models/trip.dart';

/// Service for generating mileage reimbursement PDF reports
class MileageReportService {
  /// Generate a mileage reimbursement PDF report
  ///
  /// Only business trips (where [Trip.isBusiness] is true) are included.
  /// Returns the path to the generated PDF file.
  Future<String> generateReport({
    required List<Trip> trips,
    required ReimbursementRate rate,
    required String employeeName,
    required DateTime periodStart,
    required DateTime periodEnd,
    required double ytdKm,
  }) async {
    final dateFormat = DateFormat('MMM d, yyyy');
    final shortDateFormat = DateFormat('MMM d');
    final dateTimeFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
    final currencyFormat = NumberFormat.currency(symbol: '\$', decimalDigits: 2);

    // Filter to business trips only
    final businessTrips =
        trips.where((trip) => trip.isBusiness).toList()
          ..sort((a, b) => a.startedAt.compareTo(b.startedAt));

    // Calculate totals
    final totalKm = businessTrips.fold<double>(
      0.0,
      (sum, trip) => sum + trip.distanceKm,
    );
    final totalReimbursement = rate.calculateReimbursement(totalKm, ytdKm);

    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        header: (context) => _buildHeader(
          context: context,
          employeeName: employeeName,
          periodStart: periodStart,
          periodEnd: periodEnd,
          dateFormat: dateFormat,
        ),
        footer: (context) => _buildFooter(
          context: context,
          rate: rate,
        ),
        build: (context) => [
          // Summary box
          _buildSummaryBox(
            totalKm: totalKm,
            totalReimbursement: totalReimbursement,
            tripCount: businessTrips.length,
            rate: rate,
            currencyFormat: currencyFormat,
          ),
          pw.SizedBox(height: 20),
          // Trip table
          _buildTripTable(
            trips: businessTrips,
            rate: rate,
            ytdKm: ytdKm,
            shortDateFormat: shortDateFormat,
            currencyFormat: currencyFormat,
            totalKm: totalKm,
            totalReimbursement: totalReimbursement,
          ),
        ],
      ),
    );

    // Generate filename
    final timestamp =
        dateTimeFormat.format(DateTime.now()).replaceAll(':', '-');
    final sanitizedName =
        employeeName.replaceAll(RegExp(r'[^\w\s]'), '').replaceAll(' ', '_');
    final filename = 'mileage_${sanitizedName}_$timestamp.pdf';

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

  pw.Widget _buildHeader({
    required pw.Context context,
    required String employeeName,
    required DateTime periodStart,
    required DateTime periodEnd,
    required DateFormat dateFormat,
  }) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Mileage Reimbursement Report',
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
        pw.Text(
          'Period: ${dateFormat.format(periodStart)} - ${dateFormat.format(periodEnd)}',
          style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey700),
        ),
        pw.Text(
          'Generated: ${dateFormat.format(DateTime.now())}',
          style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
        ),
        pw.Divider(thickness: 1),
        pw.SizedBox(height: 10),
      ],
    );
  }

  pw.Widget _buildFooter({
    required pw.Context context,
    required ReimbursementRate rate,
  }) {
    return pw.Column(
      children: [
        pw.Divider(color: PdfColors.grey300),
        pw.SizedBox(height: 4),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Expanded(
              child: pw.Text(
                'Rate: ${rate.displayRate} (${rate.displaySource})',
                style:
                    const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
              ),
            ),
            pw.Text(
              'Page ${context.pageNumber} of ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
            ),
          ],
        ),
        pw.SizedBox(height: 2),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.start,
          children: [
            pw.Text(
              'Tri-Logis Time',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
            ),
          ],
        ),
      ],
    );
  }

  pw.Widget _buildSummaryBox({
    required double totalKm,
    required double totalReimbursement,
    required int tripCount,
    required ReimbursementRate rate,
    required NumberFormat currencyFormat,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: PdfColors.blue50,
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
        children: [
          _buildSummaryItem(
            'Total Business km',
            '${totalKm.toStringAsFixed(1)} km',
          ),
          _buildSummaryItem(
            'Total Reimbursement',
            currencyFormat.format(totalReimbursement),
          ),
          _buildSummaryItem(
            'Business Trips',
            tripCount.toString(),
          ),
          _buildSummaryItem(
            'Rate',
            '\$${rate.ratePerKm.toStringAsFixed(2)}/km',
          ),
        ],
      ),
    );
  }

  pw.Widget _buildTripTable({
    required List<Trip> trips,
    required ReimbursementRate rate,
    required double ytdKm,
    required DateFormat shortDateFormat,
    required NumberFormat currencyFormat,
    required double totalKm,
    required double totalReimbursement,
  }) {
    // Calculate per-trip reimbursement incrementally to respect YTD tiering
    final tripReimbursements = <double>[];
    var runningYtdKm = ytdKm;
    for (final trip in trips) {
      final reimbursement =
          rate.calculateReimbursement(trip.distanceKm, runningYtdKm);
      tripReimbursements.add(reimbursement);
      runningYtdKm += trip.distanceKm;
    }

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey300),
      columnWidths: {
        0: const pw.FlexColumnWidth(1.2), // Date
        1: const pw.FlexColumnWidth(2.0), // From
        2: const pw.FlexColumnWidth(2.0), // To
        3: const pw.FlexColumnWidth(1.0), // Distance
        4: const pw.FlexColumnWidth(1.0), // Duration
        5: const pw.FlexColumnWidth(1.2), // Reimbursement
      },
      children: [
        // Header row
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey200),
          children: [
            _buildTableCell('Date', isHeader: true),
            _buildTableCell('From', isHeader: true),
            _buildTableCell('To', isHeader: true),
            _buildTableCell('Distance (km)', isHeader: true),
            _buildTableCell('Duration', isHeader: true),
            _buildTableCell('Reimbursement', isHeader: true),
          ],
        ),
        // Data rows
        ...trips.asMap().entries.map((entry) {
          final index = entry.key;
          final trip = entry.value;
          final reimbursement = tripReimbursements[index];

          return pw.TableRow(
            children: [
              _buildTableCell(
                shortDateFormat.format(trip.startedAt.toLocal()),
              ),
              _buildTableCell(
                trip.startDisplayName,
                maxLines: 2,
              ),
              _buildTableCell(
                trip.endDisplayName,
                maxLines: 2,
              ),
              _buildTableCell(
                trip.distanceKm.toStringAsFixed(1),
                alignment: pw.Alignment.centerRight,
              ),
              _buildTableCell(
                _formatDuration(trip.durationMinutes),
              ),
              _buildTableCell(
                currencyFormat.format(reimbursement),
                alignment: pw.Alignment.centerRight,
              ),
            ],
          );
        }),
        // Grand total row
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey100),
          children: [
            _buildTableCell('TOTAL', isHeader: true),
            _buildTableCell(''),
            _buildTableCell(''),
            _buildTableCell(
              totalKm.toStringAsFixed(1),
              isHeader: true,
              alignment: pw.Alignment.centerRight,
            ),
            _buildTableCell(''),
            _buildTableCell(
              currencyFormat.format(totalReimbursement),
              isHeader: true,
              alignment: pw.Alignment.centerRight,
            ),
          ],
        ),
      ],
    );
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

  pw.Widget _buildTableCell(
    String text, {
    bool isHeader = false,
    int maxLines = 1,
    pw.Alignment? alignment,
  }) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(6),
      alignment: alignment,
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: isHeader ? 9 : 8,
          fontWeight: isHeader ? pw.FontWeight.bold : null,
        ),
        maxLines: maxLines,
        overflow: pw.TextOverflow.clip,
      ),
    );
  }

  String _formatDuration(int minutes) {
    final hours = minutes ~/ 60;
    final mins = minutes % 60;

    if (hours == 0 && mins == 0) return '0m';
    if (hours == 0) return '${mins}m';
    if (mins == 0) return '${hours}h';
    return '${hours}h ${mins}m';
  }
}

/// Exception for mileage report operations
class MileageReportException implements Exception {
  final String message;

  const MileageReportException(this.message);

  @override
  String toString() => 'MileageReportException: $message';
}

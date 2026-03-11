import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../cleaning/models/cleaning_session.dart';
import '../../cleaning/models/scan_result.dart';
import '../../cleaning/models/studio.dart';
import '../../cleaning/providers/cleaning_session_provider.dart';
import '../../cleaning/widgets/manual_entry_dialog.dart';
import '../../cleaning/widgets/scan_result_dialog.dart';
import '../../shifts/providers/shift_provider.dart';
import '../models/work_session.dart';
import '../providers/work_session_provider.dart';

/// Full-screen QR scanner for work session check-in/check-out.
///
/// Uses [WorkSessionNotifier.scanIn] / [scanOut] under the hood,
/// converting [WorkSessionResult] to [ScanResult] for display
/// via the existing [ScanResultDialog] (Phase 1 compatibility).
class QrScannerScreen extends ConsumerStatefulWidget {
  const QrScannerScreen({super.key});

  @override
  ConsumerState<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends ConsumerState<QrScannerScreen>
    with WidgetsBindingObserver {
  late MobileScannerController _controller;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = MobileScannerController(
      formats: [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _controller.stop();
    } else if (state == AppLifecycleState.resumed) {
      _controller.start();
    }
  }

  Future<void> _onBarcodeDetected(BarcodeCapture capture) async {
    if (_isProcessing) return;

    final barcode = capture.barcodes.firstOrNull;
    if (barcode == null || barcode.rawValue == null) return;

    final qrCode = barcode.rawValue!.trim();
    if (qrCode.isEmpty) return;

    setState(() => _isProcessing = true);
    await _controller.stop();

    await _processQrCode(qrCode);
  }

  Future<void> _processQrCode(String qrCode) async {
    // Validate active shift
    final hasShift = ref.read(hasActiveShiftProvider);
    if (!hasShift) {
      if (!mounted) return;
      await ScanResultDialog.show(
        context,
        ScanResult.error(ScanErrorType.noActiveShift),
      );
      _resumeScanner();
      return;
    }

    final activeShift = ref.read(activeShiftProvider);
    if (activeShift == null) {
      _resumeScanner();
      return;
    }

    final notifier = ref.read(workSessionProvider.notifier);
    final activeSession = ref.read(activeWorkSessionProvider);

    // Check if there's an active session for a DIFFERENT studio
    if (activeSession != null) {
      // Try to look up the scanned studio to see if it matches
      final studioCache = ref.read(studioCacheServiceProvider);
      final scannedStudio = await studioCache.lookupByQrCode(qrCode);

      if (scannedStudio != null && scannedStudio.id == activeSession.studioId) {
        // Same studio — scan out
        final result = await notifier.scanOut(qrCode);
        if (!mounted) return;
        final scanResult = _toScanResult(result);
        await ScanResultDialog.show(context, scanResult);
        if (scanResult.success) {
          if (mounted) Navigator.of(context).pop();
        } else {
          _resumeScanner();
        }
        return;
      }

      // Different studio — warn about existing session
      if (!mounted) return;
      final action = await _showExistingSessionWarning(activeSession);
      if (action == _ExistingSessionAction.closeAndNew) {
        // Close current session first
        final closeResult = await notifier.scanOut(
          await _getQrCodeForSession(activeSession),
        );
        if (closeResult.success) {
          // Now scan in to the new studio
          final result = await notifier.scanIn(
            qrCode,
            activeShift.id,
            serverShiftId: activeShift.serverId,
          );
          if (!mounted) return;
          final scanResult = _toScanResult(result);
          await ScanResultDialog.show(context, scanResult);
          if (scanResult.success) {
            if (mounted) Navigator.of(context).pop();
          } else {
            _resumeScanner();
          }
        } else {
          if (!mounted) return;
          await ScanResultDialog.show(context, _toScanResult(closeResult));
          _resumeScanner();
        }
        return;
      } else {
        // User cancelled
        _resumeScanner();
        return;
      }
    }

    // No active session — try scan in
    final result = await notifier.scanIn(
      qrCode,
      activeShift.id,
      serverShiftId: activeShift.serverId,
    );
    if (!mounted) return;
    final scanResult = _toScanResult(result);
    await ScanResultDialog.show(context, scanResult);
    if (scanResult.success) {
      if (mounted) Navigator.of(context).pop();
    } else {
      _resumeScanner();
    }
  }

  /// Convert [WorkSessionResult] to [ScanResult] for Phase 1 dialog compatibility.
  ScanResult _toScanResult(WorkSessionResult result) {
    if (result.success && result.session != null) {
      final ws = result.session!;
      final session = CleaningSession(
        id: ws.id,
        employeeId: ws.employeeId,
        studioId: ws.studioId ?? '',
        shiftId: ws.shiftId,
        status: _toCleaningStatus(ws.status),
        startedAt: ws.startedAt,
        completedAt: ws.completedAt,
        durationMinutes: ws.durationMinutes,
        isFlagged: ws.isFlagged,
        flagReason: ws.flagReason,
        studioNumber: ws.studioNumber,
        buildingName: ws.buildingName,
        studioType: ws.studioType != null
            ? StudioType.fromJson(ws.studioType!)
            : null,
      );
      return ScanResult.success(session, warning: result.warning);
    }

    // Map error type
    ScanErrorType errorType;
    switch (result.errorType) {
      case 'NO_AUTH':
        errorType = ScanErrorType.noActiveShift;
      case 'NO_ACTIVE_SESSION':
        errorType = ScanErrorType.noActiveSession;
      case 'SESSION_EXISTS':
        errorType = ScanErrorType.sessionExists;
      case 'STUDIO_INACTIVE':
        errorType = ScanErrorType.studioInactive;
      default:
        errorType = ScanErrorType.invalidQr;
    }
    return ScanResult.error(errorType, message: result.errorMessage);
  }

  /// Convert [WorkSessionStatus] to [CleaningSessionStatus].
  CleaningSessionStatus _toCleaningStatus(WorkSessionStatus status) {
    switch (status) {
      case WorkSessionStatus.inProgress:
        return CleaningSessionStatus.inProgress;
      case WorkSessionStatus.completed:
        return CleaningSessionStatus.completed;
      case WorkSessionStatus.autoClosed:
        return CleaningSessionStatus.autoClosed;
      case WorkSessionStatus.manuallyClosed:
        return CleaningSessionStatus.manuallyClosed;
    }
  }

  Future<String> _getQrCodeForSession(WorkSession session) async {
    final studioCache = ref.read(studioCacheServiceProvider);
    final studios = await studioCache.getAllStudios();
    final match =
        studios.where((s) => s.id == session.studioId).firstOrNull;
    return match?.qrCode ?? '';
  }

  Future<_ExistingSessionAction?> _showExistingSessionWarning(
    WorkSession activeSession,
  ) {
    return showDialog<_ExistingSessionAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.orange),
            SizedBox(width: 8),
            Expanded(child: Text('Session active')),
          ],
        ),
        content: Text(
          'Vous avez une session active à ${activeSession.locationLabel}. '
          'Voulez-vous la fermer et démarrer une nouvelle?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context)
                .pop(_ExistingSessionAction.closeAndNew),
            child: const Text('Fermer et démarrer'),
          ),
        ],
      ),
    );
  }

  void _resumeScanner() {
    if (mounted) {
      setState(() => _isProcessing = false);
      _controller.start();
    }
  }

  void _openManualEntry() async {
    await _controller.stop();

    if (!mounted) return;
    final qrCode = await ManualEntryDialog.show(context, ref);

    if (qrCode != null && qrCode.isNotEmpty) {
      await _processQrCode(qrCode);
    } else {
      _resumeScanner();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scanner QR'),
        actions: [
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (_, state, __) {
              return IconButton(
                icon: Icon(
                  state.torchState == TorchState.on
                      ? Icons.flash_on
                      : Icons.flash_off,
                ),
                onPressed: () => _controller.toggleTorch(),
                tooltip: 'Lampe torche',
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // Camera preview
          MobileScanner(
            controller: _controller,
            onDetect: _onBarcodeDetected,
            errorBuilder: (context, error) {
              return _CameraErrorView(error: error);
            },
          ),

          // Scan overlay
          _ScanOverlay(isProcessing: _isProcessing),

          // Bottom controls
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.7),
                  ],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _isProcessing
                        ? 'Traitement en cours...'
                        : 'Pointez la caméra vers le code QR',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _isProcessing ? null : _openManualEntry,
                    icon: const Icon(Icons.keyboard, color: Colors.white),
                    label: const Text(
                      'Entrer manuellement',
                      style: TextStyle(color: Colors.white),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white54),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _ExistingSessionAction { closeAndNew }

/// Overlay with scan area indicator.
class _ScanOverlay extends StatelessWidget {
  final bool isProcessing;

  const _ScanOverlay({required this.isProcessing});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(
              border: Border.all(
                color: isProcessing ? Colors.orange : Colors.white,
                width: 2,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          if (isProcessing) ...[
            const SizedBox(height: 16),
            const CircularProgressIndicator(color: Colors.white),
          ],
        ],
      ),
    );
  }
}

/// Error view when camera fails to initialize.
class _CameraErrorView extends StatelessWidget {
  final MobileScannerException error;

  const _CameraErrorView({required this.error});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    String message;
    switch (error.errorCode) {
      case MobileScannerErrorCode.permissionDenied:
        message =
            'Permission de caméra refusée. Veuillez l\'activer dans les paramètres.';
      default:
        message = 'Erreur caméra: ${error.errorDetails?.message ?? "inconnue"}';
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.camera_alt_outlined,
              size: 64,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Retour'),
            ),
          ],
        ),
      ),
    );
  }
}

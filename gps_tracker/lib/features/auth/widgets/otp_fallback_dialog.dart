import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/theme.dart';
import '../services/auth_service.dart';
import '../services/validators.dart';
import 'otp_input_field.dart';

/// Compact OTP dialog shown when biometric refresh token is expired.
///
/// Sends an OTP to the saved phone, lets the user enter the code, and
/// returns the [AuthResponse] on success (or null if cancelled/failed).
class OtpFallbackDialog extends StatefulWidget {
  final String phone;
  final AuthService authService;

  const OtpFallbackDialog({
    required this.phone,
    required this.authService,
    super.key,
  });

  /// Show the dialog and return the auth response (or null).
  static Future<AuthResponse?> show({
    required BuildContext context,
    required String phone,
    required AuthService authService,
  }) async {
    // Send OTP before showing dialog
    try {
      await authService.sendOtp(phone: phone);
    } on AuthServiceException {
      return null;
    }

    if (!context.mounted) return null;

    return showDialog<AuthResponse>(
      context: context,
      barrierDismissible: false,
      builder: (_) => OtpFallbackDialog(
        phone: phone,
        authService: authService,
      ),
    );
  }

  @override
  State<OtpFallbackDialog> createState() => _OtpFallbackDialogState();
}

class _OtpFallbackDialogState extends State<OtpFallbackDialog> {
  final _otpKey = GlobalKey<OtpInputFieldState>();
  bool _isLoading = false;
  String? _error;
  int _resendCooldown = 60;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startCooldown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startCooldown() {
    _timer?.cancel();
    _resendCooldown = 60;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _resendCooldown--;
        if (_resendCooldown <= 0) timer.cancel();
      });
    });
  }

  Future<void> _handleVerify(String code) async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await widget.authService.verifyOtp(
        phone: widget.phone,
        token: code,
      );

      if (mounted) {
        Navigator.of(context).pop(response);
      }
    } on AuthServiceException catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.message;
        });
        _otpKey.currentState?.clear();
      }
    }
  }

  Future<void> _handleResend() async {
    try {
      await widget.authService.sendOtp(phone: widget.phone);
      _startCooldown();
      if (mounted) {
        setState(() => _error = null);
      }
    } on AuthServiceException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayPhone = PhoneValidator.formatForDisplay(widget.phone);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'Verification requise',
        textAlign: TextAlign.center,
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Session expiree. Un code a ete envoye au $displayPhone',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600], fontSize: 14),
          ),
          const SizedBox(height: 24),
          OtpInputField(
            key: _otpKey,
            onCompleted: _handleVerify,
            enabled: !_isLoading,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(
                color: TriLogisColors.darkRed,
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 12),
          if (_isLoading)
            const SizedBox(
              height: 24,
              width: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            TextButton(
              onPressed: _resendCooldown <= 0 ? _handleResend : null,
              child: Text(
                _resendCooldown <= 0
                    ? 'Renvoyer le code'
                    : 'Renvoyer dans ${_resendCooldown}s',
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(null),
          child: const Text('Annuler'),
        ),
      ],
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

/// Button to resend OTP code with a 30-second countdown.
class OtpResendButton extends StatefulWidget {
  /// Called when the button is pressed to resend the code
  final VoidCallback onResend;

  /// Countdown duration in seconds (default: 60)
  final int cooldownSeconds;

  const OtpResendButton({
    required this.onResend,
    super.key,
    this.cooldownSeconds = 60,
  });

  @override
  State<OtpResendButton> createState() => _OtpResendButtonState();
}

class _OtpResendButtonState extends State<OtpResendButton> {
  late int _remainingSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _remainingSeconds = widget.cooldownSeconds;
    _startCountdown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startCountdown() {
    _timer?.cancel();
    _remainingSeconds = widget.cooldownSeconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _remainingSeconds--;
        if (_remainingSeconds <= 0) {
          timer.cancel();
        }
      });
    });
  }

  void _handleResend() {
    widget.onResend();
    _startCountdown();
  }

  String get _formattedTime {
    final minutes = _remainingSeconds ~/ 60;
    final seconds = _remainingSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final canResend = _remainingSeconds <= 0;

    return TextButton(
      onPressed: canResend ? _handleResend : null,
      child: Text(
        canResend
            ? 'Renvoyer le code'
            : 'Renvoyer dans $_formattedTime',
      ),
    );
  }
}

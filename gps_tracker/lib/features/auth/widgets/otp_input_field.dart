import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A 6-digit OTP input field with auto-advance, paste support, and iOS/Android
/// SMS autofill.
///
/// Uses 6 individual [TextFormField] widgets so iOS can heuristically detect
/// the OTP pattern and show the "From Messages" autofill suggestion. The first
/// field carries [AutofillHints.oneTimeCode] and the group is wrapped in an
/// [AutofillGroup].
class OtpInputField extends StatefulWidget {
  /// Called when all 6 digits have been entered
  final ValueChanged<String> onCompleted;

  /// Whether the field is enabled
  final bool enabled;

  const OtpInputField({
    required this.onCompleted,
    super.key,
    this.enabled = true,
  });

  @override
  State<OtpInputField> createState() => OtpInputFieldState();
}

class OtpInputFieldState extends State<OtpInputField> {
  static const _length = 6;

  final List<TextEditingController> _controllers =
      List.generate(_length, (_) => TextEditingController());
  final List<FocusNode> _focusNodes =
      List.generate(_length, (_) => FocusNode());
  bool _submitted = false;

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  /// Clear all fields and focus the first one
  void clear() {
    _submitted = false;
    for (final c in _controllers) {
      c.clear();
    }
    _focusNodes[0].requestFocus();
  }

  String get _currentCode => _controllers.map((c) => c.text).join();

  void _onChanged(int index, String value) {
    // Handle paste or autofill: if multiple digits arrive, distribute them
    if (value.length > 1) {
      _handlePaste(value, index);
      return;
    }

    // Single digit entered — auto-advance to next field
    if (value.length == 1 && index < _length - 1) {
      _focusNodes[index + 1].requestFocus();
    }

    // Check if complete (guard against double-fire)
    final code = _currentCode;
    if (code.length == _length && !_submitted) {
      _submitted = true;
      _focusNodes[index].unfocus();
      widget.onCompleted(code);
    }
  }

  void _handlePaste(String value, int startIndex) {
    final digits = value.replaceAll(RegExp(r'[^\d]'), '');
    for (var i = 0; i < digits.length && (startIndex + i) < _length; i++) {
      _controllers[startIndex + i].text = digits[i];
    }

    // Focus the next empty field or last field
    final nextEmpty = _controllers.indexWhere((c) => c.text.isEmpty);
    if (nextEmpty != -1) {
      _focusNodes[nextEmpty].requestFocus();
    } else {
      _focusNodes[_length - 1].unfocus();
    }

    final code = _currentCode;
    if (code.length == _length && !_submitted) {
      _submitted = true;
      widget.onCompleted(code);
    }
  }

  void _onKeyEvent(int index, KeyEvent event) {
    // Handle backspace: go back to previous field
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        _controllers[index].text.isEmpty &&
        index > 0) {
      _controllers[index - 1].clear();
      _focusNodes[index - 1].requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AutofillGroup(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(_length, (index) {
          return Container(
            width: 48,
            height: 56,
            margin: EdgeInsets.only(
              left: index == 0 ? 0 : 6,
              right: index == _length - 1 ? 0 : 6,
            ),
            child: KeyboardListener(
              focusNode: FocusNode(),
              onKeyEvent: (event) => _onKeyEvent(index, event),
              child: TextFormField(
                controller: _controllers[index],
                focusNode: _focusNodes[index],
                enabled: widget.enabled,
                autofocus: index == 0,
                autofillHints: index == 0
                    ? const [AutofillHints.oneTimeCode]
                    : null,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                // NOTE: do NOT set maxLength here — it adds a
                // LengthLimitingTextInputFormatter that truncates pasted /
                // autofilled OTP codes BEFORE onChanged fires, breaking
                // _handlePaste.  Length is enforced in _onChanged instead.
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: const InputDecoration(
                  counterText: '',
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
                onChanged: (value) => _onChanged(index, value),
              ),
            ),
          );
        }),
      ),
    );
  }
}

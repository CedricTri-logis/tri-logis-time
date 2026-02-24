import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A 6-digit OTP input field with iOS SMS autofill and paste support.
///
/// Overlays a transparent TextField (with [AutofillHints.oneTimeCode]) on top
/// of 6 visual digit boxes. The TextField is technically visible to iOS so the
/// "From Messages" autofill suggestion appears, but its text and cursor are
/// fully transparent — the user only sees the visual boxes underneath.
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

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    // Listen to focus changes to update the cursor animation on visual boxes
    _focusNode.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Clear the field and re-enable submission
  void clear() {
    _submitted = false;
    _controller.clear();
    _focusNode.requestFocus();
  }

  void _onTextChanged() {
    // Force rebuild to update visual boxes
    setState(() {});

    final text = _controller.text;
    if (text.length == _length && !_submitted) {
      _submitted = true;
      // Unfocus to dismiss keyboard
      _focusNode.unfocus();
      widget.onCompleted(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = _controller.text;

    // Total width of the 6 boxes: 6 * 48px + 10 gaps * 6px = 348px
    const totalWidth = _length * 48.0 + (_length - 1) * 12.0;

    return SizedBox(
      width: totalWidth,
      height: 56,
      child: Stack(
        children: [
          // Visual 6-box display (behind the TextField)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_length, (index) {
              final hasDigit = index < code.length;
              final isActive = index == code.length && _focusNode.hasFocus;

              return Container(
                width: 48,
                height: 56,
                margin: EdgeInsets.only(
                  left: index == 0 ? 0 : 6,
                  right: index == _length - 1 ? 0 : 6,
                ),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isActive
                        ? theme.colorScheme.primary
                        : hasDigit
                            ? theme.colorScheme.outline
                            : theme.colorScheme.outlineVariant,
                    width: isActive ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(8),
                  color: hasDigit
                      ? theme.colorScheme.surfaceContainerHighest
                      : null,
                ),
                alignment: Alignment.center,
                child: hasDigit
                    ? Text(
                        code[index],
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : isActive
                        ? SizedBox(
                            width: 2,
                            height: 24,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          )
                        : null,
              );
            }),
          ),

          // Transparent TextField on top — visible to iOS for autofill
          // but text/cursor are transparent so user only sees the boxes
          Positioned.fill(
            child: AutofillGroup(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                enabled: widget.enabled,
                autofillHints: const [AutofillHints.oneTimeCode],
                keyboardType: TextInputType.number,
                maxLength: _length,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(_length),
                ],
                style: const TextStyle(
                  color: Colors.transparent,
                  fontSize: 1,
                ),
                cursorColor: Colors.transparent,
                cursorWidth: 0,
                showCursor: false,
                decoration: const InputDecoration(
                  counterText: '',
                  border: InputBorder.none,
                  fillColor: Colors.transparent,
                  filled: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

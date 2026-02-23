import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Phone number input field with +1 prefix and auto-formatting.
///
/// Displays the number as (XXX) XXX-XXXX while the user types.
class PhoneFormField extends StatelessWidget {
  /// Controller for the text field (contains raw digits only)
  final TextEditingController controller;

  /// Focus node for the field
  final FocusNode? focusNode;

  /// Whether the field is enabled
  final bool enabled;

  /// Validation function
  final String? Function(String?)? validator;

  /// Called when field is submitted
  final VoidCallback? onSubmitted;

  const PhoneFormField({
    required this.controller,
    super.key,
    this.focusNode,
    this.enabled = true,
    this.validator,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      keyboardType: TextInputType.phone,
      textInputAction: TextInputAction.done,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(10),
        _PhoneNumberFormatter(),
      ],
      validator: validator,
      onFieldSubmitted: (_) => onSubmitted?.call(),
      decoration: const InputDecoration(
        labelText: 'Telephone',
        hintText: '(514) 555-1234',
        prefixIcon: Icon(Icons.phone_outlined),
        prefixText: '+1  ',
        border: OutlineInputBorder(),
        filled: true,
      ),
    );
  }
}

/// Formats digits into (XXX) XXX-XXXX pattern.
class _PhoneNumberFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'[^\d]'), '');
    final buffer = StringBuffer();

    for (var i = 0; i < digits.length && i < 10; i++) {
      if (i == 0) buffer.write('(');
      buffer.write(digits[i]);
      if (i == 2) buffer.write(') ');
      if (i == 5) buffer.write('-');
    }

    final formatted = buffer.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

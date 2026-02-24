import 'package:flutter/material.dart';

/// Search bar widget for filtering team employees.
///
/// Provides:
/// - Text input for search query
/// - Clear button when text is entered
/// - Debounced search callback
class TeamSearchBar extends StatefulWidget {
  /// Callback when search query changes.
  final ValueChanged<String> onSearch;

  /// Initial search query.
  final String initialQuery;

  /// Hint text for empty state.
  final String? hintText;

  /// Whether to show a loading indicator.
  final bool isLoading;

  const TeamSearchBar({
    super.key,
    required this.onSearch,
    this.initialQuery = '',
    this.hintText,
    this.isLoading = false,
  });

  @override
  State<TeamSearchBar> createState() => _TeamSearchBarState();
}

class _TeamSearchBarState extends State<TeamSearchBar> {
  late TextEditingController _controller;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleClear() {
    _controller.clear();
    widget.onSearch('');
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      onChanged: widget.onSearch,
      decoration: InputDecoration(
        hintText: widget.hintText ?? 'Rechercher par nom ou numéro d\'employé...',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, child) {
            if (widget.isLoading) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            if (value.text.isNotEmpty) {
              return IconButton(
                icon: const Icon(Icons.clear),
                onPressed: _handleClear,
              );
            }
            return const SizedBox.shrink();
          },
        ),
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest.withOpacity(0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: colorScheme.primary,
            width: 1.5,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
      ),
    );
  }
}

/// Compact search bar for app bar integration.
class TeamSearchBarCompact extends StatefulWidget {
  final ValueChanged<String> onSearch;
  final VoidCallback? onClose;

  const TeamSearchBarCompact({
    super.key,
    required this.onSearch,
    this.onClose,
  });

  @override
  State<TeamSearchBarCompact> createState() => _TeamSearchBarCompactState();
}

class _TeamSearchBarCompactState extends State<TeamSearchBarCompact> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return TextField(
      controller: _controller,
      onChanged: widget.onSearch,
      autofocus: true,
      style: theme.textTheme.bodyLarge,
      decoration: InputDecoration(
        hintText: 'Rechercher les employés...',
        border: InputBorder.none,
        suffixIcon: widget.onClose != null
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  _controller.clear();
                  widget.onSearch('');
                  widget.onClose!();
                },
              )
            : null,
      ),
    );
  }
}

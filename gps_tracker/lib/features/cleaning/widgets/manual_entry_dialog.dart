import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/studio.dart';
import '../providers/cleaning_session_provider.dart';

/// Bottom sheet dialog for manual QR code entry.
class ManualEntryDialog extends StatefulWidget {
  final List<Studio> studios;

  const ManualEntryDialog({super.key, required this.studios});

  /// Show the dialog and return the entered QR code (or null if cancelled).
  static Future<String?> show(BuildContext context, WidgetRef ref) async {
    final studioCache = ref.read(studioCacheServiceProvider);
    final studios = await studioCache.getAllStudios();

    if (!context.mounted) return null;

    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ManualEntryDialog(studios: studios),
    );
  }

  @override
  State<ManualEntryDialog> createState() => _ManualEntryDialogState();
}

class _ManualEntryDialogState extends State<ManualEntryDialog> {
  final _controller = TextEditingController();
  List<Studio> _filteredStudios = [];
  bool _showSuggestions = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final query = _controller.text.trim().toLowerCase();
    if (query.isEmpty) {
      setState(() {
        _filteredStudios = [];
        _showSuggestions = false;
      });
      return;
    }

    setState(() {
      _filteredStudios = widget.studios.where((studio) {
        return studio.qrCode.toLowerCase().contains(query) ||
            studio.studioNumber.toLowerCase().contains(query) ||
            studio.buildingName.toLowerCase().contains(query);
      }).take(5).toList();
      _showSuggestions = _filteredStudios.isNotEmpty;
    });
  }

  void _submit() {
    final code = _controller.text.trim();
    if (code.isNotEmpty) {
      Navigator.of(context).pop(code);
    }
  }

  void _selectStudio(Studio studio) {
    Navigator.of(context).pop(studio.qrCode);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outline.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Title
            Text(
              'Entrée manuelle',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Entrez le code QR ou cherchez par numéro de studio',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),

            // Text input
            TextField(
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'Code QR ou numéro de studio',
                hintText: 'Ex: 8FJ3K2L9H4 ou 201',
                prefixIcon: const Icon(Icons.qr_code),
                border: const OutlineInputBorder(),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _controller.clear();
                        },
                      )
                    : null,
              ),
              onSubmitted: (_) => _submit(),
            ),

            // Autocomplete suggestions
            if (_showSuggestions) ...[
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(alpha: 0.3),
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _filteredStudios.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final studio = _filteredStudios[index];
                    return ListTile(
                      dense: true,
                      title: Text(studio.studioNumber),
                      subtitle: Text(studio.buildingName),
                      trailing: Text(
                        studio.studioType.displayName,
                        style: theme.textTheme.bodySmall,
                      ),
                      onTap: () => _selectStudio(studio),
                    );
                  },
                ),
              ),
            ],

            const SizedBox(height: 16),

            // Submit button
            FilledButton(
              onPressed: _controller.text.trim().isEmpty ? null : _submit,
              child: const Text('Valider'),
            ),
          ],
        ),
      ),
    );
  }
}

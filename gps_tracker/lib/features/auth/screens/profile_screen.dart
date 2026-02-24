import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../../../shared/widgets/error_snackbar.dart';
import '../providers/profile_provider.dart';
import '../widgets/auth_button.dart';

/// Profile screen for viewing and editing user information
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();

  bool _isEditing = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    // Fetch profile on init
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(profileProvider.notifier).fetchProfile();
    });
  }

  @override
  void dispose() {
    _fullNameController.dispose();
    super.dispose();
  }

  void _startEditing() {
    final profile = ref.read(profileProvider).profile;
    _fullNameController.text = profile?.fullName ?? '';
    setState(() => _isEditing = true);
  }

  void _cancelEditing() {
    setState(() => _isEditing = false);
    _fullNameController.clear();
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isSaving = true);

    try {
      await ref.read(profileProvider.notifier).updateProfile(
            fullName: _fullNameController.text,
          );

      if (mounted) {
        setState(() => _isEditing = false);
        ErrorSnackbar.showSuccess(context, 'Profil mis à jour avec succès');
      }
    } catch (e) {
      if (mounted) {
        ErrorSnackbar.show(context, 'Échec de la mise à jour du profil');
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profileState = ref.watch(profileProvider);
    final currentUser = ref.watch(currentUserProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profil'),
        actions: [
          if (!_isEditing && profileState.profile != null)
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: _startEditing,
              tooltip: 'Modifier le profil',
            ),
        ],
      ),
      body: profileState.isLoading && profileState.profile == null
          ? const Center(child: CircularProgressIndicator())
          : profileState.error != null && profileState.profile == null
              ? _buildErrorState(theme, profileState.error!)
              : _buildProfileContent(theme, profileState, currentUser),
    );
  }

  Widget _buildErrorState(ThemeData theme, String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              error,
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                ref.read(profileProvider.notifier).fetchProfile();
              },
              child: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileContent(
    ThemeData theme,
    ProfileState profileState,
    dynamic currentUser,
  ) {
    final profile = profileState.profile;

    if (_isEditing) {
      return _buildEditForm(theme);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Profile header
          Center(
            child: Column(
              children: [
                CircleAvatar(
                  radius: 50,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text(
                    _getInitials(profile?.fullName, profile?.email),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (profile?.fullName != null && profile!.fullName!.isNotEmpty)
                  Text(
                    profile.fullName!,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  profile?.email ?? (currentUser?.email as String?) ?? '',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Profile information
          Text(
            'Informations du compte',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),

          _buildInfoTile(
            theme,
            icon: Icons.email_outlined,
            label: 'Courriel',
            value: profile?.email ?? (currentUser?.email as String?) ?? 'Non défini',
            isReadOnly: true,
          ),
          const Divider(),

          _buildInfoTile(
            theme,
            icon: Icons.phone_outlined,
            label: 'Telephone',
            value: profile?.hasPhoneNumber == true
                ? profile!.phoneNumber!
                : 'Non enregistre',
            isReadOnly: true,
          ),
          const Divider(),

          _buildInfoTile(
            theme,
            icon: Icons.person_outline,
            label: 'Nom complet',
            value: profile?.fullName ?? 'Non défini',
          ),
          const Divider(),

          if (profile?.employeeId != null) ...[
            _buildInfoTile(
              theme,
              icon: Icons.badge_outlined,
              label: 'No. employé',
              value: profile!.employeeId!,
            ),
            const Divider(),
          ],

          _buildInfoTile(
            theme,
            icon: Icons.calendar_today_outlined,
            label: 'Membre depuis',
            value: profile != null
                ? _formatDate(profile.createdAt)
                : 'Inconnu',
          ),

          const SizedBox(height: 32),

          // Status indicator
          if (profile != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: profile.isActive
                    ? Colors.green.withValues(alpha: 0.1)
                    : theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    profile.isActive
                        ? Icons.check_circle_outline
                        : Icons.warning_amber_outlined,
                    color: profile.isActive
                        ? Colors.green
                        : theme.colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Statut du compte : ${profile.status.value.toUpperCase()}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: profile.isActive
                          ? Colors.green
                          : theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEditForm(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Modifier le profil',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),

            // Full name field
            TextFormField(
              controller: _fullNameController,
              decoration: const InputDecoration(
                labelText: 'Nom complet',
                hintText: 'Entrez votre nom complet',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
              enabled: !_isSaving,
              validator: (value) {
                if (value != null && value.length > 255) {
                  return 'Le nom est trop long (max 255 caractères)';
                }
                return null;
              },
            ),
            const SizedBox(height: 8),
            Text(
              'Ce nom sera affiché dans l\'application',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 32),

            // Save button
            AuthButton(
              text: 'Enregistrer',
              loadingText: 'Enregistrement...',
              isLoading: _isSaving,
              onPressed: _saveProfile,
            ),
            const SizedBox(height: 12),

            // Cancel button
            OutlinedButton(
              onPressed: _isSaving ? null : _cancelEditing,
              child: const Text('Annuler'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoTile(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
    bool isReadOnly = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Row(
        children: [
          Icon(
            icon,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: theme.textTheme.bodyLarge,
                ),
              ],
            ),
          ),
          if (isReadOnly)
            Icon(
              Icons.lock_outline,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    );
  }

  String _getInitials(String? fullName, String? email) {
    if (fullName != null && fullName.isNotEmpty) {
      final parts = fullName.trim().split(' ');
      if (parts.length >= 2) {
        return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
      }
      return fullName[0].toUpperCase();
    }
    if (email != null && email.isNotEmpty) {
      return email[0].toUpperCase();
    }
    return '?';
  }

  String _formatDate(DateTime date) {
    final months = [
      'jan.', 'fév.', 'mars', 'avr.', 'mai', 'juin',
      'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.',
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }
}

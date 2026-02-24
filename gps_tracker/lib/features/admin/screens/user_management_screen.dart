import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/user_role.dart';
import '../../../shared/providers/supabase_provider.dart';
import '../../auth/providers/profile_provider.dart';
import '../models/user_with_role.dart';
import '../providers/admin_provider.dart';

/// Screen for managing users and their roles.
///
/// Accessible by admin and super_admin roles only.
/// Displays:
/// - Summary of users by role
/// - Search/filter bar
/// - List of all users with role management
class UserManagementScreen extends ConsumerWidget {
  const UserManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(userManagementProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gestion des utilisateurs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(userManagementProvider.notifier).refresh(),
            tooltip: 'Actualiser',
          ),
        ],
      ),
      body: _buildBody(context, ref, state, theme),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    UserManagementState state,
    ThemeData theme,
  ) {
    // Show loading spinner only on initial load
    if (state.isLoading && state.lastUpdated == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // Show error state only if no data
    if (state.error != null && state.lastUpdated == null) {
      return _ErrorState(
        error: state.error!,
        onRetry: () => ref.read(userManagementProvider.notifier).refresh(),
      );
    }

    // Show empty state if no users
    if (state.users.isEmpty && !state.isLoading) {
      return const _EmptyState();
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(userManagementProvider.notifier).refresh(),
      child: CustomScrollView(
        slivers: [
          // Summary header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Role summary
                  _RoleSummaryCard(users: state.users),
                  const SizedBox(height: 16),

                  // Search bar
                  _SearchBar(
                    onSearch: (query) => ref
                        .read(userManagementProvider.notifier)
                        .updateSearchQuery(query),
                    initialQuery: state.searchQuery,
                  ),
                  const SizedBox(height: 8),

                  // Filter status
                  if (state.searchQuery.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Text(
                            '${state.filteredUsers.length} sur ${state.users.length} utilisateurs',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => ref
                                .read(userManagementProvider.notifier)
                                .clearSearch(),
                            child: const Text('Effacer'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),

          // User list
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final user = state.filteredUsers[index];
                  return _UserTile(
                    user: user,
                    onRoleChanged: (newRole) =>
                        _handleRoleChange(context, ref, user, newRole),
                  );
                },
                childCount: state.filteredUsers.length,
              ),
            ),
          ),

          // Bottom padding
          const SliverToBoxAdapter(
            child: SizedBox(height: 80),
          ),
        ],
      ),
    );
  }

  Future<void> _handleRoleChange(
    BuildContext context,
    WidgetRef ref,
    UserWithRole user,
    UserRole newRole,
  ) async {
    // Confirm role change
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmer le changement de rôle'),
        content: Text(
          'Changer le rôle de ${user.displayName} de '
          '${user.role.displayName} à ${newRole.displayName} ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Confirmer'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!context.mounted) return;

    // Update role
    final success = await ref.read(userManagementProvider.notifier).updateUserRole(
          userId: user.id,
          newRole: newRole,
        );

    if (!context.mounted) return;

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${user.displayName} est maintenant ${newRole.displayName}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      final error = ref.read(userManagementErrorProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error ?? 'Échec de la mise à jour du rôle'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }
}

class _RoleSummaryCard extends StatelessWidget {
  final List<UserWithRole> users;

  const _RoleSummaryCard({required this.users});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Count users by role
    final roleCounts = <UserRole, int>{};
    for (final user in users) {
      roleCounts[user.role] = (roleCounts[user.role] ?? 0) + 1;
    }

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Aperçu des utilisateurs',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _RoleBadge(
                  role: UserRole.superAdmin,
                  count: roleCounts[UserRole.superAdmin] ?? 0,
                  color: Colors.purple,
                ),
                _RoleBadge(
                  role: UserRole.admin,
                  count: roleCounts[UserRole.admin] ?? 0,
                  color: Colors.red,
                ),
                _RoleBadge(
                  role: UserRole.manager,
                  count: roleCounts[UserRole.manager] ?? 0,
                  color: Colors.blue,
                ),
                _RoleBadge(
                  role: UserRole.employee,
                  count: roleCounts[UserRole.employee] ?? 0,
                  color: colorScheme.primary,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  final UserRole role;
  final int count;
  final Color color;

  const _RoleBadge({
    required this.role,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$count',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            role.displayName,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchBar extends StatefulWidget {
  final ValueChanged<String> onSearch;
  final String initialQuery;

  const _SearchBar({
    required this.onSearch,
    this.initialQuery = '',
  });

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      decoration: InputDecoration(
        hintText: 'Rechercher un utilisateur...',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _controller.text.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _controller.clear();
                  widget.onSearch('');
                },
              )
            : null,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        filled: true,
      ),
      onChanged: widget.onSearch,
    );
  }
}

class _UserTile extends ConsumerWidget {
  final UserWithRole user;
  final ValueChanged<UserRole> onRoleChanged;

  const _UserTile({
    required this.user,
    required this.onRoleChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final currentUserId = ref.watch(currentUserProvider)?.id;
    final currentProfile = ref.watch(currentProfileProvider);

    final currentUserRole = currentProfile.when(
      data: (profile) => profile?.role ?? UserRole.employee,
      loading: () => UserRole.employee,
      error: (_, __) => UserRole.employee,
    );

    final canModify = ref.watch(adminServiceProvider).canModifyUserRole(
          targetRole: user.role,
          currentUserRole: currentUserRole,
          targetUserId: user.id,
          currentUserId: currentUserId ?? '',
        );

    final isCurrentUser = user.id == currentUserId;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // Avatar with role indicator
            Stack(
              children: [
                CircleAvatar(
                  backgroundColor: _getRoleColor(user.role).withOpacity(0.2),
                  child: Text(
                    user.displayName.isNotEmpty
                        ? user.displayName[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                      color: _getRoleColor(user.role),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (user.isProtected)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.purple,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colorScheme.surface,
                          width: 2,
                        ),
                      ),
                      child: const Icon(
                        Icons.shield,
                        size: 10,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),

            // User info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          user.displayName,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isCurrentUser)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Vous',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    user.email,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (user.employeeId != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      'ID: ${user.employeeId}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant.withOpacity(0.7),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // Role selector
            if (canModify)
              _RoleDropdown(
                currentRole: user.role,
                currentUserRole: currentUserRole,
                onChanged: onRoleChanged,
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: _getRoleColor(user.role).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (user.isProtected)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.lock,
                          size: 14,
                          color: Colors.purple,
                        ),
                      ),
                    Text(
                      user.role.displayName,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: _getRoleColor(user.role),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Color _getRoleColor(UserRole role) {
    switch (role) {
      case UserRole.superAdmin:
        return Colors.purple;
      case UserRole.admin:
        return Colors.red;
      case UserRole.manager:
        return Colors.blue;
      case UserRole.employee:
        return Colors.green;
    }
  }
}

class _RoleDropdown extends StatelessWidget {
  final UserRole currentRole;
  final UserRole currentUserRole;
  final ValueChanged<UserRole> onChanged;

  const _RoleDropdown({
    required this.currentRole,
    required this.currentUserRole,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Get assignable roles based on current user's role
    final assignableRoles = currentUserRole.isSuperAdmin
        ? UserRole.values
        : UserRole.values.where((role) => role != UserRole.superAdmin).toList();

    return DropdownButton<UserRole>(
      value: currentRole,
      underline: const SizedBox.shrink(),
      borderRadius: BorderRadius.circular(8),
      items: assignableRoles.map((role) {
        return DropdownMenuItem(
          value: role,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _getRoleColor(role),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(role.displayName),
            ],
          ),
        );
      }).toList(),
      onChanged: (role) {
        if (role != null && role != currentRole) {
          onChanged(role);
        }
      },
    );
  }

  Color _getRoleColor(UserRole role) {
    switch (role) {
      case UserRole.superAdmin:
        return Colors.purple;
      case UserRole.admin:
        return Colors.red;
      case UserRole.manager:
        return Colors.blue;
      case UserRole.employee:
        return Colors.green;
    }
  }
}

class _ErrorState extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _ErrorState({
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
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
              'Échec du chargement des utilisateurs',
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.people_outline,
              size: 80,
              color: theme.colorScheme.primary.withOpacity(0.5),
            ),
            const SizedBox(height: 24),
            Text(
              'Aucun utilisateur trouvé',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Il n'y a pas encore d'utilisateurs dans le système.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

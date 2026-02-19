import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/constants.dart';
import '../../shared/providers/supabase_provider.dart';
import '../shifts/providers/shift_provider.dart';
import '../admin/screens/user_management_screen.dart';
import '../auth/providers/profile_provider.dart';
import '../auth/screens/profile_screen.dart';
import '../dashboard/screens/team_dashboard_screen.dart';
import '../history/screens/my_history_screen.dart';
import '../history/screens/supervised_employees_screen.dart';
import '../shifts/screens/shift_dashboard_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _handleSignOut(BuildContext context, WidgetRef ref) async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // Clock out first (auto-closes cleaning + maintenance sessions)
      final shiftState = ref.read(shiftProvider);
      if (shiftState.activeShift != null) {
        await ref.read(shiftProvider.notifier).clockOut();
      }

      final authService = ref.read(authServiceProvider);
      await authService.signOut();
      // Navigation handled automatically by auth state in app.dart
    }
  }

  void _navigateToProfile(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const ProfileScreen()),
    );
  }

  void _navigateToHistory(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const MyHistoryScreen()),
    );
  }

  void _navigateToEmployeeHistory(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const SupervisedEmployeesScreen()),
    );
  }

  void _navigateToUserManagement(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const UserManagementScreen()),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch profile to determine if user is a manager or admin
    final profileAsync = ref.watch(currentProfileProvider);
    final isManager = profileAsync.when(
      data: (profile) => profile?.isManager ?? false,
      loading: () => false,
      error: (_, __) => false,
    );
    final isAdmin = profileAsync.when(
      data: (profile) => profile?.isAdmin ?? false,
      loading: () => false,
      error: (_, __) => false,
    );

    // Use TabBar view for managers, simple dashboard for employees
    if (isManager) {
      return _ManagerHomeScreen(
        onSignOut: () => _handleSignOut(context, ref),
        onProfile: () => _navigateToProfile(context),
        onHistory: () => _navigateToHistory(context),
        onEmployeeHistory: () => _navigateToEmployeeHistory(context),
        onUserManagement: () => _navigateToUserManagement(context),
        isAdmin: isAdmin,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text(AppConstants.appName),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Shift History',
            onPressed: () => _navigateToHistory(context),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'profile':
                  _navigateToProfile(context);
                  break;
                case 'signout':
                  _handleSignOut(context, ref);
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'profile',
                child: Row(
                  children: [
                    Icon(Icons.person_outline),
                    SizedBox(width: 12),
                    Text('Profile'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'signout',
                child: Row(
                  children: [
                    Icon(Icons.logout),
                    SizedBox(width: 12),
                    Text('Sign Out'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: const ShiftDashboardScreen(),
    );
  }
}

/// Home screen for managers with tab navigation between personal and team dashboards.
class _ManagerHomeScreen extends StatelessWidget {
  final VoidCallback onSignOut;
  final VoidCallback onProfile;
  final VoidCallback onHistory;
  final VoidCallback onEmployeeHistory;
  final VoidCallback onUserManagement;
  final bool isAdmin;

  const _ManagerHomeScreen({
    required this.onSignOut,
    required this.onProfile,
    required this.onHistory,
    required this.onEmployeeHistory,
    required this.onUserManagement,
    required this.isAdmin,
  });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(AppConstants.appName),
          centerTitle: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Shift History',
              onPressed: onHistory,
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                switch (value) {
                  case 'profile':
                    onProfile();
                    break;
                  case 'employee_history':
                    onEmployeeHistory();
                    break;
                  case 'user_management':
                    onUserManagement();
                    break;
                  case 'signout':
                    onSignOut();
                    break;
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'profile',
                  child: Row(
                    children: [
                      Icon(Icons.person_outline),
                      SizedBox(width: 12),
                      Text('Profile'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'employee_history',
                  child: Row(
                    children: [
                      Icon(Icons.groups),
                      SizedBox(width: 12),
                      Text('Employee History'),
                    ],
                  ),
                ),
                if (isAdmin)
                  const PopupMenuItem(
                    value: 'user_management',
                    child: Row(
                      children: [
                        Icon(Icons.admin_panel_settings),
                        SizedBox(width: 12),
                        Text('User Management'),
                      ],
                    ),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'signout',
                  child: Row(
                    children: [
                      Icon(Icons.logout),
                      SizedBox(width: 12),
                      Text('Sign Out'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(
                icon: Icon(Icons.person),
                text: 'My Dashboard',
              ),
              Tab(
                icon: Icon(Icons.groups),
                text: 'Team',
              ),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            ShiftDashboardScreen(),
            TeamDashboardScreen(),
          ],
        ),
      ),
    );
  }
}

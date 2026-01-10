import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/constants.dart';
import '../../shared/providers/supabase_provider.dart';
import '../auth/providers/profile_provider.dart';
import '../auth/screens/profile_screen.dart';
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch profile to determine if user is a manager
    final profileAsync = ref.watch(currentProfileProvider);
    final isManager = profileAsync.when(
      data: (profile) => profile?.isManager ?? false,
      loading: () => false,
      error: (_, __) => false,
    );

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
                case 'employee_history':
                  _navigateToEmployeeHistory(context);
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
              if (isManager)
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

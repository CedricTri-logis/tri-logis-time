import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/theme.dart';
import '../../shared/providers/supabase_provider.dart';
import '../auth/providers/app_lock_provider.dart';
import '../auth/services/biometric_service.dart';
import '../shifts/providers/shift_provider.dart';
import '../admin/screens/user_management_screen.dart';
import '../auth/providers/profile_provider.dart';
import '../auth/screens/profile_screen.dart';
import '../dashboard/screens/team_dashboard_screen.dart';
import '../history/screens/my_history_screen.dart';
import '../history/screens/supervised_employees_screen.dart';
import '../mileage/screens/mileage_screen.dart';
import '../shifts/screens/shift_dashboard_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _handleSignOut(BuildContext context, WidgetRef ref) async {
    final bio = ref.read(biometricServiceProvider);
    final biometricEnabled = await bio.isEnabled();

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Déconnexion'),
        content: const Text('Voulez-vous vraiment vous déconnecter ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Déconnexion'),
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

      if (biometricEnabled) {
        // App-lock pattern: save fresh tokens, then lock the app
        // WITHOUT calling signOut() (which would revoke the refresh token).
        final session = ref.read(supabaseClientProvider).auth.currentSession;
        if (session != null) {
          final phone = ref.read(supabaseClientProvider).auth.currentUser?.phone;
          await bio.saveSessionTokens(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken!,
            phone: (phone != null && phone.isNotEmpty) ? phone : null,
          );
        }

        // Lock the app → app.dart shows SignInScreen, session stays alive
        ref.read(appLockProvider.notifier).state = true;
      } else {
        // No biometric → regular sign-out (revokes session)
        final authService = ref.read(authServiceProvider);
        await authService.signOut();
      }
      // Navigation handled automatically by auth/lock state in app.dart
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

  void _navigateToMileage(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const MileageScreen()),
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
        onMileage: () => _navigateToMileage(context),
        onEmployeeHistory: () => _navigateToEmployeeHistory(context),
        onUserManagement: () => _navigateToUserManagement(context),
        isAdmin: isAdmin,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 36, maxWidth: 140),
          child: Image.asset(
            'assets/images/logo.png',
            fit: BoxFit.contain,
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        shadowColor: Colors.black.withValues(alpha: 0.1),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(
            height: 1.0,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  TriLogisColors.red, // TriLogis Red
                  TriLogisColors.gold, // TriLogis Gold
                ],
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.history,
              color: TriLogisColors.red,
              size: 28,
            ),
            tooltip: 'Historique des quarts',
            onPressed: () => _navigateToHistory(context),
          ),
          PopupMenuButton<String>(
            icon: const Icon(
              Icons.more_vert,
              color: TriLogisColors.red,
              size: 28,
            ),
            onSelected: (value) {
              switch (value) {
                case 'mileage':
                  _navigateToMileage(context);
                  break;
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
                value: 'mileage',
                child: Row(
                  children: [
                    Icon(Icons.directions_car_outlined, color: TriLogisColors.red),
                    SizedBox(width: 12),
                    Text('Kilométrage'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'profile',
                child: Row(
                  children: [
                    Icon(Icons.person_outline, color: TriLogisColors.red),
                    SizedBox(width: 12),
                    Text('Profil'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'signout',
                child: Row(
                  children: [
                    Icon(Icons.logout, color: TriLogisColors.red),
                    SizedBox(width: 12),
                    Text('Déconnexion'),
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
  final VoidCallback onMileage;
  final VoidCallback onEmployeeHistory;
  final VoidCallback onUserManagement;
  final bool isAdmin;

  const _ManagerHomeScreen({
    required this.onSignOut,
    required this.onProfile,
    required this.onHistory,
    required this.onMileage,
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
          title: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 36, maxWidth: 140),
            child: Image.asset(
              'assets/images/logo.png',
              fit: BoxFit.contain,
            ),
          ),
          centerTitle: true,
          backgroundColor: Colors.white,
          elevation: 0,
          surfaceTintColor: Colors.white,
          shadowColor: Colors.black.withValues(alpha: 0.1),
          actions: [
            IconButton(
              icon: const Icon(
                Icons.history,
                color: TriLogisColors.red,
                size: 28,
              ),
              tooltip: 'Historique des quarts',
              onPressed: onHistory,
            ),
            PopupMenuButton<String>(
              icon: const Icon(
                Icons.more_vert,
                color: TriLogisColors.red,
                size: 28,
              ),
              onSelected: (value) {
                switch (value) {
                  case 'mileage':
                    onMileage();
                    break;
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
                  value: 'mileage',
                  child: Row(
                    children: [
                      Icon(Icons.directions_car_outlined, color: TriLogisColors.red),
                      SizedBox(width: 12),
                      Text('Kilométrage'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'profile',
                  child: Row(
                    children: [
                      Icon(Icons.person_outline, color: TriLogisColors.red),
                      SizedBox(width: 12),
                      Text('Profil'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'employee_history',
                  child: Row(
                    children: [
                      Icon(Icons.groups, color: TriLogisColors.red),
                      SizedBox(width: 12),
                      Text('Historique employés'),
                    ],
                  ),
                ),
                if (isAdmin)
                  const PopupMenuItem(
                    value: 'user_management',
                    child: Row(
                      children: [
                        Icon(Icons.admin_panel_settings, color: TriLogisColors.red),
                        SizedBox(width: 12),
                        Text('Gestion des utilisateurs'),
                      ],
                    ),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'signout',
                  child: Row(
                    children: [
                      Icon(Icons.logout, color: TriLogisColors.red),
                      SizedBox(width: 12),
                      Text('Déconnexion'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          bottom: TabBar(
            indicatorColor: TriLogisColors.red, // TriLogis Red
            labelColor: TriLogisColors.red,
            unselectedLabelColor: Colors.grey[600],
            tabs: const [
              Tab(
                icon: Icon(Icons.person),
                text: 'Mon tableau de bord',
              ),
              Tab(
                icon: Icon(Icons.groups),
                text: 'Équipe',
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

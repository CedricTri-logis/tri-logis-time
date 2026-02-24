import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/supervised_employees_provider.dart';
import '../widgets/employee_list_tile.dart';
import 'employee_history_screen.dart';

/// Screen displaying the list of employees supervised by the current manager
class SupervisedEmployeesScreen extends ConsumerStatefulWidget {
  const SupervisedEmployeesScreen({super.key});

  @override
  ConsumerState<SupervisedEmployeesScreen> createState() =>
      _SupervisedEmployeesScreenState();
}

class _SupervisedEmployeesScreenState
    extends ConsumerState<SupervisedEmployeesScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    // Load employees when screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(supervisedEmployeesProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(supervisedEmployeesProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Historique employés'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: state.isLoading
                ? null
                : () => ref.read(supervisedEmployeesProvider.notifier).refresh(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Rechercher un employé...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
              ),
              onChanged: (value) {
                setState(() => _searchQuery = value);
              },
            ),
          ),
          // Content
          Expanded(
            child: _buildContent(state, theme),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(SupervisedEmployeesState state, ThemeData theme) {
    if (state.isLoading && state.employees.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.error != null && state.employees.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                state.error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () =>
                    ref.read(supervisedEmployeesProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh),
                label: const Text('Réessayer'),
              ),
            ],
          ),
        ),
      );
    }

    // Filter employees based on search
    final filteredEmployees = ref.read(filteredEmployeesProvider(_searchQuery));

    if (filteredEmployees.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _searchQuery.isEmpty ? Icons.people_outline : Icons.search_off,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isEmpty
                  ? 'Aucun employé à superviser'
                  : 'Aucun employé ne correspond à votre recherche',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(supervisedEmployeesProvider.notifier).refresh(),
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: filteredEmployees.length,
        itemBuilder: (context, index) {
          final employee = filteredEmployees[index];
          return EmployeeListTile(
            employee: employee,
            onTap: () => _navigateToHistory(employee.id, employee.displayName),
          );
        },
      ),
    );
  }

  void _navigateToHistory(String employeeId, String employeeName) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => EmployeeHistoryScreen(
          employeeId: employeeId,
          employeeName: employeeName,
        ),
      ),
    );
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/supabase_provider.dart';
import '../models/employee_summary.dart';
import '../services/history_service.dart';

/// Provider for the HistoryService
final historyServiceProvider = Provider<HistoryService>((ref) {
  return HistoryService(ref.watch(supabaseClientProvider));
});

/// State for supervised employees list
class SupervisedEmployeesState {
  final List<EmployeeSummary> employees;
  final bool isLoading;
  final String? error;

  const SupervisedEmployeesState({
    this.employees = const [],
    this.isLoading = false,
    this.error,
  });

  SupervisedEmployeesState copyWith({
    List<EmployeeSummary>? employees,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return SupervisedEmployeesState(
      employees: employees ?? this.employees,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Notifier for managing supervised employees state
class SupervisedEmployeesNotifier
    extends StateNotifier<SupervisedEmployeesState> {
  final HistoryService _historyService;

  SupervisedEmployeesNotifier(this._historyService)
      : super(const SupervisedEmployeesState());

  /// Load the list of supervised employees
  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final employees = await _historyService.getSupervisedEmployees();
      state = state.copyWith(
        employees: employees,
        isLoading: false,
      );
    } on HistoryServiceException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load employees: $e',
      );
    }
  }

  /// Refresh the employee list
  Future<void> refresh() async {
    await load();
  }

  /// Search/filter employees by name or employee ID (client-side)
  List<EmployeeSummary> filterBySearch(String query) {
    if (query.isEmpty) return state.employees;

    final lowerQuery = query.toLowerCase();
    return state.employees.where((employee) {
      return employee.displayName.toLowerCase().contains(lowerQuery) ||
          (employee.employeeId?.toLowerCase().contains(lowerQuery) ?? false) ||
          employee.email.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// Clear any error state
  void clearError() {
    state = state.copyWith(clearError: true);
  }
}

/// Provider for supervised employees state
final supervisedEmployeesProvider = StateNotifierProvider<
    SupervisedEmployeesNotifier, SupervisedEmployeesState>((ref) {
  return SupervisedEmployeesNotifier(ref.watch(historyServiceProvider));
});

/// Provider for the filtered employee list based on search query
final filteredEmployeesProvider =
    Provider.family<List<EmployeeSummary>, String>((ref, query) {
  final notifier = ref.watch(supervisedEmployeesProvider.notifier);
  return notifier.filterBySearch(query);
});

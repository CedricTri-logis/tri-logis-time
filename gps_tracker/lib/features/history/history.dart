/// Employee History Feature
///
/// Provides managers with access to supervised employees' shift history,
/// with filtering, statistics, export, and GPS route visualization.
library;

// Models
export 'models/employee_summary.dart';
export 'models/history_statistics.dart';
export 'models/shift_history_filter.dart';
export 'models/supervision_record.dart';

// Services
export 'services/export_service.dart';
export 'services/history_service.dart';
export 'services/statistics_service.dart';

// Providers
export 'providers/employee_history_provider.dart';
export 'providers/history_filter_provider.dart';
export 'providers/history_statistics_provider.dart';
export 'providers/supervised_employees_provider.dart';

// Widgets
export 'widgets/employee_list_tile.dart';
export 'widgets/export_dialog.dart';
export 'widgets/gps_route_map.dart';
export 'widgets/history_filter_bar.dart';
export 'widgets/shift_history_card.dart';
export 'widgets/statistics_card.dart';

// Screens
export 'screens/employee_history_screen.dart';
export 'screens/my_history_screen.dart';
export 'screens/shift_detail_screen.dart';
export 'screens/statistics_screen.dart';
export 'screens/supervised_employees_screen.dart';

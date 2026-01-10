/// Dashboard feature module - Employee & Shift Dashboard
///
/// Provides personalized dashboards for employees and managers:
/// - Employee dashboard: shift status, today's/monthly stats, recent shifts
/// - Manager dashboard: team overview, search/filter, team statistics
library dashboard;

// Models
export 'models/dashboard_state.dart';
export 'models/team_dashboard_state.dart';
export 'models/employee_work_status.dart';

// Services
export 'services/dashboard_service.dart';
export 'services/dashboard_cache_service.dart';

// Providers
export 'providers/dashboard_provider.dart';
export 'providers/team_dashboard_provider.dart';
export 'providers/team_statistics_provider.dart';

// Screens
export 'screens/employee_dashboard_screen.dart';
export 'screens/team_dashboard_screen.dart';
export 'screens/team_statistics_screen.dart';

// Widgets
export 'widgets/shift_status_tile.dart';
export 'widgets/live_shift_timer.dart';
export 'widgets/daily_summary_card.dart';
export 'widgets/monthly_summary_card.dart';
export 'widgets/recent_shifts_list.dart';
export 'widgets/sync_status_badge.dart';
export 'widgets/team_employee_tile.dart';
export 'widgets/team_search_bar.dart';
export 'widgets/date_range_picker.dart';
export 'widgets/team_hours_chart.dart';

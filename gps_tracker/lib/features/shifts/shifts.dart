/// Barrel export file for the shifts feature.
library shifts;

// Models
export 'models/geo_point.dart';
export 'models/local_gps_point.dart';
export 'models/local_shift.dart';
export 'models/shift.dart';
export 'models/shift_enums.dart';
export 'models/shift_summary.dart';

// Services
export 'services/connectivity_service.dart';
export 'services/location_service.dart';
export 'services/shift_service.dart';
export 'services/sync_service.dart';

// Providers
export 'providers/connectivity_provider.dart';
export 'providers/location_provider.dart';
export 'providers/shift_history_provider.dart';
export 'providers/shift_provider.dart';
export 'providers/sync_provider.dart';

// Screens
export 'screens/shift_dashboard_screen.dart';
export 'screens/shift_detail_screen.dart';
export 'screens/shift_history_screen.dart';

// Widgets
export 'widgets/clock_button.dart';
export 'widgets/clock_out_confirmation_sheet.dart';
export 'widgets/shift_card.dart';
export 'widgets/shift_status_card.dart';
export 'widgets/shift_summary_card.dart';
export 'widgets/shift_timer.dart';
export 'widgets/sync_status_indicator.dart';

<!--
Sync Impact Report
==================
Version change: 0.0.0 → 1.0.0 (Initial ratification)
Added sections:
  - Principle I: Mobile-First Flutter
  - Principle II: Battery-Conscious Design
  - Principle III: Privacy & Compliance
  - Principle IV: Offline-First Architecture
  - Principle V: Simplicity & Maintainability
  - Section: Platform Requirements
  - Section: Development Workflow
  - Governance rules
Templates requiring updates:
  - .specify/templates/plan-template.md ✅ (no changes needed - generic)
  - .specify/templates/spec-template.md ✅ (no changes needed - generic)
  - .specify/templates/tasks-template.md ✅ (no changes needed - generic)
Follow-up TODOs: None
-->

# GPS Tracker Constitution

## Core Principles

### I. Mobile-First Flutter

All features MUST be developed using Flutter for cross-platform deployment (iOS and Android) from a single codebase.

- Flutter is the ONLY approved framework for this project
- All UI components MUST use Flutter's Material Design or Cupertino widgets appropriately per platform
- Platform-specific code (iOS/Android) MUST be minimized and isolated in clearly marked platform channels
- Dependencies MUST be compatible with both iOS and Android platforms before adoption

**Rationale**: Single codebase reduces maintenance burden, ensures feature parity, and maximizes Claude Code's ability to assist with well-documented Flutter APIs.

### II. Battery-Conscious Design

All background operations MUST be designed to minimize battery consumption while maintaining required functionality.

- GPS polling interval MUST be configurable (default: 5 minutes when clocked in)
- Background location tracking MUST use platform-optimized approaches (iOS Background Modes, Android Foreground Service)
- App MUST stop all GPS tracking when employee clocks out
- Battery impact MUST be documented and tested on real devices before release
- Users MUST be informed of battery usage expectations

**Rationale**: Employee devices are personal property; excessive battery drain reduces adoption and trust.

### III. Privacy & Compliance

All location data handling MUST respect employee privacy and comply with applicable regulations.

- Location tracking MUST only occur while employee is actively clocked in
- Employees MUST provide explicit consent before any location tracking begins
- GPS data MUST be transmitted securely (HTTPS/TLS) to Supabase backend
- No location data MUST be collected outside of work hours
- Clear privacy policy MUST be displayed and accepted before first use
- Data retention policies MUST be documented and enforced

**Rationale**: Employee GPS tracking has legal implications; clear boundaries protect both employer and employee.

### IV. Offline-First Architecture

The app MUST function reliably even with intermittent or no network connectivity.

- Clock in/out actions MUST work offline and sync when connectivity returns
- GPS data points MUST be stored locally when offline and batch-uploaded when online
- App MUST clearly indicate sync status to users
- Local storage MUST be encrypted on device
- Conflict resolution strategy MUST be defined for offline/online sync scenarios

**Rationale**: Employees work in various environments including areas with poor cellular coverage; the app must remain functional.

### V. Simplicity & Maintainability

The codebase MUST remain simple, focused, and maintainable by AI-assisted development.

- Features MUST directly serve the core use case: employee clock-in with GPS tracking
- No feature creep: additions require explicit justification against core mission
- Code MUST be self-documenting with clear naming conventions
- Complex logic MUST include inline comments explaining the "why"
- Third-party dependencies MUST be minimized and well-maintained packages preferred
- YAGNI (You Aren't Gonna Need It) principle applies to all decisions

**Rationale**: A focused app is easier to maintain, test, and extend; AI assistance works best with clear, conventional code.

## Platform Requirements

### iOS Requirements

- Minimum deployment target: iOS 14.0
- MUST request "Always" location permission with clear justification string
- MUST use Background Modes capability for location updates
- MUST display background location indicator when tracking

### Android Requirements

- Minimum SDK: API 24 (Android 7.0)
- Target SDK: Latest stable
- MUST use Foreground Service for background location tracking
- MUST display persistent notification when tracking is active
- MUST handle Android battery optimization settings gracefully

### Backend Requirements (Supabase)

- Authentication: Supabase Auth with email/password
- Database: PostgreSQL via Supabase
- Row Level Security (RLS) MUST be enabled on all tables
- API calls MUST use Supabase client library (supabase_flutter)

## Development Workflow

### Distribution Strategy

- iOS: TestFlight for beta distribution (up to 10,000 testers)
- Android: Google Play Internal Testing track (up to 100 testers)
- No public App Store/Play Store release required for initial deployment

### Testing Requirements

- Critical paths (clock in, clock out, GPS capture) MUST have integration tests
- Background location behavior MUST be manually tested on physical devices
- Battery consumption MUST be measured and documented

### Code Review Standards

- All changes MUST be reviewed for compliance with this constitution
- Security-sensitive changes (auth, location permissions, data transmission) require extra scrutiny
- Platform-specific code requires testing on both iOS and Android before merge

## Governance

This constitution defines non-negotiable principles for the GPS Tracker project. All development decisions MUST align with these principles.

- **Amendments**: Changes to this constitution require documented justification and version increment
- **Compliance**: All code reviews MUST verify adherence to constitutional principles
- **Exceptions**: Any deviation from principles MUST be documented in code comments with rationale
- **Versioning**: Constitution follows semantic versioning (MAJOR.MINOR.PATCH)
  - MAJOR: Principle removal or fundamental redefinition
  - MINOR: New principle added or significant expansion
  - PATCH: Clarifications and wording improvements

**Version**: 1.0.0 | **Ratified**: 2026-01-08 | **Last Amended**: 2026-01-08

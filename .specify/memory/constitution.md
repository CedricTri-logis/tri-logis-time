<!--
Sync Impact Report
==================
Version change: 1.0.0 → 1.1.0 (MINOR - new principle added)
Modified principles:
  - Principle I: "Mobile-First Flutter" → "Mobile App: Flutter Cross-Platform" (renamed for clarity)
  - Principles II-V renumbered to III-VI
Added sections:
  - Principle II: Desktop Dashboard: TypeScript Web Stack (NEW)
  - Platform Requirements: Web/Desktop Requirements (NEW)
  - Backend Requirements: Manager access additions
Removed sections: None
Templates requiring updates:
  - .specify/templates/plan-template.md: ✅ No changes needed (generic)
  - .specify/templates/spec-template.md: ✅ No changes needed (generic)
  - .specify/templates/tasks-template.md: ✅ No changes needed (generic)
  - .specify/templates/checklist-template.md: ✅ No changes needed (generic)
Follow-up TODOs: None
-->

# GPS Tracker Constitution

## Core Principles

### I. Mobile App: Flutter Cross-Platform

All mobile features MUST be developed using Flutter for cross-platform deployment (iOS and Android) from a single codebase.

- Flutter is the approved framework for the mobile employee app
- All mobile UI components MUST use Flutter's Material Design or Cupertino widgets appropriately per platform
- Platform-specific code (iOS/Android) MUST be minimized and isolated in clearly marked platform channels
- Dependencies MUST be compatible with both iOS and Android platforms before adoption
- Mobile app targets employees for clock-in/out and GPS tracking

**Rationale**: Single codebase reduces maintenance burden, ensures feature parity, and maximizes AI assistance with well-documented Flutter APIs.

### II. Desktop Dashboard: TypeScript Web Stack

The manager dashboard MUST be built with the approved TypeScript web stack for optimal AI assistance and ADMIN project compatibility.

- Framework: Next.js 14+ with App Router (not Pages Router)
- Language: TypeScript with strict mode enabled
- UI Components: shadcn/ui (Tailwind CSS + Radix primitives)
- Data Layer: Refine with @refinedev/supabase provider
- Styling: Tailwind CSS only (no CSS-in-JS, no custom CSS files)
- Validation: Zod schemas for all form inputs and API responses
- MUST use Refine data hooks (useTable, useForm, useList, useOne) instead of custom fetch logic
- MUST use shadcn/ui components instead of creating custom UI primitives
- Desktop dashboard targets managers/supervisors for monitoring and reporting

**Rationale**: This stack aligns with the ADMIN Data Room project for eventual integration, maximizes AI code generation accuracy (shadcn/v0.dev), and leverages Refine's structured CRUD patterns to eliminate boilerplate.

### III. Battery-Conscious Design

All background operations MUST be designed to minimize battery consumption while maintaining required functionality.

- GPS polling interval MUST be configurable (default: 5 minutes when clocked in)
- Background location tracking MUST use platform-optimized approaches (iOS Background Modes, Android Foreground Service)
- App MUST stop all GPS tracking when employee clocks out
- Battery impact MUST be documented and tested on real devices before release
- Users MUST be informed of battery usage expectations

**Rationale**: Employee devices are personal property; excessive battery drain reduces adoption and trust.

### IV. Privacy & Compliance

All location data handling MUST respect employee privacy and comply with applicable regulations.

- Location tracking MUST only occur while employee is actively clocked in
- Employees MUST provide explicit consent before any location tracking begins
- GPS data MUST be transmitted securely (HTTPS/TLS) to Supabase backend
- No location data MUST be collected outside of work hours
- Clear privacy policy MUST be displayed and accepted before first use
- Data retention policies MUST be documented and enforced
- Manager dashboard MUST only display data for employees under their supervision

**Rationale**: Employee GPS tracking has legal implications; clear boundaries protect both employer and employee.

### V. Offline-First Architecture

The mobile app MUST function reliably even with intermittent or no network connectivity.

- Clock in/out actions MUST work offline and sync when connectivity returns
- GPS data points MUST be stored locally when offline and batch-uploaded when online
- App MUST clearly indicate sync status to users
- Local storage MUST be encrypted on device
- Conflict resolution strategy MUST be defined for offline/online sync scenarios

**Rationale**: Employees work in various environments including areas with poor cellular coverage; the app must remain functional.

### VI. Simplicity & Maintainability

Both codebases MUST remain simple, focused, and maintainable by AI-assisted development.

- Features MUST directly serve the core use case: employee clock-in with GPS tracking (mobile) or workforce monitoring (dashboard)
- No feature creep: additions require explicit justification against core mission
- Code MUST be self-documenting with clear naming conventions
- Complex logic MUST include inline comments explaining the "why"
- Third-party dependencies MUST be minimized and well-maintained packages preferred
- YAGNI (You Aren't Gonna Need It) principle applies to all decisions
- Both Flutter and TypeScript codebases MUST follow their respective community conventions

**Rationale**: A focused app is easier to maintain, test, and extend; AI assistance works best with clear, conventional code.

## Platform Requirements

### iOS Requirements (Mobile App)

- Minimum deployment target: iOS 14.0
- MUST request "Always" location permission with clear justification string
- MUST use Background Modes capability for location updates
- MUST display background location indicator when tracking

### Android Requirements (Mobile App)

- Minimum SDK: API 24 (Android 7.0)
- Target SDK: Latest stable
- MUST use Foreground Service for background location tracking
- MUST display persistent notification when tracking is active
- MUST handle Android battery optimization settings gracefully

### Web/Desktop Requirements (Manager Dashboard)

- Minimum Node.js: 18.x LTS
- Target browsers: Chrome, Safari, Firefox (latest 2 versions)
- MUST use Next.js App Router architecture
- MUST use Refine data hooks for all CRUD operations
- MUST use shadcn/ui components for UI consistency
- MUST connect to same Supabase instance as mobile app
- Desktop-first design (mobile responsiveness is optional)

### Backend Requirements (Supabase - Shared)

- Authentication: Supabase Auth with email/password
- Database: PostgreSQL via Supabase
- Row Level Security (RLS) MUST be enabled on all tables
- Mobile API calls MUST use supabase_flutter client library
- Dashboard API calls MUST use @supabase/supabase-js or @refinedev/supabase
- RLS policies MUST support both employee (own data) and manager (all employee data) access patterns
- Manager role MUST be defined and enforced at database level

## Development Workflow

### Distribution Strategy

**Mobile App:**
- iOS: TestFlight for beta distribution (up to 10,000 testers)
- Android: Google Play Internal Testing track (up to 100 testers)
- No public App Store/Play Store release required for initial deployment

**Manager Dashboard:**
- Vercel deployment for web hosting
- Protected by Supabase Auth (manager role required)

### Testing Requirements

**Mobile App:**
- Critical paths (clock in, clock out, GPS capture) MUST have integration tests
- Background location behavior MUST be manually tested on physical devices
- Battery consumption MUST be measured and documented

**Manager Dashboard:**
- Playwright for E2E testing of critical flows
- Component testing for complex UI interactions
- API integration tests for data layer

### Code Review Standards

- All changes MUST be reviewed for compliance with this constitution
- Security-sensitive changes (auth, location permissions, data transmission) require extra scrutiny
- Mobile platform-specific code requires testing on both iOS and Android before merge
- Dashboard changes require browser testing on Chrome and Safari minimum

## Governance

This constitution defines non-negotiable principles for the GPS Tracker project (mobile app and manager dashboard). All development decisions MUST align with these principles.

- **Amendments**: Changes to this constitution require documented justification and version increment
- **Compliance**: All code reviews MUST verify adherence to constitutional principles
- **Exceptions**: Any deviation from principles MUST be documented in code comments with rationale
- **Versioning**: Constitution follows semantic versioning (MAJOR.MINOR.PATCH)
  - MAJOR: Principle removal or fundamental redefinition
  - MINOR: New principle added or significant expansion
  - PATCH: Clarifications and wording improvements

**Version**: 1.1.0 | **Ratified**: 2026-01-08 | **Last Amended**: 2026-01-10

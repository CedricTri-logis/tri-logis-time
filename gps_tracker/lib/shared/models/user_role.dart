/// User role enumeration for access control
///
/// Defines the access levels for employees within the GPS tracking system:
/// - `employee`: Standard user who can only view their own data
/// - `manager`: Can view data for supervised employees
/// - `admin`: Full system access including supervision management
enum UserRole {
  employee('employee'),
  manager('manager'),
  admin('admin');

  final String value;
  const UserRole(this.value);

  /// Parse a role string from the database into a UserRole enum
  static UserRole fromString(String value) {
    return UserRole.values.firstWhere(
      (e) => e.value == value,
      orElse: () => UserRole.employee,
    );
  }

  /// Whether this role has manager capabilities (can view supervised employees)
  bool get isManager => this == UserRole.manager || this == UserRole.admin;

  /// Whether this role has admin capabilities (full system access)
  bool get isAdmin => this == UserRole.admin;
}

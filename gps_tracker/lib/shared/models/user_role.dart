/// User role enumeration for access control
///
/// Defines the access levels for employees within the GPS tracking system:
/// - `employee`: Standard user who can only view their own data
/// - `manager`: Can view data for supervised employees
/// - `admin`: Full system access including supervision management, can see all employees
/// - `superAdmin`: Protected admin that cannot be demoted, can assign any role
enum UserRole {
  employee('employee'),
  manager('manager'),
  admin('admin'),
  superAdmin('super_admin');

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
  bool get isManager =>
      this == UserRole.manager ||
      this == UserRole.admin ||
      this == UserRole.superAdmin;

  /// Whether this role has admin capabilities (full system access)
  bool get isAdmin => this == UserRole.admin || this == UserRole.superAdmin;

  /// Whether this role is super admin (protected, cannot be demoted)
  bool get isSuperAdmin => this == UserRole.superAdmin;

  /// Whether this role can manage other users' roles
  bool get canManageRoles => isAdmin;

  /// Display name for the role
  String get displayName {
    switch (this) {
      case UserRole.employee:
        return 'Employee';
      case UserRole.manager:
        return 'Manager';
      case UserRole.admin:
        return 'Admin';
      case UserRole.superAdmin:
        return 'Super Admin';
    }
  }
}

/// Exception thrown when local database operations fail.
class LocalDatabaseException implements Exception {
  final String message;
  final String? operation;
  final dynamic originalError;

  LocalDatabaseException(
    this.message, {
    this.operation,
    this.originalError,
  });

  @override
  String toString() {
    final buffer = StringBuffer('LocalDatabaseException: $message');
    if (operation != null) {
      buffer.write(' (operation: $operation)');
    }
    if (originalError != null) {
      buffer.write('\nOriginal error: $originalError');
    }
    return buffer.toString();
  }
}

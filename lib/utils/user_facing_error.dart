import '../backend/interfaces/auth_service_interface.dart';

String describeUserFacingError({
  required AuthServiceInterface authService,
  required Object error,
  required String fallbackMessage,
}) {
  final description = authService.describeError(error).trim();
  if (description.isEmpty) {
    return fallbackMessage;
  }

  final raw = error.toString().trim();
  final normalized = description.toLowerCase();
  const technicalMarkers = <String>[
    'exception',
    'typeerror',
    'stateerror',
    'socketexception',
    'httpexception',
    'failed to',
    'backend (',
    'no such method',
  ];

  final looksTechnical = description == raw ||
      technicalMarkers.any((marker) => normalized.contains(marker));
  return looksTechnical ? fallbackMessage : description;
}

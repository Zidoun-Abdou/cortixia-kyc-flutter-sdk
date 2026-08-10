import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
// Import required for Timer
import 'dart:async';
// Import required for NfcProvider (from dmrtd package)
import 'package:dmrtd/dmrtd.dart';
// Helper function for date formatting from MRZ
String formatMrzDate(String date, String type) {
  bool isLeapYear(String type, String yearPart) {
    int year = 2000 + int.parse(yearPart);
    return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
  }

  int getFullYear(String type, String yearPart) {
    int year = int.parse(yearPart);
    if (type == 'e') return 2000 + year;
    if (type == 'b') return (year < 30) ? 2000 + year : 1900 + year;
    return 0;
  }

  if (date.length != 6 || !RegExp(r'^\d{6}$').hasMatch(date)) return "";

  String yearPart = date.substring(0, 2);
  String month = date.substring(2, 4);
  String day = date.substring(4, 6);

  int monthInt = int.parse(month);
  if (monthInt < 1 || monthInt > 12) return "";

  int dayInt = int.parse(day);
  if (dayInt < 1 || dayInt > 31) return "";

  if (month == '02' && (dayInt > (isLeapYear(type, yearPart) ? 29 : 28)))
    return "";
  if (['04', '06', '09', '11'].contains(month) && dayInt > 30) return "";

  int fullYear = getFullYear(type, yearPart);
  if (fullYear == 0) return "";

  return "$month/$day/$fullYear";
}

// Convert NV21 camera image to InputImage for ML Kit
Future<InputImage?> convertNV21CameraImageToInputImage(
    CameraImage image, InputImageRotation rotation) async {
  final format = InputImageFormatValue.fromRawValue(image.format.raw);

  if (format == InputImageFormat.nv21) {
    return InputImage.fromBytes(
      bytes: image.planes[0].bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  } else {
    print('Unsupported format: $format');
    return null;
  }
}

// Format file size to human readable
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

// Validate email format
bool isValidEmail(String email) {
  final emailRegex = RegExp(
      r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
  );
  return emailRegex.hasMatch(email);
}

// Format date for display
String formatDate(DateTime date) {
  final months = [
    'Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
    'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre'
  ];

  return '${date.day} ${months[date.month - 1]} ${date.year}';
}

// Format time for display
String formatTime(DateTime date) {
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

// Generate unique filename
String generateUniqueFileName(String prefix, String extension) {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  return '${prefix}_$timestamp.$extension';
}

// Validate ID card number (Algerian format)
bool isValidIdNumber(String idNumber) {
  // Algerian ID cards have 9 digit numbers
  return RegExp(r'^\d{9}$').hasMatch(idNumber);
}

// Parse ISO date string safely
DateTime? parseDate(String dateStr) {
  try {
    return DateTime.parse(dateStr);
  } catch (e) {
    return null;
  }
}

// Convert date to ISO format
String toIsoDate(String usDate) {
  // Convert MM/DD/YYYY to YYYY-MM-DD
  final parts = usDate.split('/');
  if (parts.length == 3) {
    return '${parts[2]}-${parts[0].padLeft(2, '0')}-${parts[1].padLeft(2, '0')}';
  }
  return usDate;
}

// Sanitize filename
String sanitizeFileName(String name) {
  // Remove special characters and spaces
  return name
      .replaceAll(RegExp(r'[^\w\s-]'), '')
      .replaceAll(RegExp(r'\s+'), '_')
      .toLowerCase();
}

// Calculate age from birth date
int calculateAge(DateTime birthDate) {
  final now = DateTime.now();
  int age = now.year - birthDate.year;

  if (now.month < birthDate.month ||
      (now.month == birthDate.month && now.day < birthDate.day)) {
    age--;
  }

  return age;
}

// Check if ID card is expired
bool isCardExpired(String expiryDateStr) {
  try {
    // Parse date in MM/DD/YYYY format
    final parts = expiryDateStr.split('/');
    if (parts.length == 3) {
      final month = int.parse(parts[0]);
      final day = int.parse(parts[1]);
      final year = int.parse(parts[2]);

      final expiryDate = DateTime(year, month, day);
      return DateTime.now().isAfter(expiryDate);
    }
  } catch (e) {
    print('Error parsing expiry date: $e');
  }
  return false;
}

// Get remaining days until expiry
int getDaysUntilExpiry(String expiryDateStr) {
  try {
    // Parse date in MM/DD/YYYY format
    final parts = expiryDateStr.split('/');
    if (parts.length == 3) {
      final month = int.parse(parts[0]);
      final day = int.parse(parts[1]);
      final year = int.parse(parts[2]);

      final expiryDate = DateTime(year, month, day);
      final now = DateTime.now();

      if (expiryDate.isAfter(now)) {
        return expiryDate.difference(now).inDays;
      }
    }
  } catch (e) {
    print('Error calculating days until expiry: $e');
  }
  return 0;
}

// Format NIN (National Identity Number)
String formatNIN(String nin) {
  // Format as XXX-XXX-XXX-XXX for better readability
  if (nin.length == 12) {
    return '${nin.substring(0, 3)}-${nin.substring(3, 6)}-${nin.substring(6, 9)}-${nin.substring(9, 12)}';
  }
  return nin;
}

// Extension to capitalize first letter of string
extension StringExtension on String {
  String capitalize() {
    if (isEmpty) return this;
    return "${this[0].toUpperCase()}${substring(1).toLowerCase()}";
  }

  String capitalizeWords() {
    return split(' ').map((word) => word.capitalize()).join(' ');
  }
}

// Check if device has NFC capability
Future<bool> hasNfcCapability() async {
  try {
    final status = await NfcProvider.nfcStatus;
    return status != NfcStatus.notSupported;
  } catch (e) {
    return false;
  }
}

// Show success message with icon
Map<String, dynamic> successMessage(String message) {
  return {
    'icon': '✅',
    'color': 0xFF4CAF50, // Green color
    'message': message,
  };
}

// Show error message with icon
Map<String, dynamic> errorMessage(String message) {
  return {
    'icon': '❌',
    'color': 0xFFF44336, // Red color
    'message': message,
  };
}

// Show warning message with icon
Map<String, dynamic> warningMessage(String message) {
  return {
    'icon': '⚠️',
    'color': 0xFFFF9800, // Orange color
    'message': message,
  };
}

// Show info message with icon
Map<String, dynamic> infoMessage(String message) {
  return {
    'icon': 'ℹ️',
    'color': 0xFF2196F3, // Blue color
    'message': message,
  };
}

// Debounce function for search or input fields
class Debouncer {
  final int milliseconds;
  Timer? _timer;

  Debouncer({required this.milliseconds});

  void run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: milliseconds), action);
  }

  void dispose() {
    _timer?.cancel();
  }
}

// Validate OTP format
bool isValidOTP(String otp) {
  // OTP should be 6 digits
  return RegExp(r'^\d{6}$').hasMatch(otp);
}

// Format phone number for display
String formatPhoneNumber(String phone) {
  // Remove all non-digits
  final digitsOnly = phone.replaceAll(RegExp(r'\D'), '');

  // Format as +213 XXX XX XX XX for Algerian numbers
  if (digitsOnly.startsWith('213') && digitsOnly.length == 12) {
    return '+${digitsOnly.substring(0, 3)} ${digitsOnly.substring(3, 6)} ${digitsOnly.substring(6, 8)} ${digitsOnly.substring(8, 10)} ${digitsOnly.substring(10, 12)}';
  }

  // Format as 0XXX XX XX XX for local Algerian numbers
  if (digitsOnly.startsWith('0') && digitsOnly.length == 10) {
    return '${digitsOnly.substring(0, 4)} ${digitsOnly.substring(4, 6)} ${digitsOnly.substring(6, 8)} ${digitsOnly.substring(8, 10)}';
  }

  return phone;
}


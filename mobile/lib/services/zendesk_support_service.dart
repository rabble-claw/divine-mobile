// ABOUTME: Flutter wrapper for Zendesk Support (native SDK + REST API fallback)
// ABOUTME: Provides ticket creation via native iOS/Android SDKs or REST API for desktop

import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:openvine/config/zendesk_config.dart';
import 'package:openvine/utils/unified_logger.dart';

/// Service for interacting with Zendesk Support SDK
class ZendeskSupportService {
  static const MethodChannel _channel = MethodChannel(
    'com.openvine/zendesk_support',
  );

  static bool _initialized = false;

  /// Check if Zendesk is available (credentials configured and initialized)
  static bool get isAvailable => _initialized;

  /// Current user identity info (for REST API fallback)
  static String? _userName;
  static String? _userEmail;
  static String? _userNpub;

  /// JWT authentication state (for native SDK ticket history)
  static String? _cachedJwt;

  /// Initialize Zendesk SDK
  ///
  /// Call once at app startup. Returns true if initialization successful.
  /// Returns false if credentials missing or initialization fails.
  /// App continues to work with email fallback when returns false.
  static Future<bool> initialize({
    required String appId,
    required String clientId,
    required String zendeskUrl,
  }) async {
    // Skip if credentials missing
    if (appId.isEmpty || clientId.isEmpty || zendeskUrl.isEmpty) {
      Log.info(
        'Zendesk credentials not configured - bug reports will use email fallback',
        category: LogCategory.system,
      );
      return false;
    }

    try {
      final result = await _channel.invokeMethod('initialize', {
        'appId': appId,
        'clientId': clientId,
        'zendeskUrl': zendeskUrl,
      });

      _initialized = (result == true);

      if (_initialized) {
        Log.info(
          '✅ Zendesk initialized successfully',
          category: LogCategory.system,
        );
      } else {
        Log.warning(
          'Zendesk initialization failed - bug reports will use email fallback',
          category: LogCategory.system,
        );
      }

      return _initialized;
    } on PlatformException catch (e) {
      Log.error(
        'Zendesk initialization failed: ${e.code} - ${e.message}',
        category: LogCategory.system,
      );
      _initialized = false;
      return false;
    } catch (e) {
      Log.error(
        'Unexpected error initializing Zendesk: $e',
        category: LogCategory.system,
      );
      _initialized = false;
      return false;
    }
  }

  /// Set user identity for Zendesk tickets
  ///
  /// Call this after user login to associate tickets with the user.
  /// For Nostr users, we use:
  /// - name: Display name or NIP-05 identifier
  /// - email: NIP-05 identifier (if available) or npub-based email
  /// - npub: User's npub for reference in ticket body
  ///
  /// Returns true if identity was set successfully.
  static Future<bool> setUserIdentity({
    String? displayName,
    String? nip05,
    required String npub,
  }) async {
    // Store for REST API fallback
    _userNpub = npub;

    // Determine display name: prefer displayName, fall back to NIP-05, then npub
    final effectiveName = displayName?.isNotEmpty == true
        ? displayName!
        : nip05?.isNotEmpty == true
        ? nip05!
        : _formatNpubForDisplay(npub);

    // Determine email: use NIP-05 if it looks like an email, otherwise create synthetic email
    // NIP-05 format is user@domain which works as email identifier
    // Full npub (63 chars) is within RFC 5321 local-part limit (64 chars)
    final effectiveEmail = nip05?.isNotEmpty == true && nip05!.contains('@')
        ? nip05
        : '$npub@divine.video';

    _userName = effectiveName;
    _userEmail = effectiveEmail;

    Log.info(
      'Setting Zendesk user identity: $effectiveName ($effectiveEmail)',
      category: LogCategory.system,
    );

    // If native SDK is initialized, set identity there too
    if (_initialized) {
      try {
        final result = await _channel.invokeMethod('setUserIdentity', {
          'name': effectiveName,
          'email': effectiveEmail,
        });

        if (result == true) {
          Log.info(
            '✅ Zendesk user identity set successfully',
            category: LogCategory.system,
          );
          return true;
        } else {
          Log.warning(
            'Failed to set Zendesk user identity via native SDK',
            category: LogCategory.system,
          );
          // Still return true since REST API will use stored values
          return true;
        }
      } on PlatformException catch (e) {
        Log.warning(
          'Platform error setting Zendesk identity: ${e.code} - ${e.message}',
          category: LogCategory.system,
        );
        // Still return true since REST API will use stored values
        return true;
      } catch (e) {
        Log.warning(
          'Error setting Zendesk identity: $e',
          category: LogCategory.system,
        );
        // Still return true since REST API will use stored values
        return true;
      }
    }

    // Native SDK not initialized, but REST API will use stored values
    return true;
  }

  /// Clear user identity (call on logout)
  static Future<void> clearUserIdentity() async {
    _userName = null;
    _userEmail = null;
    _userNpub = null;
    _cachedJwt = null;

    if (_initialized) {
      try {
        await _channel.invokeMethod('clearUserIdentity');
        Log.info('Zendesk user identity cleared', category: LogCategory.system);
      } catch (e) {
        Log.warning(
          'Error clearing Zendesk identity: $e',
          category: LogCategory.system,
        );
      }
    }
  }

  /// Set anonymous identity (for non-logged-in users)
  ///
  /// Sets a plain anonymous identity without name/email so Zendesk widget works.
  /// Should be called before showing ticket screens if user is not logged in.
  static Future<void> setAnonymousIdentity() async {
    if (_initialized) {
      try {
        await _channel.invokeMethod('setAnonymousIdentity');
        Log.info(
          'Zendesk anonymous identity set',
          category: LogCategory.system,
        );
      } catch (e) {
        Log.warning(
          'Error setting Zendesk anonymous identity: $e',
          category: LogCategory.system,
        );
      }
    }
  }

  // ==========================================================================
  // JWT Authentication (for native SDK ticket history)
  // ==========================================================================

  /// Fetch a JWT from the relay manager for Zendesk SDK authentication
  ///
  /// The JWT contains external_id (pubkey) which links tickets created via
  /// REST API to the native SDK's "View Past Messages" feature.
  ///
  /// Returns the JWT string on success, null on failure.
  static Future<String?> fetchJwt({
    required String pubkey,
    String? displayName,
    String? email,
  }) async {
    if (!ZendeskConfig.isJwtAvailable) {
      Log.warning(
        '🎫 Zendesk JWT: RELAY_MANAGER_URL not configured',
        category: LogCategory.system,
      );
      return null;
    }

    try {
      Log.info(
        '🎫 Zendesk JWT: Fetching from relay manager',
        category: LogCategory.system,
      );

      final response = await http.post(
        Uri.parse('${ZendeskConfig.relayManagerUrl}/api/zendesk/mobile-jwt'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'pubkey': pubkey,
          if (displayName != null) 'name': displayName,
          if (email != null) 'email': email,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['success'] == true && data['jwt'] != null) {
          _cachedJwt = data['jwt'] as String;
          Log.info(
            '✅ Zendesk JWT: Fetched successfully',
            category: LogCategory.system,
          );
          return _cachedJwt;
        }
      }

      Log.warning(
        '⚠️ Zendesk JWT: Failed to fetch - ${response.statusCode}',
        category: LogCategory.system,
      );
      return null;
    } catch (e) {
      Log.error(
        '❌ Zendesk JWT: Error fetching - $e',
        category: LogCategory.system,
      );
      return null;
    }
  }

  /// Set JWT identity on the native Zendesk SDK
  ///
  /// Pass the user's npub as the userToken. Zendesk will call our JWT endpoint
  /// with this token to get the actual JWT for authentication.
  ///
  /// Returns true if identity was set successfully.
  static Future<bool> setJwtIdentity(String userToken) async {
    if (!_initialized) {
      Log.warning(
        '⚠️ Zendesk JWT: SDK not initialized',
        category: LogCategory.system,
      );
      return false;
    }

    try {
      Log.info(
        '🎫 Zendesk JWT: Setting identity with user token',
        category: LogCategory.system,
      );

      final result = await _channel.invokeMethod('setJwtIdentity', {
        'userToken': userToken,
      });

      if (result == true) {
        Log.info(
          '✅ Zendesk JWT: Identity set - Zendesk will callback for JWT',
          category: LogCategory.system,
        );
        return true;
      }
      return false;
    } on PlatformException catch (e) {
      Log.error(
        '❌ Zendesk JWT: Platform error - ${e.code}: ${e.message}',
        category: LogCategory.system,
      );
      return false;
    } catch (e) {
      Log.error(
        '❌ Zendesk JWT: Error setting identity - $e',
        category: LogCategory.system,
      );
      return false;
    }
  }

  /// Ensure JWT identity is set before viewing ticket history
  ///
  /// Pass the user's npub as the identifier. The Zendesk SDK will call our
  /// JWT endpoint with this identifier to get the actual JWT for authentication.
  /// Call this before showing the ticket list to enable "View Past Messages".
  ///
  /// Returns true if JWT identity is set successfully, false otherwise.
  /// Falls back gracefully - ticket list will still work with anonymous identity.
  static Future<bool> ensureJwtIdentity({
    required String pubkey,
    String? displayName,
  }) async {
    // Use stored npub if available (set via setUserIdentity)
    // Otherwise use the provided pubkey as the user token
    final userToken = _userNpub ?? pubkey;

    Log.info(
      '🎫 Zendesk JWT: Setting identity with user token (npub)',
      category: LogCategory.system,
    );

    return setJwtIdentity(userToken);
  }

  /// Clear cached JWT (call on logout)
  static void clearJwtCache() {
    _cachedJwt = null;
  }

  /// Format npub for display
  /// CRITICAL: Never truncate Nostr IDs - full npub needed for user identification
  static String _formatNpubForDisplay(String npub) {
    return npub;
  }

  /// Show native Zendesk ticket creation screen
  ///
  /// Presents the native Zendesk UI for creating a support ticket.
  /// Returns true if screen shown, false if Zendesk not initialized.
  static Future<bool> showNewTicketScreen({
    String? subject,
    String? description,
    List<String>? tags,
  }) async {
    if (!_initialized) {
      Log.warning(
        'Zendesk not initialized - cannot show ticket screen',
        category: LogCategory.system,
      );
      return false;
    }

    try {
      await _channel.invokeMethod('showNewTicket', {
        'subject': subject,
        'description': description,
        'tags': tags,
      });

      Log.info('Zendesk ticket screen shown', category: LogCategory.system);
      return true;
    } on PlatformException catch (e) {
      Log.error(
        'Failed to show Zendesk ticket screen: ${e.code} - ${e.message}',
        category: LogCategory.system,
      );
      return false;
    } catch (e) {
      Log.error(
        'Unexpected error showing Zendesk screen: $e',
        category: LogCategory.system,
      );
      return false;
    }
  }

  /// Show user's ticket list (support history)
  ///
  /// Presents the native Zendesk UI showing all tickets from this user.
  /// Returns true if screen shown, false if Zendesk not initialized.
  static Future<bool> showTicketListScreen() async {
    if (!_initialized) {
      Log.warning(
        'Zendesk not initialized - cannot show ticket list',
        category: LogCategory.system,
      );
      return false;
    }

    try {
      await _channel.invokeMethod('showTicketList');
      Log.info('Zendesk ticket list shown', category: LogCategory.system);
      return true;
    } on PlatformException catch (e) {
      Log.error(
        'Failed to show Zendesk ticket list: ${e.code} - ${e.message}',
        category: LogCategory.system,
      );
      return false;
    } catch (e) {
      Log.error(
        'Unexpected error showing ticket list: $e',
        category: LogCategory.system,
      );
      return false;
    }
  }

  /// Create a Zendesk ticket programmatically (no UI)
  ///
  /// Creates a support ticket silently in the background without showing any UI.
  /// Useful for automatic content reporting or system-generated tickets.
  /// Returns true if ticket created successfully, false otherwise.
  ///
  /// Platform support:
  /// - iOS: Full support via RequestProvider API (with custom fields)
  /// - Android: Full support via RequestProvider API (with custom fields)
  /// - macOS/Windows: Falls back to REST API
  ///
  /// Custom fields format: [{'id': 12345, 'value': 'some_value'}, ...]
  static Future<bool> createTicket({
    required String subject,
    required String description,
    List<String>? tags,
    int? ticketFormId,
    List<Map<String, dynamic>>? customFields,
  }) async {
    if (!_initialized) {
      Log.warning(
        'Zendesk not initialized - cannot create ticket',
        category: LogCategory.system,
      );
      return false;
    }

    try {
      final result = await _channel.invokeMethod('createTicket', {
        'subject': subject,
        'description': description,
        'tags': tags ?? [],
        if (ticketFormId != null) 'ticketFormId': ticketFormId,
        if (customFields != null && customFields.isNotEmpty)
          'customFields': customFields,
      });

      if (result == true) {
        Log.info(
          'Zendesk ticket created successfully: $subject',
          category: LogCategory.system,
        );
        return true;
      } else {
        Log.warning(
          'Failed to create Zendesk ticket: $subject',
          category: LogCategory.system,
        );
        return false;
      }
    } on MissingPluginException {
      // Native SDK not available (macOS, Windows, Web)
      // Fall back to REST API
      Log.info(
        'Native createTicket not available, falling back to REST API',
        category: LogCategory.system,
      );
      return createTicketViaApi(
        subject: subject,
        description: description,
        requesterName: _userName,
        requesterEmail: _userEmail,
        tags: tags,
      );
    } on PlatformException catch (e) {
      Log.error(
        '❌ Zendesk SDK error: ${e.code} - ${e.message}',
        category: LogCategory.system,
      );
      // Fall back to REST API on SDK error
      Log.info(
        '🔄 Falling back to REST API after SDK error',
        category: LogCategory.system,
      );
      return createTicketViaApi(
        subject: subject,
        description: description,
        requesterName: _userName,
        requesterEmail: _userEmail,
        tags: tags,
      );
    } catch (e) {
      Log.error(
        'Unexpected error creating Zendesk ticket: $e',
        category: LogCategory.system,
      );
      return false;
    }
  }

  /// Show ticket list (user's support request history)
  ///
  /// Opens the Zendesk ticket list UI showing the user's past support tickets
  /// and allowing them to view responses and continue conversations.
  /// Returns true if ticket list shown successfully, false otherwise.
  static Future<bool> showTicketList() async {
    if (!_initialized) {
      Log.warning(
        'Zendesk not initialized - cannot show ticket list',
        category: LogCategory.system,
      );
      return false;
    }

    try {
      final result = await _channel.invokeMethod('showTicketList');

      if (result == true) {
        Log.info(
          'Zendesk ticket list shown successfully',
          category: LogCategory.system,
        );
        return true;
      } else {
        Log.warning(
          'Failed to show Zendesk ticket list',
          category: LogCategory.system,
        );
        return false;
      }
    } on PlatformException catch (e) {
      Log.error(
        'Platform error showing Zendesk ticket list: ${e.code} - ${e.message}',
        category: LogCategory.system,
      );
      return false;
    } catch (e) {
      Log.error(
        'Unexpected error showing Zendesk ticket list: $e',
        category: LogCategory.system,
      );
      return false;
    }
  }

  // ========================================================================
  // REST API Methods (for platforms without native SDK: macOS, Windows, Web)
  // ========================================================================

  /// Check if REST API is available (for platforms without native SDK)
  static bool get isRestApiAvailable => ZendeskConfig.isRestApiConfigured;

  /// Create a Zendesk ticket via REST API (no native SDK required)
  ///
  /// This works on ALL platforms including macOS, Windows, and Web.
  /// Uses the Zendesk Support API with token authentication.
  /// Returns true if ticket created successfully, false otherwise.
  static Future<bool> createTicketViaApi({
    required String subject,
    required String description,
    String? requesterEmail,
    String? requesterName,
    List<String>? tags,
  }) async {
    if (!ZendeskConfig.isRestApiConfigured) {
      Log.error(
        '❌ Zendesk REST API not configured - ZENDESK_API_TOKEN not set in build',
        category: LogCategory.system,
      );
      return false;
    }

    try {
      Log.info(
        'Creating Zendesk ticket via REST API: $subject',
        category: LogCategory.system,
      );

      // Build the request body
      // Using the Requests API which requires a requester email
      // Default to apiEmail if none provided (for anonymous bug reports)
      final effectiveEmail = requesterEmail ?? ZendeskConfig.apiEmail;
      final effectiveName = requesterName ?? 'Divine App User';

      // Build requester with external_id for JWT identity linking
      final requester = <String, dynamic>{
        'name': effectiveName,
        'email': effectiveEmail,
      };
      if (_userNpub != null) {
        requester['external_id'] = _userNpub;
      }

      final requestBody = {
        'request': {
          'subject': subject,
          'comment': {'body': description},
          'requester': requester,
          if (tags != null && tags.isNotEmpty) 'tags': tags,
        },
      };

      // Zendesk API URL for creating requests (end-user ticket creation)
      final apiUrl = '${ZendeskConfig.zendeskUrl}/api/v2/requests.json';

      // Create Basic Auth header: email/token:api_token
      final credentials =
          '${ZendeskConfig.apiEmail}/token:${ZendeskConfig.apiToken}';
      final encodedCredentials = base64Encode(utf8.encode(credentials));

      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Basic $encodedCredentials',
        },
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 201 || response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        final ticketId = responseData['request']?['id'];
        Log.info(
          '✅ Zendesk ticket created via API: #$ticketId - $subject',
          category: LogCategory.system,
        );
        return true;
      } else {
        Log.error(
          'Zendesk API error: ${response.statusCode} - ${response.body}',
          category: LogCategory.system,
        );
        return false;
      }
    } catch (e, stackTrace) {
      Log.error(
        'Exception creating Zendesk ticket via API: $e',
        category: LogCategory.system,
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// Create a structured bug report with user-provided fields
  ///
  /// This method submits bug reports via native SDK (iOS/Android) or REST API
  /// (desktop). Using SDK ensures tickets are linked to the user's identity
  /// and visible in "View Past Messages".
  ///
  /// Custom field IDs (configured in Zendesk):
  /// - 14772963437071: ticket_form_id (Bug Report form)
  /// - 14332953477519: Ticket Type (incident)
  /// - 14884176561807: Platform (ios/android/macos/etc)
  /// - 14884157556111: OS Version
  /// - 14884184890511: Build Number
  /// - 14677364166031: Steps to Reproduce
  /// - 14677341431695: Expected Behavior
  static Future<bool> createStructuredBugReport({
    required String subject,
    required String description,
    String? stepsToReproduce,
    String? expectedBehavior,
    required String reportId,
    required String appVersion,
    required Map<String, dynamic> deviceInfo,
    String? currentScreen,
    String? userPubkey,
    Map<String, int>? errorCounts,
    String? logsSummary,
  }) async {
    Log.info(
      'Creating structured Zendesk bug report: $reportId',
      category: LogCategory.system,
    );

    // Extract platform info for custom fields
    final platform =
        deviceInfo['platform']?.toString().toLowerCase() ?? 'unknown';
    final osVersion =
        deviceInfo['version']?.toString() ??
        deviceInfo['systemVersion']?.toString() ??
        'unknown';
    // appVersion format is "1.2.3+456" - extract build number after +
    final buildNumber = appVersion.contains('+')
        ? appVersion.split('+').last
        : appVersion;

    // Build comprehensive ticket description
    final buffer = StringBuffer();
    buffer.writeln('## Bug Report');
    buffer.writeln('**Report ID:** $reportId');
    buffer.writeln('**App Version:** $appVersion');
    buffer.writeln('');
    buffer.writeln('### Description');
    buffer.writeln(description);
    buffer.writeln('');
    if (stepsToReproduce != null && stepsToReproduce.isNotEmpty) {
      buffer.writeln('### Steps to Reproduce');
      buffer.writeln(stepsToReproduce);
      buffer.writeln('');
    }
    if (expectedBehavior != null && expectedBehavior.isNotEmpty) {
      buffer.writeln('### Expected Behavior');
      buffer.writeln(expectedBehavior);
      buffer.writeln('');
    }
    buffer.writeln('### Device Information');
    deviceInfo.forEach((key, value) {
      buffer.writeln('- **$key:** $value');
    });
    if (currentScreen != null) {
      buffer.writeln('');
      buffer.writeln('**Current Screen:** $currentScreen');
    }
    final effectivePubkey = userPubkey ?? _userNpub;
    if (effectivePubkey != null) {
      buffer.writeln('**User Pubkey:** $effectivePubkey');
    }
    if (errorCounts != null && errorCounts.isNotEmpty) {
      buffer.writeln('');
      buffer.writeln('### Recent Error Summary');
      final sortedErrors = errorCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final entry in sortedErrors.take(10)) {
        buffer.writeln('- ${entry.key}: ${entry.value} occurrences');
      }
    }
    if (logsSummary != null && logsSummary.isNotEmpty) {
      buffer.writeln('');
      buffer.writeln('### Recent Logs (Summary)');
      buffer.writeln('```');
      buffer.writeln(logsSummary);
      buffer.writeln('```');
    }

    final effectiveSubject = subject.isNotEmpty
        ? subject
        : 'Bug Report: $reportId';
    final tags = ['bug_report', 'divine_app', 'mobile', platform];

    // Build custom fields list for SDK
    final customFields = <Map<String, dynamic>>[
      {'id': 14332953477519, 'value': 'incident'}, // Ticket Type
      {'id': 14884176561807, 'value': platform}, // Platform
      {'id': 14884157556111, 'value': osVersion}, // OS Version
      {'id': 14884184890511, 'value': buildNumber}, // Build Number
    ];

    // Add optional text fields if provided
    if (stepsToReproduce != null && stepsToReproduce.isNotEmpty) {
      customFields.add({
        'id': 14677364166031,
        'value': stepsToReproduce,
      }); // Steps to Reproduce
    }
    if (expectedBehavior != null && expectedBehavior.isNotEmpty) {
      customFields.add({
        'id': 14677341431695,
        'value': expectedBehavior,
      }); // Expected Behavior
    }

    // Try native SDK first (iOS/Android) - this links tickets to user identity
    if (_initialized) {
      Log.info(
        '🎫 Using native SDK for bug report (enables View Past Messages)',
        category: LogCategory.system,
      );
      // First try without custom fields to test basic SDK functionality
      return createTicket(
        subject: effectiveSubject,
        description: buffer.toString(),
        tags: tags,
        // Temporarily disabled to test basic SDK ticket creation
        // ticketFormId: 14772963437071, // Bug Report form
        // customFields: customFields,
      );
    }

    // Fall back to REST API for desktop platforms
    Log.info(
      '🎫 Native SDK not available, using REST API fallback',
      category: LogCategory.system,
    );
    return _createStructuredBugReportViaApi(
      subject: effectiveSubject,
      description: buffer.toString(),
      tags: tags,
      customFields: customFields,
    );
  }

  /// Internal: Create bug report via REST API (fallback for desktop)
  static Future<bool> _createStructuredBugReportViaApi({
    required String subject,
    required String description,
    required List<String> tags,
    required List<Map<String, dynamic>> customFields,
  }) async {
    if (!ZendeskConfig.isRestApiConfigured) {
      Log.error(
        '❌ Zendesk REST API not configured - ZENDESK_API_TOKEN not set',
        category: LogCategory.system,
      );
      return false;
    }

    try {
      // Requester info - include external_id (npub) for JWT identity matching
      final effectiveEmail = _userEmail ?? ZendeskConfig.apiEmail;
      final effectiveName = _userName ?? 'Divine App User';

      // Build requester with external_id for JWT identity linking
      final requester = <String, dynamic>{
        'name': effectiveName,
        'email': effectiveEmail,
      };
      if (_userNpub != null) {
        requester['external_id'] = _userNpub;
      }

      // Build ticket request
      final requestBody = {
        'ticket': {
          'subject': subject,
          'comment': {'body': description},
          'requester': requester,
          'ticket_form_id': 14772963437071,
          'tags': tags,
          'custom_fields': customFields,
        },
      };

      // Use Tickets API endpoint (supports custom fields)
      final apiUrl = '${ZendeskConfig.zendeskUrl}/api/v2/tickets.json';

      // Create Basic Auth header
      final authEmail = ZendeskConfig.apiEmail;
      Log.info(
        'Zendesk API auth: email=$authEmail, tokenLen=${ZendeskConfig.apiToken.length}',
        category: LogCategory.system,
      );
      final credentials = '$authEmail/token:${ZendeskConfig.apiToken}';
      final encodedCredentials = base64Encode(utf8.encode(credentials));

      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Basic $encodedCredentials',
        },
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 201 || response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        final ticketId = responseData['ticket']?['id'];
        Log.info(
          '✅ Zendesk bug report created via API: #$ticketId',
          category: LogCategory.system,
        );
        return true;
      } else {
        Log.error(
          'Zendesk API error: ${response.statusCode} - ${response.body}',
          category: LogCategory.system,
        );
        return false;
      }
    } catch (e, stackTrace) {
      Log.error(
        'Exception creating Zendesk bug report via API: $e',
        category: LogCategory.system,
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// Create a bug report ticket via REST API with full diagnostics
  ///
  /// Formats the bug report data into a Zendesk ticket with proper structure.
  /// Uses the Tickets API with custom fields for structured metadata.
  /// See: https://github.com/divinevideo/divine-mobile/issues/951
  ///
  /// Custom field IDs (configured in Zendesk):
  /// - 14772963437071: ticket_form_id (Bug Report form)
  /// - 14332953477519: Ticket Type (incident)
  /// - 14884176561807: Platform (ios/android/macos/etc)
  /// - 14884157556111: OS Version
  /// - 14884184890511: Build Number
  static Future<bool> createBugReportTicketViaApi({
    required String reportId,
    required String userDescription,
    required String appVersion,
    required Map<String, dynamic> deviceInfo,
    String? currentScreen,
    String? userPubkey,
    Map<String, int>? errorCounts,
    String? logsSummary,
  }) async {
    if (!ZendeskConfig.isRestApiConfigured) {
      Log.error(
        '❌ Zendesk REST API not configured - ZENDESK_API_TOKEN not set',
        category: LogCategory.system,
      );
      return false;
    }

    try {
      Log.info(
        'Creating Zendesk bug report ticket: $reportId',
        category: LogCategory.system,
      );

      // Extract platform info for custom fields
      final platform =
          deviceInfo['platform']?.toString().toLowerCase() ?? 'unknown';
      final osVersion =
          deviceInfo['version']?.toString() ??
          deviceInfo['systemVersion']?.toString() ??
          'unknown';
      // appVersion format is "1.2.3+456" - extract build number after +
      final buildNumber = appVersion.contains('+')
          ? appVersion.split('+').last
          : appVersion;

      // Build comprehensive ticket description
      final buffer = StringBuffer();
      buffer.writeln('## Bug Report');
      buffer.writeln('**Report ID:** $reportId');
      buffer.writeln('**App Version:** $appVersion');
      buffer.writeln('');
      buffer.writeln('### User Description');
      buffer.writeln(userDescription);
      buffer.writeln('');
      buffer.writeln('### Device Information');
      deviceInfo.forEach((key, value) {
        buffer.writeln('- **$key:** $value');
      });
      if (currentScreen != null) {
        buffer.writeln('');
        buffer.writeln('**Current Screen:** $currentScreen');
      }
      final effectivePubkey = userPubkey ?? _userNpub;
      if (effectivePubkey != null) {
        buffer.writeln('**User Pubkey:** $effectivePubkey');
      }
      if (errorCounts != null && errorCounts.isNotEmpty) {
        buffer.writeln('');
        buffer.writeln('### Recent Error Summary');
        final sortedErrors = errorCounts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        for (final entry in sortedErrors.take(10)) {
          buffer.writeln('- ${entry.key}: ${entry.value} occurrences');
        }
      }
      if (logsSummary != null && logsSummary.isNotEmpty) {
        buffer.writeln('');
        buffer.writeln('### Recent Logs (Summary)');
        buffer.writeln('```');
        buffer.writeln(logsSummary);
        buffer.writeln('```');
      }

      // Requester info - include external_id (npub) for JWT identity matching
      final effectiveEmail = _userEmail ?? ZendeskConfig.apiEmail;
      final effectiveName = _userName ?? 'Divine App User';

      // Build requester with external_id for JWT identity linking
      final requester = <String, dynamic>{
        'name': effectiveName,
        'email': effectiveEmail,
      };
      if (_userNpub != null) {
        requester['external_id'] = _userNpub;
      }

      // Build ticket with custom fields
      // Using Tickets API (not Requests API) to support custom fields
      final requestBody = {
        'ticket': {
          'subject': 'Bug Report: $reportId',
          'comment': {'body': buffer.toString()},
          'requester': requester,
          'ticket_form_id': 14772963437071,
          'tags': ['bug_report', 'divine_app', 'mobile', platform],
          'custom_fields': [
            {'id': 14332953477519, 'value': 'incident'}, // Ticket Type
            {'id': 14884176561807, 'value': platform}, // Platform
            {'id': 14884157556111, 'value': osVersion}, // OS Version
            {'id': 14884184890511, 'value': buildNumber}, // Build Number
          ],
        },
      };

      // Use Tickets API endpoint (supports custom fields)
      final apiUrl = '${ZendeskConfig.zendeskUrl}/api/v2/tickets.json';

      // Create Basic Auth header
      final credentials =
          '${ZendeskConfig.apiEmail}/token:${ZendeskConfig.apiToken}';
      final encodedCredentials = base64Encode(utf8.encode(credentials));

      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Basic $encodedCredentials',
        },
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 201 || response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        final ticketId = responseData['ticket']?['id'];
        Log.info(
          '✅ Zendesk bug report created: #$ticketId - $reportId',
          category: LogCategory.system,
        );
        return true;
      } else {
        Log.error(
          'Zendesk API error: ${response.statusCode} - ${response.body}',
          category: LogCategory.system,
        );
        return false;
      }
    } catch (e, stackTrace) {
      Log.error(
        'Exception creating Zendesk bug report: $e',
        category: LogCategory.system,
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  // ==========================================================================
  // Feature Requests
  // ==========================================================================

  /// Create a feature request ticket
  ///
  /// Custom field IDs (configured in Zendesk):
  /// - 15081095878799: ticket_form_id (Feature Request form)
  /// - 15081108558863: How would this be useful for you?
  /// - 15081142424847: When would you use this?
  static Future<bool> createFeatureRequest({
    required String subject,
    required String description,
    String? usefulness,
    String? whenToUse,
    String? userPubkey,
  }) async {
    Log.info(
      '💡 Creating Zendesk feature request',
      category: LogCategory.system,
    );

    // Build ticket description
    final buffer = StringBuffer();
    buffer.writeln('## Feature Request');
    buffer.writeln('');
    buffer.writeln('### What would you like?');
    buffer.writeln(description);
    if (usefulness != null && usefulness.isNotEmpty) {
      buffer.writeln('');
      buffer.writeln('### How would this be useful for you?');
      buffer.writeln(usefulness);
    }
    if (whenToUse != null && whenToUse.isNotEmpty) {
      buffer.writeln('');
      buffer.writeln('### When would you use this?');
      buffer.writeln(whenToUse);
    }
    final effectivePubkey = userPubkey ?? _userNpub;
    if (effectivePubkey != null) {
      buffer.writeln('');
      buffer.writeln('**User Pubkey:** $effectivePubkey');
    }

    final effectiveSubject = subject.isNotEmpty ? subject : 'Feature Request';
    final tags = ['feature_request', 'divine_app', 'mobile'];

    // Build custom fields list
    final customFields = <Map<String, dynamic>>[];
    if (usefulness != null && usefulness.isNotEmpty) {
      customFields.add({
        'id': 15081108558863,
        'value': usefulness,
      }); // How would this be useful for you?
    }
    if (whenToUse != null && whenToUse.isNotEmpty) {
      customFields.add({
        'id': 15081142424847,
        'value': whenToUse,
      }); // When would you use this?
    }

    // Try native SDK first (iOS/Android) - this links tickets to user identity
    if (_initialized) {
      Log.info(
        '💡 Using native SDK for feature request (enables View Past Messages)',
        category: LogCategory.system,
      );
      return createTicket(
        subject: effectiveSubject,
        description: buffer.toString(),
        tags: tags,
      );
    }

    // Fall back to REST API for desktop platforms
    Log.info(
      '💡 Native SDK not available, using REST API fallback',
      category: LogCategory.system,
    );
    return _createFeatureRequestViaApi(
      subject: effectiveSubject,
      description: buffer.toString(),
      tags: tags,
      customFields: customFields,
    );
  }

  /// Internal: Create feature request via REST API (fallback for desktop)
  static Future<bool> _createFeatureRequestViaApi({
    required String subject,
    required String description,
    required List<String> tags,
    required List<Map<String, dynamic>> customFields,
  }) async {
    if (!ZendeskConfig.isRestApiConfigured) {
      Log.error(
        '❌ Zendesk REST API not configured - ZENDESK_API_TOKEN not set',
        category: LogCategory.system,
      );
      return false;
    }

    try {
      // Requester info - include external_id (npub) for JWT identity matching
      final effectiveEmail = _userEmail ?? ZendeskConfig.apiEmail;
      final effectiveName = _userName ?? 'Divine App User';

      // Build requester with external_id for JWT identity linking
      final requester = <String, dynamic>{
        'name': effectiveName,
        'email': effectiveEmail,
      };
      if (_userNpub != null) {
        requester['external_id'] = _userNpub;
      }

      // Build ticket request
      final requestBody = {
        'ticket': {
          'subject': subject,
          'comment': {'body': description},
          'requester': requester,
          'ticket_form_id': 15081095878799, // Feature Request form
          'tags': tags,
          'custom_fields': customFields,
        },
      };

      // Use Tickets API endpoint (supports custom fields)
      final apiUrl = '${ZendeskConfig.zendeskUrl}/api/v2/tickets.json';

      // Create Basic Auth header
      final credentials =
          '${ZendeskConfig.apiEmail}/token:${ZendeskConfig.apiToken}';
      final encodedCredentials = base64Encode(utf8.encode(credentials));

      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Basic $encodedCredentials',
        },
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 201 || response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        final ticketId = responseData['ticket']?['id'];
        Log.info(
          '✅ Zendesk feature request created via API: #$ticketId',
          category: LogCategory.system,
        );
        return true;
      } else {
        Log.error(
          'Zendesk API error: ${response.statusCode} - ${response.body}',
          category: LogCategory.system,
        );
        return false;
      }
    } catch (e, stackTrace) {
      Log.error(
        'Exception creating Zendesk feature request: $e',
        category: LogCategory.system,
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }
}

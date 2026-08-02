import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models/model_spec.dart';
import 'app_settings.dart';
import 'model_storage.dart';

/// Result of asking Hugging Face whether the current credentials may download a
/// particular model file.
enum HfAccessStatus {
  /// The file can be downloaded right now.
  granted,

  /// No usable credentials: the user has to sign in or paste a token.
  authenticationRequired,

  /// Signed in, but the repository's license has not been accepted yet (or the
  /// request for access is still awaiting manual approval).
  licenseRequired,

  /// The repository or file does not exist.
  notFound,

  /// The check could not be completed — offline, DNS failure, timeout.
  networkError,
}

/// Outcome of [HuggingFaceService.checkAccess].
class HfAccessResult {
  const HfAccessResult(this.status, {this.message});

  final HfAccessStatus status;

  /// Server-supplied explanation, when there is one worth showing.
  final String? message;

  bool get isGranted => status == HfAccessStatus.granted;

  @override
  String toString() => 'HfAccessResult($status, $message)';
}

/// Progress of an in-flight model download.
class DownloadProgress {
  const DownloadProgress({required this.received, required this.total});

  /// Bytes written so far, including bytes carried over from a resumed
  /// download.
  final int received;

  /// Total size in bytes, or null when the server did not report one.
  final int? total;

  /// Completion in the range 0..1, or null when [total] is unknown.
  double? get fraction {
    final total = this.total;
    if (total == null || total <= 0) return null;
    return (received / total).clamp(0.0, 1.0);
  }
}

/// Cooperative cancellation for a download.
class CancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void Function()? _onCancel;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
  }

  void attach(void Function() callback) {
    _onCancel = callback;
    if (_cancelled) callback();
  }

  void detach() => _onCancel = null;
}

/// Thrown when a download is asked to stop.
class DownloadCancelled implements Exception {
  const DownloadCancelled();
  @override
  String toString() => 'Download cancelled';
}

/// Thrown when a download cannot proceed. [access] carries the reason when the
/// failure was an access-control one, so the UI can route the user to a sign-in
/// or a license page rather than just showing an error.
class HfDownloadException implements Exception {
  const HfDownloadException(this.message, {this.access});

  final String message;
  final HfAccessResult? access;

  @override
  String toString() => message;
}

/// Talks to Hugging Face: authentication, gated-repository access checks, and
/// downloading model weights.
///
/// Gated repositories such as `google/gemma-3n-E2B-it-litert-preview` are only
/// downloadable once the signed-in account has accepted Google's Gemma Terms of
/// Use on the model page. This service never tries to work around that: it
/// detects the condition, sends the user to Hugging Face's own consent page, and
/// re-checks afterwards. [downloadModel] repeats the check immediately before
/// transferring bytes so that a stale screen cannot start a download the account
/// is not entitled to.
class HuggingFaceService {
  static final HuggingFaceService _instance = HuggingFaceService._internal();
  factory HuggingFaceService() => _instance;
  HuggingFaceService._internal();

  /// OAuth client id of a Hugging Face "Connected App".
  ///
  /// Supply at build time with
  /// `flutter run --dart-define=HF_CLIENT_ID=<your client id>`. When it is not
  /// set, [isOAuthConfigured] is false and the UI offers the access-token flow
  /// instead. There is deliberately no client *secret*: a secret shipped inside
  /// an app binary is not a secret, so this uses PKCE for a public client.
  static const String clientId = String.fromEnvironment('HF_CLIENT_ID');

  /// Custom scheme registered for the OAuth redirect. Must match the
  /// `android:scheme` in `AndroidManifest.xml` and the iOS URL type.
  static const String callbackScheme = 'privai';
  static const String redirectUri = '$callbackScheme://oauth-callback';

  static final Uri _authorizeEndpoint =
      Uri.parse('https://huggingface.co/oauth/authorize');
  static final Uri _tokenEndpoint =
      Uri.parse('https://huggingface.co/oauth/token');
  static final Uri _whoAmIEndpoint =
      Uri.parse('https://huggingface.co/api/whoami-v2');

  /// `read-repos` is what grants download access to repositories the account can
  /// reach, including gated ones it has been approved for.
  static const String _scopes = 'openid profile read-repos';

  static const Duration _requestTimeout = Duration(seconds: 30);

  final AppSettings _settings = AppSettings();
  final ModelStorage _storage = ModelStorage();
  final http.Client _client = http.Client();

  bool get isOAuthConfigured => clientId.isNotEmpty;

  Future<String?> get token => _settings.hfToken;
  Future<bool> get isSignedIn async => (await _settings.hfToken) != null;

  // --------------------------------------------------------------------------
  // Authentication
  // --------------------------------------------------------------------------

  /// Runs the OAuth 2.0 authorization-code flow with PKCE and stores the token.
  ///
  /// Throws [StateError] when no [clientId] was configured at build time.
  Future<void> signInWithOAuth() async {
    if (!isOAuthConfigured) {
      throw StateError(
        'No Hugging Face OAuth client id was configured. Rebuild with '
        '--dart-define=HF_CLIENT_ID=<id>, or sign in with an access token.',
      );
    }

    final verifier = _randomUrlSafeString(64);
    final challenge =
        base64UrlEncode(sha256.convert(utf8.encode(verifier)).bytes)
            .replaceAll('=', '');
    final state = _randomUrlSafeString(24);

    final authorizeUrl = _authorizeEndpoint.replace(queryParameters: {
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': _scopes,
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    });

    final rawResult = await FlutterWebAuth2.authenticate(
      url: authorizeUrl.toString(),
      callbackUrlScheme: callbackScheme,
    );

    final result = Uri.parse(rawResult);
    final error = result.queryParameters['error'];
    if (error != null) {
      throw HfDownloadException(
        'Hugging Face denied the sign-in request: '
        '${result.queryParameters['error_description'] ?? error}',
      );
    }

    if (result.queryParameters['state'] != state) {
      // Guards against a callback that did not originate from our request.
      throw const HfDownloadException(
          'Sign-in failed: mismatched OAuth state.');
    }

    final code = result.queryParameters['code'];
    if (code == null) {
      throw const HfDownloadException(
        'Sign-in failed: Hugging Face did not return an authorization code.',
      );
    }

    final response = await _client.post(
      _tokenEndpoint,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'authorization_code',
        'client_id': clientId,
        'code': code,
        'code_verifier': verifier,
        'redirect_uri': redirectUri,
      },
    ).timeout(_requestTimeout);

    if (response.statusCode != 200) {
      throw HfDownloadException(
        'Could not exchange the sign-in code for a token '
        '(HTTP ${response.statusCode}).',
      );
    }

    final accessToken =
        (json.decode(response.body) as Map<String, dynamic>)['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const HfDownloadException(
        'Hugging Face returned a sign-in response without an access token.',
      );
    }

    await _settings.setHfToken(accessToken);
  }

  /// Validates a user-supplied access token and stores it when it works.
  ///
  /// Returns the account name. Throws [HfDownloadException] if the token is not
  /// accepted, so a typo never gets saved and then blamed on the model.
  Future<String> signInWithAccessToken(String rawToken) async {
    final token = rawToken.trim();
    if (token.isEmpty) {
      throw const HfDownloadException('Enter an access token first.');
    }

    final http.Response response;
    try {
      response = await _client.get(
        _whoAmIEndpoint,
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(_requestTimeout);
    } on Object catch (e) {
      throw HfDownloadException('Could not reach Hugging Face: $e');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const HfDownloadException(
        'Hugging Face rejected that token. Create a token with "read" access '
        'at huggingface.co/settings/tokens and try again.',
      );
    }
    if (response.statusCode != 200) {
      throw HfDownloadException(
        'Unexpected response from Hugging Face (HTTP ${response.statusCode}).',
      );
    }

    await _settings.setHfToken(token);

    final body = json.decode(response.body) as Map<String, dynamic>;
    return body['name'] as String? ?? 'your account';
  }

  /// Returns the signed-in account name, or null when not signed in.
  Future<String?> currentAccountName() async {
    final token = await _settings.hfToken;
    if (token == null) return null;
    try {
      final response = await _client.get(
        _whoAmIEndpoint,
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(_requestTimeout);
      if (response.statusCode != 200) return null;
      return (json.decode(response.body) as Map<String, dynamic>)['name']
          as String?;
    } catch (e) {
      debugPrint('HuggingFaceService: whoami failed: $e');
      return null;
    }
  }

  Future<void> signOut() => _settings.clearHfToken();

  // --------------------------------------------------------------------------
  // Gated access
  // --------------------------------------------------------------------------

  /// Asks Hugging Face whether [spec] can be downloaded with the stored token.
  ///
  /// This probes the real download URL with a one-byte range request rather than
  /// the repository metadata endpoint, because gated repositories expose their
  /// model card publicly while still refusing the weights — only the file
  /// endpoint reflects the license acceptance the user has to complete.
  Future<HfAccessResult> checkAccess(ModelSpec spec) async {
    final token = await _settings.hfToken;
    if (token == null && spec.gated) {
      return const HfAccessResult(
        HfAccessStatus.authenticationRequired,
        message: 'Sign in to Hugging Face to download this model.',
      );
    }

    try {
      final response = await _openStream(
        spec.downloadUrl,
        token: token,
        rangeHeader: 'bytes=0-0',
      );
      // We only need the status; discard whatever body came back.
      await response.stream.drain<void>();
      return _interpretStatus(response.statusCode, response.headers,
          hasToken: token != null);
    } on SocketException catch (e) {
      return HfAccessResult(HfAccessStatus.networkError, message: e.message);
    } on http.ClientException catch (e) {
      return HfAccessResult(HfAccessStatus.networkError, message: e.message);
    } catch (e) {
      return HfAccessResult(HfAccessStatus.networkError, message: '$e');
    }
  }

  HfAccessResult _interpretStatus(
    int statusCode,
    Map<String, String> headers, {
    required bool hasToken,
  }) {
    final serverMessage = headers['x-error-message'];

    if (statusCode >= 200 && statusCode < 300) {
      return const HfAccessResult(HfAccessStatus.granted);
    }

    switch (statusCode) {
      case 401:
        return HfAccessResult(
          HfAccessStatus.authenticationRequired,
          message: serverMessage ??
              (hasToken
                  ? 'Your Hugging Face session has expired. Sign in again.'
                  : 'Sign in to Hugging Face to download this model.'),
        );
      case 403:
        return HfAccessResult(
          HfAccessStatus.licenseRequired,
          message: serverMessage ??
              'Access to this repository is restricted until its license is '
                  'accepted.',
        );
      case 404:
        // Hugging Face hides gated repositories from accounts without access,
        // so an authenticated 404 on a repo we know is gated means the license
        // still has to be accepted rather than that the file vanished.
        return HfAccessResult(
          HfAccessStatus.notFound,
          message: serverMessage ?? 'That file is not on Hugging Face.',
        );
      default:
        return HfAccessResult(
          HfAccessStatus.networkError,
          message: serverMessage ?? 'Hugging Face returned HTTP $statusCode.',
        );
    }
  }

  /// Opens the model's Hugging Face page in an external browser, where Hugging
  /// Face presents the repository's license — for the Gemma models, Google's
  /// Gemma Terms of Use — together with the button that records acceptance
  /// against the user's account.
  ///
  /// Returns false when no browser could be opened.
  Future<bool> openLicensePage(ModelSpec spec) async {
    try {
      return await launchUrl(
        spec.licensePageUrl,
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      debugPrint('HuggingFaceService: could not open license page: $e');
      return false;
    }
  }

  // --------------------------------------------------------------------------
  // Downloading
  // --------------------------------------------------------------------------

  /// Downloads [spec] into [ModelStorage] using the operating system's native
  /// background transfer service.
  ///
  /// Access is re-checked here, immediately before any bytes move, so a gated
  /// model can never be fetched on the strength of a stale UI state. Returns the
  /// path of the finished file.
  Future<String> downloadModel(
    ModelSpec spec, {
    void Function(DownloadProgress)? onProgress,
    CancellationToken? cancellationToken,
  }) async {
    final access = await checkAccess(spec);
    if (!access.isGranted) {
      throw HfDownloadException(
        access.message ?? 'This model cannot be downloaded yet.',
        access: access,
      );
    }

    if (spec.isBundle) {
      return _downloadBundle(
        spec,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
    }

    final token = await _settings.hfToken;
    final targetPath = await _storage.pathFor(spec.filename);
    final target = File(targetPath);
    final total = await _remoteSize(spec.downloadUrl, token);
    await _downloadTo(
      url: spec.downloadUrl,
      target: target,
      token: token,
      expectedSize: total,
      cancellationToken: cancellationToken,
      onProgress: (received) => onProgress?.call(
        DownloadProgress(received: received, total: total),
      ),
    );
    debugPrint('HuggingFaceService: downloaded ${spec.filename}');
    return targetPath;
  }

  /// Fetches every file of a multi-file model into its bundle directory.
  ///
  /// Sizes are queried up front so progress can be reported against the whole
  /// bundle rather than restarting at zero for each file. Files already complete
  /// are skipped, which makes a re-run after a failure cheap.
  Future<String> _downloadBundle(
    ModelSpec spec, {
    void Function(DownloadProgress)? onProgress,
    CancellationToken? cancellationToken,
  }) async {
    final bundle = spec.bundleDirectory ?? spec.filename;
    final token = await _settings.hfToken;

    final sizes = <String, int>{};
    var grandTotal = 0;
    var knownAll = true;
    for (final file in spec.files) {
      final size = await _remoteSize(spec.urlFor(file), token);
      if (size == null) {
        knownAll = false;
      } else {
        sizes[file.name] = size;
        grandTotal += size;
      }
    }

    var completedBytes = 0;
    for (final file in spec.files) {
      if (cancellationToken?.isCancelled ?? false) {
        throw const DownloadCancelled();
      }

      final target = File(await _storage.pathInBundle(bundle, file.name));
      final expected = sizes[file.name];
      if (await target.exists() &&
          (expected == null || await target.length() == expected)) {
        completedBytes += expected ?? await target.length();
        onProgress?.call(DownloadProgress(
          received: completedBytes,
          total: knownAll ? grandTotal : null,
        ));
        continue;
      }

      final alreadyDone = completedBytes;
      await _downloadTo(
        url: spec.urlFor(file),
        target: target,
        token: token,
        expectedSize: expected,
        cancellationToken: cancellationToken,
        onProgress: (received) => onProgress?.call(DownloadProgress(
          received: alreadyDone + received,
          total: knownAll ? grandTotal : null,
        )),
      );
      completedBytes = alreadyDone + (expected ?? await target.length());
    }

    debugPrint('HuggingFaceService: bundle $bundle complete ($grandTotal B)');
    return (await _storage.bundleDirectory(bundle)).path;
  }

  /// Downloads one URL to [target] through the native background service.
  Future<void> _downloadTo({
    required Uri url,
    required File target,
    required String? token,
    required int? expectedSize,
    required void Function(int received) onProgress,
    CancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancelled ?? false) {
      throw const DownloadCancelled();
    }
    await target.parent.create(recursive: true);
    if (await target.exists()) await target.delete();
    // Old Dart-stream partials cannot be adopted by URLSession/DownloadWorker;
    // remove one only when starting its native replacement.
    final oldPartial = File('${target.path}${ModelStorage.partialSuffix}');
    if (await oldPartial.exists()) await oldPartial.delete();

    // Resolve Hugging Face to its signed CDN URL while Dart can read the token
    // from secure storage. The background task then stores no bearer token and
    // does not accidentally forward one to the CDN, which rejects it.
    // Hugging Face's Xet bridge issues signed download URLs in response to a
    // range probe and requires the eventual transfer to carry a Range header
    // too. The range used to obtain that URL must be identical to the range
    // used by the native transfer; otherwise Xet rejects it as "invalid
    // range". Declaring the complete range also gives background_downloader an
    // exact content length and remains compatible with pause/resume handling.
    final rangeHeader = expectedSize != null && expectedSize > 0
        ? 'bytes=0-${expectedSize - 1}'
        : 'bytes=0-';
    final backgroundUrl = await _backgroundUrl(
      url,
      token,
      rangeHeader: rangeHeader,
    );
    final headers = <String, String>{'Range': rangeHeader};
    final task = DownloadTask(
      url: backgroundUrl.toString(),
      headers: headers,
      filename: target.uri.pathSegments.last,
      directory: target.parent.path,
      baseDirectory: BaseDirectory.root,
      group: 'modelDownloads',
      updates: Updates.statusAndProgress,
      retries: 3,
      allowPause: true,
      displayName: target.uri.pathSegments.last,
    );
    cancellationToken?.attach(() {
      FileDownloader().cancel(task);
    });

    TaskStatusUpdate result;
    try {
      result = await FileDownloader().download(
        task,
        onProgress: (fraction) {
          if (fraction < 0) return;
          final total = expectedSize;
          onProgress(total == null ? 0 : (total * fraction).round());
        },
      );
    } finally {
      cancellationToken?.detach();
    }

    switch (result.status) {
      case TaskStatus.complete:
        final received = await target.length();
        if (expectedSize != null && received != expectedSize) {
          await target.delete();
          throw HfDownloadException(
            'Download of ${target.uri.pathSegments.last} has the wrong size: '
            '$received of $expectedSize bytes.',
          );
        }
        onProgress(received);
        return;
      case TaskStatus.canceled:
      case TaskStatus.paused:
        throw const DownloadCancelled();
      case TaskStatus.notFound:
        throw const HfDownloadException('Model file was not found (HTTP 404).');
      case TaskStatus.failed:
        final status = result.responseStatusCode;
        if (status != null) {
          final access = _interpretStatus(
            status,
            result.responseHeaders ?? const {},
            hasToken: token != null,
          );
          throw HfDownloadException(
            access.message ?? 'Download failed (HTTP $status).',
            access: access,
          );
        }
        throw HfDownloadException(
          result.exception?.description ?? 'Background download failed.',
        );
      case TaskStatus.enqueued:
      case TaskStatus.running:
      case TaskStatus.waitingToRetry:
        throw const HfDownloadException(
          'Background download stopped before it completed.',
        );
    }
  }

  Future<Uri> _backgroundUrl(
    Uri url,
    String? token, {
    required String rangeHeader,
  }) async {
    final response = await _openStream(
      url,
      token: token,
      rangeHeader: rangeHeader,
    );
    final resolved = response.request?.url ?? url;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      final access = _interpretStatus(
        response.statusCode,
        response.headers,
        hasToken: token != null,
      );
      throw HfDownloadException(
        access.message ?? 'Download failed (HTTP ${response.statusCode}).',
        access: access,
      );
    }
    // We only need the final signed URL. Cancel the response body immediately;
    // draining a full-file range here would download every model twice.
    await response.stream.listen((_) {}).cancel();
    return resolved;
  }

  /// Size of a remote file without downloading it, or null if not reported.
  Future<int?> _remoteSize(Uri url, String? token) async {
    try {
      final response = await _openStream(
        url,
        token: token,
        rangeHeader: 'bytes=0-0',
      );
      await response.stream.drain<void>();
      final linked = int.tryParse(response.headers['x-linked-size'] ?? '');
      if (linked != null && linked > 0) return linked;

      final range = response.headers['content-range'];
      if (range != null) {
        final slash = range.lastIndexOf('/');
        if (slash != -1) return int.tryParse(range.substring(slash + 1));
      }
    } catch (e) {
      debugPrint('HuggingFaceService: could not size $url: $e');
    }
    return null;
  }

  /// Issues a GET and follows redirects manually.
  ///
  /// Hugging Face redirects weight downloads to a CDN that serves pre-signed
  /// URLs and rejects requests that also carry an `Authorization` header. The
  /// bearer token is therefore dropped as soon as the redirect leaves
  /// huggingface.co.
  Future<http.StreamedResponse> _openStream(
    Uri url, {
    String? token,
    String? rangeHeader,
  }) async {
    var current = url;
    var sendAuth = token != null;

    for (var hop = 0; hop < 8; hop++) {
      final request = http.Request('GET', current)..followRedirects = false;
      if (sendAuth) request.headers['Authorization'] = 'Bearer $token';
      if (rangeHeader != null) request.headers['Range'] = rangeHeader;

      final response = await _client.send(request).timeout(_requestTimeout);

      if (!response.isRedirect) return response;

      final location = response.headers['location'];
      await response.stream.drain<void>();
      if (location == null) return response;

      final next = current.resolve(location);
      sendAuth = token != null && _isHuggingFaceHost(next.host);
      current = next;
    }

    throw const HfDownloadException(
      'Hugging Face redirected too many times while starting the download.',
    );
  }

  static bool _isHuggingFaceHost(String host) =>
      host == 'huggingface.co' || host.endsWith('.huggingface.co');

  static final Random _random = Random.secure();
  static const String _urlSafeChars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  static String _randomUrlSafeString(int length) => String.fromCharCodes(
        Iterable.generate(
          length,
          (_) =>
              _urlSafeChars.codeUnitAt(_random.nextInt(_urlSafeChars.length)),
        ),
      );

  void dispose() => _client.close();
}

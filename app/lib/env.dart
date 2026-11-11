/// Build environment, set by the `run` script via `--dart-define=APP_ENV=...`.
const appEnv = String.fromEnvironment('APP_ENV', defaultValue: 'dev');

bool get isProd => appEnv == 'prod';

/// Sync server. Override with `--dart-define=API_URL=https://sync.example.com`
/// (the run script passes $MYTERMI_API_URL). Users can change it in the app.
const _apiUrl = String.fromEnvironment('API_URL');
String get defaultApiUrl => _apiUrl.isNotEmpty ? _apiUrl : (isProd ? '' : 'http://localhost:8080');

/// Google Sign-In OAuth client IDs (Google Cloud Console). Empty = hide the button.
const googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');
const googleServerClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

/// App version from pubspec.yaml (`version: 1.2.3+4`), read in [main] via
/// package_info_plus. Tests and failures leave the placeholder.
String appVersion = '0.0.0';

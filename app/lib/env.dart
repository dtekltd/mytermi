/// Build environment, set by the `run` script via `--dart-define=APP_ENV=...`.
const appEnv = String.fromEnvironment('APP_ENV', defaultValue: 'dev');

bool get isProd => appEnv == 'prod';

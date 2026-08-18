import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Where the backend lives, resolved the same way for every service.
///
/// The order matters, and the deployed build is the reason for it:
///
///  1. `--dart-define=API_BASE_URL=…`, which render.yaml passes. A release
///     build has no `.env` at all — the file is gitignored, so Render never
///     clones one — and without this it would fall through to a localhost that
///     exists only on a developer's machine.
///  2. `BACKEND_HOST`/`BACKEND_PORT` from the bundled `.env`, for local runs.
///  3. The local default, so a checkout with no configuration still talks to a
///     backend started with the documented defaults.
class ApiConfig {
  const ApiConfig._();

  static String get baseUrl {
    const fromBuild = String.fromEnvironment('API_BASE_URL');
    if (fromBuild.isNotEmpty) return fromBuild;
    final host = dotenv.env['BACKEND_HOST'] ?? '127.0.0.1';
    final port = dotenv.env['BACKEND_PORT'] ?? '8000';
    return 'http://$host:$port';
  }
}

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a link the reader tapped.
///
/// The app never requests a remote URL itself; it hands the URL to the browser,
/// which is a user-initiated navigation. Only http(s) and mailto are accepted so
/// that a pasted document cannot talk the app into a `javascript:` or `file:`
/// scheme. Returns false when the link could not be opened.
Future<bool> openExternalLink(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;

  const allowedSchemes = {'http', 'https', 'mailto'};
  if (!allowedSchemes.contains(uri.scheme.toLowerCase())) return false;

  try {
    return await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
      webOnlyWindowName: '_blank',
    );
  } catch (error) {
    debugPrint('Could not launch link: $error');
    return false;
  }
}

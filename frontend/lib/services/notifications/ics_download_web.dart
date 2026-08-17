import 'dart:js_interop';
import 'dart:js_interop_unsafe';

// Hand-written interop rather than package:web — see notification_channel_web
// .dart for why. Four calls: Blob, URL.createObjectURL, an anchor, and a click.

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny> parts, JSObject options);
}

@JS('URL.createObjectURL')
external String _createObjectUrl(JSObject blob);

@JS('URL.revokeObjectURL')
external void _revokeObjectUrl(String url);

@JS('document')
external _Document get _document;

extension type _Document._(JSObject _) implements JSObject {
  external _Element createElement(String tag);
  external _Element? get body;
}

extension type _Element._(JSObject _) implements JSObject {
  external void setAttribute(String name, String value);
  external void click();
  external void remove();
  external JSAny? appendChild(JSAny child);
}

/// Saves [content] to the user's downloads as [filename].
///
/// A Blob URL plus a synthetic anchor click is the only approach that works
/// across browsers without a server round-trip. `text/calendar` is what makes a
/// double-click open Calendar rather than a text editor.
///
/// The object URL is revoked on a later turn of the event loop: revoking it
/// synchronously races the browser's own read of the blob in Safari.
bool downloadIcs(String content, String filename) {
  try {
    // A leading BOM would be legal UTF-8 but confuses some desktop clients'
    // parsers, so it is deliberately not added.
    final options = JSObject()
      ..setProperty('type'.toJS, 'text/calendar;charset=utf-8'.toJS);
    final blob = _Blob(<JSAny>[content.toJS].toJS, options);
    final url = _createObjectUrl(blob);

    final anchor = _document.createElement('a')
      ..setAttribute('href', url)
      ..setAttribute('download', filename)
      ..setAttribute('rel', 'noopener');

    _document.body?.appendChild(anchor);
    anchor.click();
    anchor.remove();

    Future<void>.delayed(const Duration(seconds: 30), () {
      try {
        _revokeObjectUrl(url);
      } catch (_) {}
    });
    return true;
  } catch (_) {
    return false;
  }
}

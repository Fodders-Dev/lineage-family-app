// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

const bool supportsChatAttachmentDownload = true;

Future<void> downloadChatAttachment(
  String url, {
  String? suggestedFileName,
}) async {
  final anchor = html.AnchorElement(href: url)
    ..style.display = 'none'
    ..target = '_blank';
  final fileName = suggestedFileName?.trim();
  if (fileName != null && fileName.isNotEmpty) {
    anchor.download = fileName;
  }
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
}

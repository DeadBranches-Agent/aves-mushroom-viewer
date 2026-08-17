import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/source/collection_source.dart';
import 'package:aves/sftp/prefs.dart';
import 'package:aves/sftp/sftp_media_service.dart';
import 'package:aves/widgets/common/action_mixins/feedback.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/dialogs/aves_confirmation_dialog.dart';
import 'package:aves/widgets/settings/sftp/error_feedback.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

// remote deletion for entries of `EntryOrigins.sftp`, shared by the viewer and
// selection delete actions. the platform delete op ignores `sftp://` URIs, so
// these entries are confirmed and deleted here, before the regular delete flow.
mixin SftpEntryDeleteMixin on FeedbackMixin {
  // returns the deleted entries (empty when cancelled or nothing succeeded)
  Future<Set<AvesEntry>> doDeleteSftp(BuildContext context, Set<AvesEntry> entries) async {
    if (entries.isEmpty) return {};

    final l10n = context.l10n;
    final count = entries.length;
    if (!await showConfirmationDialog(
      context: context,
      message: sftpPrefs.deleteToRemoteTrash ? l10n.sftpDeleteToTrashConfirmationDialogMessage(count) : l10n.deleteEntriesConfirmationDialogMessage(count),
      ok: l10n.deleteButtonLabel,
    )) {
      return {};
    }

    final source = context.read<CollectionSource>();
    final result = await sftpMediaService.deleteEntries(entries, source);
    final deleted = entries.where((entry) => result.deletedUris.contains(entry.uri)).toSet();

    final failureCount = count - deleted.length;
    if (failureCount > 0) {
      final error = result.firstError;
      showFeedback(context, FeedbackType.warn, error != null ? sftpErrorMessage(l10n, error) : l10n.collectionDeleteFailureFeedback(failureCount));
    }
    return deleted;
  }
}

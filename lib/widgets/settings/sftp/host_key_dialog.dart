import 'package:aves/sftp/model/sftp_host.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/identity/aves_caption.dart';
import 'package:aves/widgets/dialogs/aves_dialog.dart';
import 'package:flutter/material.dart';

const sftpHostKeyDialogRouteName = '/dialog/sftp_host_key';

Future<bool> confirmSftpHostKey(BuildContext context, SftpHost host, String fingerprint) async {
  final l10n = context.l10n;
  final trusted = await showAvesDialog<bool>(
    context: context,
    builder: (context) => AvesDialog(
      title: l10n.settingsSftpHostKeyDialogTitle,
      scrollableContent: [
        Padding(
          padding: const EdgeInsets.all(16) + const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: .min,
            crossAxisAlignment: .start,
            children: [
              Text(l10n.settingsSftpHostKeyDialogMessage(host.name, '${host.host}:${host.port}')),
              const SizedBox(height: 16),
              AvesCaption(l10n.settingsSftpHostKeyDialogFingerprintLabel),
              const SizedBox(height: 4),
              SelectableText(
                fingerprint,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
      ],
      actions: [
        const CancelButton<bool>(result: false),
        TextButton(
          onPressed: () => Navigator.maybeOf(context)?.pop<bool>(true),
          child: Text(l10n.settingsSftpHostKeyTrustButtonLabel),
        ),
      ],
    ),
    routeSettings: const RouteSettings(name: sftpHostKeyDialogRouteName),
  );
  return trusted ?? false;
}

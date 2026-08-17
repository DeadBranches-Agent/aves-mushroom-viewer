import 'dart:async';

import 'package:aves/model/settings/enums/accessibility_animations.dart';
import 'package:aves/model/settings/settings.dart';
import 'package:aves/model/source/collection_source.dart';
import 'package:aves/sftp/cache.dart';
import 'package:aves/sftp/model/sftp_host.dart';
import 'package:aves/sftp/permission.dart';
import 'package:aves/sftp/sftp_media_service.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/theme/text.dart';
import 'package:aves/utils/file_utils.dart';
import 'package:aves/widgets/common/action_mixins/feedback.dart';
import 'package:aves/widgets/common/basic/popup/menu_row.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/identity/aves_caption.dart';
import 'package:aves/widgets/common/identity/aves_fab.dart';
import 'package:aves/widgets/common/identity/empty.dart';
import 'package:aves/widgets/dialogs/aves_confirmation_dialog.dart';
import 'package:aves/widgets/settings/sftp/error_feedback.dart';
import 'package:aves/widgets/settings/sftp/sftp_host_edit_page.dart';
import 'package:aves_model/aves_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

enum SftpHostAction { edit, clearCache, remove }

class SftpHostsPage extends StatefulWidget {
  static const routeName = '/settings/sftp_hosts';

  const SftpHostsPage({super.key});

  @override
  State<SftpHostsPage> createState() => _SftpHostsPageState();
}

class _SftpHostsPageState extends State<SftpHostsPage> with FeedbackMixin {
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AvesScaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !settings.useTvLayout,
        title: Text(l10n.settingsSftpHostsPageTitle),
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: sftpHosts,
          builder: (context, child) {
            final hosts = sftpHosts.all;
            if (hosts.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(8),
                child: EmptyContent(
                  icon: AIcons.sftp,
                  text: l10n.settingsSftpHostsEmpty,
                ),
              );
            }

            return ListView(
              children: hosts.map((v) => _buildHostTile(context, v)).toList(),
            );
          },
        ),
      ),
      floatingActionButton: AvesFab(
        tooltip: l10n.settingsSftpAddHostTooltip,
        icon: const Icon(AIcons.add),
        onPressed: () => _addHost(context),
      ),
    );
  }

  Widget _buildHostTile(BuildContext context, SftpHost host) {
    final l10n = context.l10n;
    final animations = context.select<Settings, AccessibilityAnimations>((v) => v.accessibilityAnimations);
    final subtitle = [
      '${host.username}@${host.host}:${host.port} ${host.directory}',
      l10n.settingsSftpHostCacheSize(formatFileSize(settings.avesLocale, sftpCache.sizeForHost(host.id))),
    ].join(AText.separator);

    return ListTile(
      title: Text(host.name),
      subtitle: AvesCaption(subtitle),
      onTap: () => _editHost(context, host),
      trailing: PopupMenuButton<SftpHostAction>(
        itemBuilder: (context) {
          return [
            PopupMenuItem(
              value: SftpHostAction.edit,
              child: MenuRow(text: l10n.settingsSftpHostActionEdit, icon: const Icon(AIcons.edit)),
            ),
            PopupMenuItem(
              value: SftpHostAction.clearCache,
              child: MenuRow(text: l10n.settingsSftpHostActionClearCache, icon: const Icon(AIcons.clear)),
            ),
            PopupMenuItem(
              value: SftpHostAction.remove,
              child: MenuRow(text: l10n.settingsSftpHostActionRemove, icon: const Icon(AIcons.delete)),
            ),
          ];
        },
        onSelected: (action) async {
          // wait for the popup menu to hide before proceeding with the action
          await Future.delayed(animations.popUpAnimationDelay * timeDilation);
          if (!context.mounted) return;

          switch (action) {
            case .edit:
              await _editHost(context, host);
            case .clearCache:
              await _clearCache(context, host);
            case .remove:
              await _removeHost(context, host);
          }
        },
        popUpAnimationStyle: animations.popUpAnimationStyle,
      ),
    );
  }

  Future<void> _addHost(BuildContext context) async {
    final host = await Navigator.maybeOf(context)?.push<SftpHost>(
      MaterialPageRoute(
        settings: const RouteSettings(name: SftpHostEditPage.routeName),
        builder: (context) => const SftpHostEditPage(),
      ),
    );
    if (host == null || !context.mounted) return;

    await _refreshHost(context, host);
  }

  Future<void> _editHost(BuildContext context, SftpHost host) async {
    final edited = await Navigator.maybeOf(context)?.push<SftpHost>(
      MaterialPageRoute(
        settings: const RouteSettings(name: SftpHostEditPage.routeName),
        builder: (context) => SftpHostEditPage(initialHost: host),
      ),
    );
    if (edited == null || !context.mounted) return;

    await _refreshHost(context, edited);
  }

  Future<void> _clearCache(BuildContext context, SftpHost host) async {
    final l10n = context.l10n;
    if (!await showConfirmationDialog(
      context: context,
      message: l10n.settingsSftpClearCacheConfirmationDialogMessage(host.name),
      ok: l10n.deleteButtonLabel,
    )) {
      return;
    }

    await sftpCache.clearHost(host.id);
    if (!mounted) return;

    setState(() {});
  }

  Future<void> _removeHost(BuildContext context, SftpHost host) async {
    final l10n = context.l10n;
    final source = context.read<CollectionSource>();
    if (!await showConfirmationDialog(
      context: context,
      message: l10n.settingsSftpRemoveHostConfirmationDialogMessage(host.name),
      ok: l10n.settingsSftpRemoveHostButtonLabel,
    )) {
      return;
    }

    await sftpMediaService.removeHostData(host, source);
    await sftpHosts.remove(host.id);
  }

  Future<void> _refreshHost(BuildContext context, SftpHost host) async {
    final l10n = context.l10n;
    final source = context.read<CollectionSource>();

    if (!await requestLocalNetworkPermission()) {
      if (!context.mounted) return;

      showFeedback(context, FeedbackType.warn, l10n.settingsSftpLocalNetworkPermissionDeniedFeedback);
      return;
    }
    if (!context.mounted) return;

    final reportController = StreamController.broadcast();
    unawaited(
      showOpReport(
        context: context,
        opStream: reportController.stream,
      ),
    );

    Object? error;
    int? listedCount;
    try {
      listedCount = await sftpMediaService.refreshHost(host, source);
    } catch (e) {
      error = e;
    }
    await reportController.close();

    if (!context.mounted) return;

    if (error != null) {
      showFeedback(context, FeedbackType.warn, sftpErrorMessage(l10n, error));
    } else if (listedCount == 0) {
      showFeedback(context, FeedbackType.warn, l10n.settingsSftpNoImagesFoundFeedback(host.directory));
    } else {
      showFeedback(context, FeedbackType.info, l10n.genericSuccessFeedback);
    }
    setState(() {});
  }
}

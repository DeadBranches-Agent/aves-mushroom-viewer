import 'package:aves/sftp/prefs.dart';
import 'package:aves/theme/colors.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/identity/aves_caption.dart';
import 'package:aves/widgets/dialogs/selection_dialogs/common.dart';
import 'package:aves/widgets/dialogs/selection_dialogs/single_selection.dart';
import 'package:aves/widgets/settings/common/tile_leading.dart';
import 'package:aves/widgets/settings/common/tiles.dart';
import 'package:aves/widgets/settings/settings_definition.dart';
import 'package:aves/widgets/settings/sftp/sftp_hosts_page.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class SftpSection extends SettingsSection {
  @override
  String get key => 'sftp';

  @override
  Widget icon(BuildContext context) => SettingsTileLeading(
    icon: AIcons.sftp,
    color: context.select<AvesColorsData, Color>((v) => v.fromHue(190)),
  );

  @override
  String title(BuildContext context) => context.l10n.settingsSftpSectionTitle;

  @override
  Future<List<SettingsTile>> tiles(BuildContext context) async {
    return [
      SettingsTileSftpHosts(),
      SettingsTileSftpPrefetchAhead(),
      SettingsTileSftpPrefetchBehind(),
    ];
  }
}

class SettingsTileSftpHosts extends SettingsTile {
  @override
  List<String> get settingKeys => []; // no editable settings

  @override
  String title(BuildContext context) => context.l10n.settingsSftpHostsTile;

  @override
  Widget build(BuildContext context) => SettingsSubPageTile(
    title: title,
    routeName: SftpHostsPage.routeName,
    builder: (context) => const SftpHostsPage(),
  );
}

class SettingsTileSftpPrefetchAhead extends SettingsTile {
  @override
  List<String> get settingKeys => []; // stored in the sftp module, not app settings

  @override
  String title(BuildContext context) => context.l10n.settingsSftpPrefetchAheadTile;

  @override
  Widget build(BuildContext context) => _SftpPrefetchCountTile(
    title: title,
    values: const [0, 1, 2, 3, 4, 5, 8],
    getValue: () => sftpPrefs.prefetchAhead,
    setValue: (v) => sftpPrefs.prefetchAhead = v,
  );
}

class SettingsTileSftpPrefetchBehind extends SettingsTile {
  @override
  List<String> get settingKeys => []; // stored in the sftp module, not app settings

  @override
  String title(BuildContext context) => context.l10n.settingsSftpPrefetchBehindTile;

  @override
  Widget build(BuildContext context) => _SftpPrefetchCountTile(
    title: title,
    values: const [0, 1, 2, 3],
    getValue: () => sftpPrefs.prefetchBehind,
    setValue: (v) => sftpPrefs.prefetchBehind = v,
  );
}

class _SftpPrefetchCountTile extends StatelessWidget {
  final TitleBuilder title;
  final List<int> values;
  final int Function() getValue;
  final ValueChanged<int> setValue;

  const _SftpPrefetchCountTile({
    required this.title,
    required this.values,
    required this.getValue,
    required this.setValue,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sftpPrefs,
      builder: (context, child) => ListTile(
        title: Text(title(context) ?? '?'),
        subtitle: AvesCaption('${getValue()}'),
        onTap: () => showSelectionDialog<int>(
          context: context,
          builder: (context) => AvesSingleSelectionDialog<int>(
            initialValue: getValue(),
            options: Map.fromEntries(values.map((v) => MapEntry(v, '$v'))),
            title: title(context),
          ),
          onSelection: setValue,
        ),
      ),
    );
  }
}

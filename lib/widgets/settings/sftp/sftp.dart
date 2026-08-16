import 'package:aves/theme/colors.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
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

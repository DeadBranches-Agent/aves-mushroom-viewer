import 'package:aves/model/settings/settings.dart';
import 'package:aves/sftp/model/sftp_host.dart';
import 'package:aves/theme/icons.dart';
import 'package:aves/widgets/common/basic/scaffold.dart';
import 'package:aves/widgets/common/extensions/build_context.dart';
import 'package:aves/widgets/common/identity/aves_caption.dart';
import 'package:aves/widgets/common/identity/aves_fab.dart';
import 'package:aves/widgets/dialogs/selection_dialogs/common.dart';
import 'package:aves/widgets/dialogs/selection_dialogs/single_selection.dart';
import 'package:flutter/material.dart';

class SftpHostEditPage extends StatefulWidget {
  static const routeName = '/settings/sftp_host_edit';

  static const defaultPort = 22;

  final SftpHost? initialHost;

  const SftpHostEditPage({
    super.key,
    this.initialHost,
  });

  @override
  State<SftpHostEditPage> createState() => _SftpHostEditPageState();
}

class _SftpHostEditPageState extends State<SftpHostEditPage> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _secretController = TextEditingController();
  final TextEditingController _directoryController = TextEditingController();
  late SftpAuthType _authType;

  final ValueNotifier<bool> _portValidNotifier = ValueNotifier(true);
  final ValueNotifier<bool> _isValidNotifier = ValueNotifier(false);

  SftpHost? get initialHost => widget.initialHost;

  bool get isNew => initialHost == null;

  @override
  void initState() {
    super.initState();
    final host = initialHost;
    _nameController.text = host?.name ?? '';
    _hostController.text = host?.host ?? '';
    _portController.text = '${host?.port ?? SftpHostEditPage.defaultPort}';
    _usernameController.text = host?.username ?? '';
    _directoryController.text = host?.directory ?? '';
    _authType = host?.authType ?? SftpAuthType.password;
    _validate();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _secretController.dispose();
    _directoryController.dispose();
    _portValidNotifier.dispose();
    _isValidNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AvesScaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !settings.useTvLayout,
        title: Text(isNew ? l10n.settingsSftpNewHostPageTitle : l10n.settingsSftpEditHostPageTitle),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _buildTextField(
              controller: _nameController,
              labelText: l10n.settingsSftpHostNameLabel,
            ),
            _buildTextField(
              controller: _hostController,
              labelText: l10n.settingsSftpHostAddressLabel,
              keyboardType: TextInputType.url,
            ),
            ValueListenableBuilder<bool>(
              valueListenable: _portValidNotifier,
              builder: (context, portValid, child) {
                return _buildTextField(
                  controller: _portController,
                  labelText: l10n.settingsSftpHostPortLabel,
                  helperText: portValid ? '' : l10n.settingsSftpHostPortInvalidHelper,
                  keyboardType: TextInputType.number,
                );
              },
            ),
            _buildTextField(
              controller: _usernameController,
              labelText: l10n.settingsSftpHostUsernameLabel,
            ),
            ListTile(
              title: Text(l10n.settingsSftpHostAuthTypeTile),
              subtitle: AvesCaption(_authTypeName(context, _authType)),
              onTap: () {
                _unfocus();
                showSelectionDialog<SftpAuthType>(
                  context: context,
                  builder: (context) => AvesSingleSelectionDialog<SftpAuthType>(
                    initialValue: _authType,
                    options: Map.fromEntries(SftpAuthType.values.map((v) => MapEntry(v, _authTypeName(context, v)))),
                    title: l10n.settingsSftpHostAuthTypeDialogTitle,
                  ),
                  onSelection: (v) => setState(() {
                    _authType = v;
                    _validate();
                  }),
                );
              },
            ),
            _buildTextField(
              controller: _secretController,
              labelText: switch (_authType) {
                SftpAuthType.password => l10n.settingsSftpHostPasswordLabel,
                SftpAuthType.privateKey => l10n.settingsSftpHostPrivateKeyLabel,
              },
              helperText: isNew ? null : l10n.settingsSftpHostSecretUnchangedHelper,
              obscureText: _authType == SftpAuthType.password,
              keyboardType: _authType == SftpAuthType.privateKey ? TextInputType.multiline : null,
              minLines: _authType == SftpAuthType.privateKey ? 4 : null,
              maxLines: _authType == SftpAuthType.privateKey ? null : 1,
            ),
            _buildTextField(
              controller: _directoryController,
              labelText: l10n.settingsSftpHostDirectoryLabel,
            ),
          ],
        ),
      ),
      floatingActionButton: ValueListenableBuilder<bool>(
        valueListenable: _isValidNotifier,
        builder: (context, isValid, child) {
          return AvesFab(
            tooltip: l10n.saveTooltip,
            icon: const Icon(AIcons.apply),
            onPressed: isValid ? () => _submit(context) : null,
          );
        },
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String labelText,
    String? helperText,
    bool obscureText = false,
    TextInputType? keyboardType,
    int? minLines,
    int? maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: labelText,
          helperText: helperText,
        ),
        obscureText: obscureText,
        keyboardType: keyboardType,
        minLines: minLines,
        maxLines: maxLines,
        onChanged: (_) => _validate(),
      ),
    );
  }

  String _authTypeName(BuildContext context, SftpAuthType authType) {
    final l10n = context.l10n;
    return switch (authType) {
      SftpAuthType.password => l10n.settingsSftpHostAuthTypePassword,
      SftpAuthType.privateKey => l10n.settingsSftpHostAuthTypePrivateKey,
    };
  }

  // remove focus, if any, to prevent the keyboard from showing up
  // after the user is done with the page
  void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

  int? get _port {
    final port = int.tryParse(_portController.text.trim());
    return port != null && port > 0 && port <= 65535 ? port : null;
  }

  void _validate() {
    final port = _port;
    _portValidNotifier.value = port != null;
    _isValidNotifier.value =
        port != null &&
        _nameController.text.trim().isNotEmpty &&
        _hostController.text.trim().isNotEmpty &&
        _usernameController.text.trim().isNotEmpty &&
        _directoryController.text.trim().isNotEmpty &&
        (!isNew || _secretController.text.isNotEmpty);
  }

  Future<void> _submit(BuildContext context) async {
    if (!_isValidNotifier.value) return;

    _unfocus();

    final name = _nameController.text.trim();
    final hostAddress = _hostController.text.trim();
    final port = _port!;
    final username = _usernameController.text.trim();
    final directory = _directoryController.text.trim();
    final secret = _secretController.text;

    final SftpHost host;
    final existing = initialHost;
    if (existing == null) {
      host = await sftpHosts.add(
        name: name,
        host: hostAddress,
        port: port,
        username: username,
        authType: _authType,
        directory: directory,
        secret: secret,
      );
    } else {
      host = existing.copyWith(
        name: name,
        host: hostAddress,
        port: port,
        username: username,
        authType: _authType,
        directory: directory,
      );
      await sftpHosts.update(host, secret: secret.isEmpty ? null : secret);
    }
    if (!context.mounted) return;

    Navigator.maybeOf(context)?.pop<SftpHost>(host);
  }
}

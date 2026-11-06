import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart' show DshCookie, DshException;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/direct/direct_link.dart';
import '../../state/hosts_state.dart';
import '../common/app_dialog.dart';
import '../common/discard_guard.dart';
import '../common/smooth_size.dart';
import '../providers/provider_widgets.dart' show FormFieldBlock, FormFieldGroup;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Add or edit a direct host: an `https://` DSH server (typically `dsh web`
/// behind nginx) reached by its base URL and an access token. "测试连接" opens
/// it once and reports how long that took.
class DirectHostFormPage extends ConsumerStatefulWidget {
  const DirectHostFormPage({super.key, this.existing});

  /// Null to add a new host.
  final DirectHostConfig? existing;

  @override
  ConsumerState<DirectHostFormPage> createState() => _DirectHostFormPageState();
}

class _DirectHostFormPageState extends ConsumerState<DirectHostFormPage> {
  late final String _id = widget.existing?.id ?? DirectHostConfig.newId();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _url = TextEditingController(text: widget.existing?.baseUrl ?? '');
  final _token = TextEditingController();

  bool _obscure = true;
  bool _saving = false;
  bool _testing = false;

  /// The stored session cookie, kept on save so a later start resumes without
  /// the token. Only the token and the URL are visible in the form.
  DshCookie? _cookie;

  /// The saved token/cookie is read asynchronously; saving and testing wait for
  /// it so neither can overwrite (or miss) a cookie it has not seen yet.
  Future<void>? _secretsLoad;

  /// A problem that isn't about one field (saving failed).
  String? _formError;

  /// What is missing or wrong, shown under the field it is about.
  Map<_F, String> _errors = const {};

  /// To bring the first field with a problem into view.
  final _fieldKeys = {for (final f in _F.values) f: GlobalKey()};

  /// Result of the last "测试连接": elapsed time when it worked, the sentence
  /// when it did not. Null while untouched.
  Duration? _testOk;
  String? _testError;

  /// The form as opened (with the saved token once it is read).
  late String _clean;

  late final Listenable _edits = Listenable.merge([_name, _url, _token]);

  bool get _editing => widget.existing != null;

  String _signature() => jsonEncode({'name': _name.text, 'url': _url.text, 'token': _token.text});

  @override
  void initState() {
    super.initState();
    _clean = _signature();
    if (_editing) _secretsLoad = _loadSecrets();
  }

  Future<void> _loadSecrets() async {
    final clean = jsonDecode(_clean) as Map<String, dynamic>;
    final initialToken = _token.text;
    var edited = false;
    void trackEdits() {
      if (_token.text != initialToken) edited = true;
    }

    _token.addListener(trackEdits);
    DirectSecrets secrets = const DirectSecrets();
    try {
      secrets = await ref.read(hostsProvider.notifier).loadDirectSecrets(_id);
    } catch (_) {
      // An unreadable store only costs the prefill.
    } finally {
      _token.removeListener(trackEdits);
    }
    if (!mounted) return;
    setState(() {
      _cookie = secrets.cookie;
      // A token typed (or pasted) while the store was read wins over it.
      if (!edited) _token.text = secrets.token;
      // The prefill is the saved state, not an edit.
      _clean = jsonEncode({...clean, 'token': secrets.token});
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _url, _token]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The config as typed; null (with [_errors] set) when incomplete.
  DirectHostConfig? _draft() {
    final l10n = context.l10n;
    final base = parseDirectBaseUrl(_url.text.trim());
    final token = _token.text.trim();
    // A saved cookie resumes the session, but it is bound to the authority it
    // was minted for: moving the host to another domain must ask for a token
    // again instead of replaying a cookie the new server will reject.
    final needsToken = !_editing || _cookie == null || !_sameAuthority(base);
    final errors = <_F, String>{
      if (base == null) _F.url: l10n.remoteDirectUrlInvalid,
      if (needsToken && token.isEmpty) _F.token: l10n.remoteDirectTokenRequired,
    };
    setState(() {
      _errors = errors;
      _formError = null;
    });
    if (errors.isNotEmpty) {
      final first = _F.values.firstWhere(errors.containsKey);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _fieldKeys[first]!.currentContext;
        if (target == null || !target.mounted) return;
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: 0.3,
            duration: AppMotion.of(context, AppMotion.emphasized),
            curve: AppMotion.glide,
          ),
        );
      });
      return null;
    }
    return DirectHostConfig(
      id: _id,
      name: _name.text.trim().isEmpty ? base!.host : _name.text.trim(),
      baseUrl: base.toString(),
    );
  }

  /// Typing in a field clears its error.
  void _edited(_F field) {
    if (_errors.containsKey(field)) setState(() => _errors = {..._errors}..remove(field));
  }

  Future<void> _pasteToken() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    setState(() {
      _token.text = text;
      _errors = {..._errors}..remove(_F.token);
    });
  }

  String _failureSentence(Object error) => switch (error) {
    HostLinkError(:final message) => message,
    DshException(:final message) => message,
    _ => error.toString(),
  };

  Future<void> _runTest() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await _secretsLoad;
    if (!mounted) return;
    final config = _draft();
    if (config == null) return;
    final token = _token.text.trim();
    // A cookie minted for another domain would only produce a misleading 401.
    final cookie = _sameAuthority(config.baseUri) ? _cookie : null;
    setState(() {
      _testing = true;
      _testOk = null;
      _testError = null;
    });
    try {
      final elapsed = await probeDirectHost(baseUri: config.baseUri, token: token, cookie: cookie);
      if (mounted) setState(() => _testOk = elapsed);
    } catch (e) {
      if (mounted) setState(() => _testError = _failureSentence(e));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// Whether the URL being edited keeps the domain the stored cookie was
  /// minted for.
  bool _sameAuthority(Uri? base) {
    if (_cookie == null) return false;
    if (base == null) return false;
    final existing = widget.existing;
    if (existing == null) return false;
    final was = Uri.tryParse(existing.baseUrl);
    return was != null && base.authority == was.authority;
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await _secretsLoad;
    if (!mounted) return;
    final config = _draft();
    if (config == null) return;
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(hostsProvider.notifier)
          .saveDirect(
            config,
            secrets: DirectSecrets(
              token: _token.text.trim(),
              // Same rule on save: the cookie only travels with its own domain.
              cookie: _sameAuthority(config.baseUri) ? _cookie : null,
            ),
          );
      if (!mounted) return;
      if (!saved) {
        setState(() => _formError = context.l10n.commonSaveFailed);
        return;
      }
      Navigator.of(context).pop(config);
    } catch (_) {
      if (mounted) setState(() => _formError = context.l10n.commonSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final name = widget.existing!.name;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.remoteDirectDelete),
        content: Text(context.l10n.remoteDirectDeleteBody(name)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(hostsProvider.notifier).removeDirect(_id);
    if (mounted) Navigator.of(context).pop();
  }

  Widget _testCard(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final error = _testError;
    final ok = _testOk;
    final Widget mark;
    final String title;
    final Color titleColor;
    if (_testing) {
      mark = SizedBox.square(
        dimension: 20,
        child: Padding(
          padding: const EdgeInsets.all(2.5),
          child: CircularProgressIndicator(strokeWidth: 2.2, color: scheme.primary),
        ),
      );
      title = l10n.remoteDirectTesting;
      titleColor = scheme.onSurface;
    } else if (error != null) {
      mark = Icon(AppIcons.error, size: 20, color: colors.danger);
      title = l10n.remoteDirectTestFail;
      titleColor = colors.danger;
    } else {
      mark = Icon(AppIcons.success, size: 20, color: colors.success);
      title = l10n.remoteDirectTestOk(ok?.inMilliseconds ?? 0);
      titleColor = scheme.onSurface;
    }
    return GlassSurface(
      tier: GlassTier.card,
      borderRadius: AppShape.radiusLg,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          mark,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium?.copyWith(color: titleColor)),
                if (error != null) ...[
                  const SizedBox(height: 4),
                  Text(error, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final testing = _testing;
    final mono = AppType.mono(size: 15, color: scheme.onSurface, height: 1.4);

    final page = AppPage.list(
      title: _editing ? l10n.remoteDirectEdit : l10n.remoteDirectAdd,
      subtitle: _editing ? null : Text(l10n.remoteDirectSectionHint),
      // One column, not a lazy list: every field stays built so the first one
      // with a problem can be scrolled into view.
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSection(
              title: l10n.remoteDirectSection,
              footer: Text(l10n.remoteDirectHelp),
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      key: _fieldKeys[_F.name],
                      label: l10n.remoteDirectName,
                      child: TextField(
                        controller: _name,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(hintText: l10n.remoteDirectNameHint),
                      ),
                    ),
                    FormFieldBlock(
                      key: _fieldKeys[_F.url],
                      error: _errors[_F.url],
                      label: l10n.remoteDirectUrl,
                      helper: l10n.remoteDirectUrlNote,
                      child: TextField(
                        controller: _url,
                        autocorrect: false,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.next,
                        style: mono,
                        onChanged: (_) => _edited(_F.url),
                        decoration: InputDecoration(
                          hintText: l10n.remoteDirectUrlHint,
                          error: _errors[_F.url] == null ? null : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    FormFieldBlock(
                      key: _fieldKeys[_F.token],
                      error: _errors[_F.token],
                      label: l10n.remoteDirectToken,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _SmallTextButton(
                            label: _obscure ? l10n.remoteDirectShowToken : l10n.remoteDirectHideToken,
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                          _SmallTextButton(label: l10n.remoteDirectPaste, onPressed: _pasteToken),
                        ],
                      ),
                      child: TextField(
                        controller: _token,
                        obscureText: _obscure,
                        obscuringCharacter: '•',
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        keyboardType: TextInputType.visiblePassword,
                        textInputAction: TextInputAction.done,
                        style: mono,
                        onChanged: (_) => _edited(_F.token),
                        decoration: InputDecoration(
                          hintText: l10n.remoteDirectTokenHint,
                          error: _errors[_F.token] == null ? null : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            _Reveal(
              child: _testing || _testOk != null || _testError != null
                  ? Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), child: _testCard(context))
                  : const SizedBox(width: double.infinity),
            ),
            if (_formError case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
              ),
            if (_editing)
              Center(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: colors.danger),
                  onPressed: _delete,
                  icon: const Icon(AppIcons.delete, size: 19),
                  label: Text(l10n.remoteDirectDelete),
                ),
              ),
            const SizedBox(height: _FormBar.height),
          ],
        ),
      ],
    );

    return DiscardGuard(
      listenable: _edits,
      isDirty: () => !_saving && _signature() != _clean,
      child: Stack(
        children: [
          page,
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: _FormBar(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: testing || _saving ? null : _runTest,
                    icon: testing
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(AppIcons.testConnection, size: 19),
                    label: Text(testing ? l10n.remoteTesting : l10n.remoteTestConnection),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(onPressed: _saving ? null : _save, child: Text(l10n.commonSave)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The fields of a direct-host form page.
enum _F { name, url, token }

/// A compact text action in a field label row; its label ends flush with the
/// field's edge.
class _SmallTextButton extends StatelessWidget {
  const _SmallTextButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: Theme.of(context).textTheme.labelMedium,
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// The form page's bottom bar: the actions stay put above the page (and above
/// the keyboard), over a soft fade of the page background.
class _FormBar extends StatelessWidget {
  const _FormBar({required this.children});

  final List<Widget> children;

  /// Room to leave at the end of the page so nothing hides under the bar.
  static const height = 88.0;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom > 0 ? 0.0 : MediaQuery.viewPaddingOf(context).bottom;
    final base = DshSurfaces.of(context).backdropBottom;
    // The page fades out above the keys; under them the bar is solid, so
    // nothing scrolls through a tonal or disabled fill.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [base.withValues(alpha: 0), base],
            ),
          ),
          child: const SizedBox(height: 24),
        ),
        ColoredBox(
          color: base,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + bottom),
            child: Row(children: children),
          ),
        ),
      ],
    );
  }
}

/// [AnimatedSize] unless animations are off (a zero-duration AnimatedSize
/// re-dirties itself during layout).
class _Reveal extends StatelessWidget {
  const _Reveal({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.of(context, AppMotion.standard);
    if (duration == Duration.zero) return child;
    return SmoothSize(duration: duration, curve: AppMotion.std, alignment: Alignment.topCenter, child: child);
  }
}

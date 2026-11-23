import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_update_manager.dart';

class AppUpdateView extends StatefulWidget {
  const AppUpdateView({super.key, this.manager});

  final AppUpdateManager? manager;

  @override
  State<AppUpdateView> createState() => _AppUpdateViewState();
}

class _AppUpdateViewState extends State<AppUpdateView> {
  late final AppUpdateManager _manager = widget.manager ?? AppUpdateManager();
  bool _ownsManager = false;
  bool _loading = true;
  String? _error;
  AppUpdateInfo? _info;

  @override
  void initState() {
    super.initState();
    _ownsManager = widget.manager == null;
    _check();
  }

  @override
  void dispose() {
    if (_ownsManager) _manager.close();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _manager.checkForUpdates();
      if (!mounted) return;
      setState(() {
        _info = result;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _download() async {
    final info = _info;
    if (info == null) return;
    final uri = info.latest.apkUrl ?? info.latest.url;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开版本下载地址')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final info = _info;
    return Scaffold(
      appBar: AppBar(
        title: const Text('FLS APP 更新'),
        actions: [
          IconButton(
            tooltip: '重新检查',
            onPressed: _loading ? null : _check,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off_outlined, color: colorScheme.error),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _check,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          : info == null
          ? const SizedBox.shrink()
          : _buildRelease(context, info),
      bottomNavigationBar: info?.updateAvailable == true
          ? SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(
                onPressed: _download,
                icon: const Icon(Icons.download),
                label: const Text('下载 APK'),
              ),
            )
          : null,
    );
  }

  Widget _buildRelease(BuildContext context, AppUpdateInfo info) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasCommits = info.latest.commits.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              info.updateAvailable
                  ? Icons.system_update_alt
                  : Icons.check_circle_outline,
              color: info.updateAvailable
                  ? colorScheme.primary
                  : colorScheme.tertiary,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info.updateAvailable ? '发现新版本' : '当前已是最新版本',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '当前 ${info.currentVersion}  ·  最新 ${info.latest.tagName}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (hasCommits) ...[
          Text('版本间变更', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final commit in info.latest.commits)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.commit,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(commit.message),
                        const SizedBox(height: 3),
                        Text(
                          commit.sha.substring(0, 7),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ] else if (info.latest.body.isNotEmpty) ...[
          Text('更新日志', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText(info.latest.body),
        ] else ...[
          Text(
            '此版本没有附带变更说明。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

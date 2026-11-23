import 'package:flutter/material.dart';

import '../services/local_install_manager.dart';
import '../services/online_scripts_manager.dart';
import '../services/operation_cancellation.dart';

class OnlineScriptsView extends StatefulWidget {
  const OnlineScriptsView({
    super.key,
    required this.runtimeAvailable,
    required this.installManager,
    required this.onOpenEnvironment,
    required this.onBusyChanged,
  });

  final bool runtimeAvailable;
  final LocalInstallManager installManager;
  final VoidCallback onOpenEnvironment;
  final ValueChanged<bool> onBusyChanged;

  @override
  State<OnlineScriptsView> createState() => _OnlineScriptsViewState();
}

class _OnlineScriptsViewState extends State<OnlineScriptsView> {
  final _manager = OnlineScriptsManager();
  final _searchController = TextEditingController();
  List<OnlineScript> _scripts = const [];
  bool _loading = true;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _manager.close();
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final scripts = await _manager.fetchCatalog();
      if (!mounted) return;
      setState(() {
        _scripts = scripts;
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

  List<OnlineScript> get _filteredScripts {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _scripts;
    return _scripts
        .where(
          (script) =>
              script.name.toLowerCase().contains(query) ||
              script.id.toLowerCase().contains(query) ||
              script.linkName.toLowerCase().contains(query),
        )
        .toList();
  }

  void _openScript(OnlineScript script) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _OnlineScriptDetailPage(
          manager: _manager,
          installManager: widget.installManager,
          script: script,
          runtimeAvailable: widget.runtimeAvailable,
          onOpenEnvironment: widget.onOpenEnvironment,
          onBusyChanged: widget.onBusyChanged,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final scripts = _filteredScripts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  labelText: '搜索脚本',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '刷新目录',
              onPressed: _loading ? null : _loadCatalog,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (!widget.runtimeAvailable)
          _InlineNotice(
            icon: Icons.inventory_2_outlined,
            text: '安装本机运行环境后即可管理脚本，无需启动面板。',
            action: '安装环境',
            onPressed: widget.onOpenEnvironment,
          )
        else
          _InlineNotice(
            icon: Icons.info_outline,
            text: '由 APP 直接拉取并安装到本机容器；面板可以保持停止。',
          ),
        const SizedBox(height: 8),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          _InlineNotice(
            icon: Icons.cloud_off_outlined,
            text: '读取在线脚本目录失败：$_error',
            action: '重试',
            onPressed: _loadCatalog,
          )
        else if (scripts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Text(
              _query.isEmpty ? '在线脚本目录为空' : '没有匹配的脚本',
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
            child: Text(
              '${scripts.length} 个脚本',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var index = 0; index < scripts.length; index++) ...[
                  if (index > 0) const Divider(height: 1, indent: 16),
                  ListTile(
                    title: Text(
                      scripts[index].name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${scripts[index].type.toUpperCase()} · ${scripts[index].linkName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openScript(scripts[index]),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _OnlineScriptDetailPage extends StatefulWidget {
  const _OnlineScriptDetailPage({
    required this.manager,
    required this.installManager,
    required this.script,
    required this.runtimeAvailable,
    required this.onOpenEnvironment,
    required this.onBusyChanged,
  });

  final OnlineScriptsManager manager;
  final LocalInstallManager installManager;
  final OnlineScript script;
  final bool runtimeAvailable;
  final VoidCallback onOpenEnvironment;
  final ValueChanged<bool> onBusyChanged;

  @override
  State<_OnlineScriptDetailPage> createState() =>
      _OnlineScriptDetailPageState();
}

class _OnlineScriptDetailPageState extends State<_OnlineScriptDetailPage> {
  String _document = '';
  String? _documentError;
  bool _documentLoading = true;
  bool _installing = false;
  String _installStatus = '';
  String _installLog = '';
  int _downloadedBytes = 0;
  int? _downloadTotalBytes;
  String? _installError;
  OperationCancellation? _cancellation;

  @override
  void initState() {
    super.initState();
    _loadDocument();
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    super.dispose();
  }

  Future<void> _loadDocument() async {
    try {
      final document = await widget.manager.fetchDocument(widget.script);
      if (!mounted) return;
      setState(() {
        _document = document;
        _documentLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _documentError = error.toString();
        _documentLoading = false;
      });
    }
  }

  Future<bool> _confirmInstall({required bool overwrite}) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(overwrite ? '更新在线脚本？' : '安装在线脚本？'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                overwrite
                    ? '本机脚本目录中已存在目标。确认后 APP 会覆盖同名文件并更新“${widget.script.name}”；目录中其他未被本次脚本覆盖的文件会保留。'
                    : 'APP 会直接拉取“${widget.script.name}”并安装到本机容器，不会启动 FLS 面板。',
              ),
              const SizedBox(height: 12),
              const Text('任务不会自动导入或启用。仅继续运行你信任来源提供的依赖安装命令。'),
              if (widget.script.installCommand.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('安装命令'),
                const SizedBox(height: 4),
                SelectableText(
                  widget.script.installCommand,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
              ],
              const SizedBox(height: 12),
              SelectableText(
                '来源：${widget.script.link}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(overwrite ? '确认更新' : '确认安装'),
          ),
        ],
      ),
    );
    return accepted == true;
  }

  Future<void> _installOrUpdate() async {
    if (!widget.runtimeAvailable || _installing) return;
    final overwrite = await widget.manager.hasInstallTarget(
      widget.script,
      widget.installManager,
    );
    if (!await _confirmInstall(overwrite: overwrite)) return;
    final cancellation = OperationCancellation();
    _cancellation = cancellation;
    setState(() {
      _installing = true;
      _installError = null;
      _installStatus = '准备本机容器';
      _installLog = '';
      _downloadedBytes = 0;
      _downloadTotalBytes = null;
    });
    widget.onBusyChanged(true);
    try {
      await widget.manager.installOrUpdateNative(
        script: widget.script,
        installManager: widget.installManager,
        overwriteExisting: overwrite,
        cancellation: cancellation,
        onStatus: (status) {
          if (mounted) setState(() => _installStatus = status);
        },
        onProgress: (receivedBytes, totalBytes) {
          if (!mounted) return;
          setState(() {
            _downloadedBytes = receivedBytes;
            _downloadTotalBytes = totalBytes;
          });
        },
        onLog: (line) {
          if (!mounted || line.isEmpty) return;
          setState(() {
            final lines = [..._installLog.split('\n'), line];
            _installLog = lines.length > 300
                ? lines.skip(lines.length - 300).join('\n')
                : lines.join('\n');
          });
        },
      );
      if (!mounted) return;
      setState(() => _installStatus = '安装完成');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('脚本已安装或更新')));
    } catch (error) {
      if (mounted) {
        setState(() {
          _installError = error.toString();
          if (cancellation.isCancelled) _installStatus = '已取消';
        });
      }
    } finally {
      widget.onBusyChanged(false);
      _cancellation = null;
      if (mounted) setState(() => _installing = false);
    }
  }

  void _cancelInstall() {
    final cancellation = _cancellation;
    if (cancellation == null || cancellation.isCancelled) return;
    cancellation.cancel();
    setState(() => _installStatus = '正在取消');
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.script.name)),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                Row(
                  children: [
                    Chip(label: Text(widget.script.type.toUpperCase())),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.script.linkName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _installing || !widget.runtimeAvailable
                      ? null
                      : _installOrUpdate,
                  icon: _installing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(_installing ? _installStatus : '安装 / 更新'),
                ),
                if (!widget.runtimeAvailable) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: widget.onOpenEnvironment,
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: const Text('先安装本机运行环境'),
                  ),
                ],
                if (_installing) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value:
                        _downloadTotalBytes == null || _downloadTotalBytes! <= 0
                        ? null
                        : (_downloadedBytes / _downloadTotalBytes!).clamp(
                            0.0,
                            1.0,
                          ),
                  ),
                  if (_downloadedBytes > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                      _downloadTotalBytes == null
                          ? '${_formatMegabytes(_downloadedBytes)} MB / -- MB'
                          : '${_formatMegabytes(_downloadedBytes)} MB / ${_formatMegabytes(_downloadTotalBytes!)} MB  ${((_downloadedBytes / _downloadTotalBytes!) * 100).round()}%',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: cancellationCancelled ? null : _cancelInstall,
                      icon: const Icon(Icons.close),
                      label: const Text('取消'),
                    ),
                  ),
                ],
                if (_installError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _installError!,
                    style: TextStyle(color: colorScheme.error),
                  ),
                  if (!widget.runtimeAvailable)
                    TextButton.icon(
                      onPressed: widget.onOpenEnvironment,
                      icon: const Icon(Icons.inventory_2_outlined),
                      label: const Text('安装本机运行环境'),
                    ),
                ],
                if (_installLog.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('安装日志', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 260),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _installLog,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ],
                const Divider(height: 28),
                Text('脚本文档', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (_documentLoading)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  )
                else if (_documentError != null)
                  Text(
                    _documentError!,
                    style: TextStyle(color: colorScheme.error),
                  )
                else if (_document.isEmpty)
                  Text(
                    '此脚本没有提供文档。',
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  )
                else
                  _MarkdownText(_document),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  bool get cancellationCancelled => _cancellation?.isCancelled ?? true;

  String _formatMegabytes(int bytes) =>
      (bytes / (1024 * 1024)).toStringAsFixed(1);
}

class _MarkdownText extends StatelessWidget {
  const _MarkdownText(this.markdown);

  final String markdown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = markdown.replaceAll('\r\n', '\n').split('\n');
    final blocks = <Widget>[];
    final code = <String>[];
    var inCode = false;
    for (final line in lines) {
      if (line.trimLeft().startsWith('```')) {
        if (inCode) {
          blocks.add(_codeBlock(context, code.join('\n')));
          code.clear();
        }
        inCode = !inCode;
        continue;
      }
      if (inCode) {
        code.add(line);
        continue;
      }
      final heading = RegExp(r'^(#{1,4})\s+(.+)$').firstMatch(line);
      if (heading != null) {
        final level = heading.group(1)!.length;
        blocks.add(
          Padding(
            padding: EdgeInsets.only(top: level == 1 ? 12 : 8, bottom: 4),
            child: Text(
              heading.group(2)!,
              style:
                  (level <= 2
                          ? theme.textTheme.titleMedium
                          : theme.textTheme.titleSmall)
                      ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        );
      } else if (RegExp(r'^\s*[-*+]\s+').hasMatch(line)) {
        final content = line.replaceFirst(RegExp(r'^\s*[-*+]\s+'), '');
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  '),
                Expanded(child: SelectableText(content)),
              ],
            ),
          ),
        );
      } else if (line.trim().isEmpty) {
        blocks.add(const SizedBox(height: 4));
      } else {
        blocks.add(SelectableText(line, style: theme.textTheme.bodyMedium));
      }
    }
    if (code.isNotEmpty) blocks.add(_codeBlock(context, code.join('\n')));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: blocks,
    );
  }

  Widget _codeBlock(BuildContext context, String text) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    required this.icon,
    required this.text,
    this.action,
    this.onPressed,
  });

  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: colors.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
          if (action != null)
            TextButton(onPressed: onPressed, child: Text(action!)),
        ],
      ),
    );
  }
}

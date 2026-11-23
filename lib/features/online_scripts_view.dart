import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/local_install_manager.dart';
import '../services/online_scripts_manager.dart';
import '../services/operation_cancellation.dart';
import '../widgets/native_markdown_view.dart';

enum _OnlineScriptTypeFilter { all, raw, repo }

class OnlineScriptsView extends StatefulWidget {
  const OnlineScriptsView({
    super.key,
    required this.runtimeAvailable,
    required this.installManager,
    required this.onOpenEnvironment,
    required this.onBusyChanged,
    this.manager,
  });

  final bool runtimeAvailable;
  final LocalInstallManager installManager;
  final VoidCallback onOpenEnvironment;
  final ValueChanged<bool> onBusyChanged;
  final OnlineScriptsManager? manager;

  @override
  State<OnlineScriptsView> createState() => _OnlineScriptsViewState();
}

class _OnlineScriptsViewState extends State<OnlineScriptsView> {
  late final OnlineScriptsManager _manager;
  late final bool _ownsManager;
  final _searchController = TextEditingController();
  List<OnlineScript> _scripts = const [];
  OnlineScriptsCatalogSnapshot? _catalog;
  final Map<String, bool?> _installedById = {};
  bool _loading = true;
  String? _error;
  String _query = '';
  _OnlineScriptTypeFilter _typeFilter = _OnlineScriptTypeFilter.all;

  @override
  void initState() {
    super.initState();
    _ownsManager = widget.manager == null;
    _manager = widget.manager ?? OnlineScriptsManager();
    _loadCatalog();
  }

  @override
  void dispose() {
    _searchController.dispose();
    if (_ownsManager) _manager.close();
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cached = await _manager.readCachedCatalog();
      if (!mounted) return;
      if (cached != null && _catalog == null) {
        setState(() {
          _catalog = cached;
          _scripts = cached.scripts;
        });
        _refreshInstalledStates(cached.scripts);
      }
      final catalog = await _manager.fetchCatalogSnapshot();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _scripts = catalog.scripts;
        _loading = false;
      });
      _refreshInstalledStates(catalog.scripts);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _refreshInstalledStates(List<OnlineScript> scripts) async {
    final states = await Future.wait(
      scripts.map((script) async {
        try {
          return await _manager.hasInstallTarget(script, widget.installManager);
        } catch (_) {
          return null;
        }
      }),
    );
    if (!mounted) return;
    setState(() {
      _installedById
        ..clear()
        ..addEntries(
          List.generate(
            scripts.length,
            (index) => MapEntry(scripts[index].id, states[index]),
          ),
        );
    });
  }

  List<OnlineScript> get _filteredScripts {
    final query = _query.trim().toLowerCase();
    return _scripts
        .where(
          (script) =>
              (_typeFilter == _OnlineScriptTypeFilter.all ||
                  script.type == _typeFilter.name) &&
              (query.isEmpty ||
                  script.name.toLowerCase().contains(query) ||
                  script.id.toLowerCase().contains(query) ||
                  script.linkName.toLowerCase().contains(query) ||
                  script.link.host.toLowerCase().contains(query) ||
                  script.link.path.toLowerCase().contains(query)),
        )
        .toList();
  }

  Future<void> _openScript(OnlineScript script) async {
    await Navigator.of(context).push<void>(
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
    if (!mounted) return;
    await _refreshInstalledStates(_scripts);
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
        SegmentedButton<_OnlineScriptTypeFilter>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: _OnlineScriptTypeFilter.all,
              label: Text('全部'),
            ),
            ButtonSegment(
              value: _OnlineScriptTypeFilter.raw,
              label: Text('单文件'),
            ),
            ButtonSegment(
              value: _OnlineScriptTypeFilter.repo,
              label: Text('仓库'),
            ),
          ],
          selected: {_typeFilter},
          onSelectionChanged: (selection) =>
              setState(() => _typeFilter = selection.first),
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
        if (_loading && _scripts.isNotEmpty)
          const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          _InlineNotice(
            icon: Icons.cloud_off_outlined,
            text: '读取在线脚本目录失败：$_error',
            action: '重试',
            onPressed: _loadCatalog,
          )
        else if (_catalog?.refreshError != null)
          _InlineNotice(
            icon: Icons.cloud_off_outlined,
            text:
                '目录暂不可用，正在显示缓存（缓存同步于 ${_formatCatalogTime(_catalog!.lastSyncedAt)}，上次成功检查 ${_formatCatalogTime(_catalog!.lastCheckedAt)}）：${_catalog!.refreshError}',
            action: '重试',
            onPressed: _loadCatalog,
          )
        else if (_catalog?.changes case final changes? when changes.hasChanges)
          _InlineNotice(
            icon: Icons.sync,
            text:
                '目录已更新：新增 ${changes.added}，更新 ${changes.updated}，移除 ${changes.removed}',
          )
        else if (_catalog?.lastCheckedAt case final checkedAt?)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text(
              '目录上次检查：${_formatCatalogTime(checkedAt)}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (_loading && _scripts.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null && scripts.isEmpty)
          const SizedBox.shrink()
        else if (scripts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Text(
              _query.isEmpty && _typeFilter == _OnlineScriptTypeFilter.all
                  ? '在线脚本目录为空'
                  : '没有匹配的脚本',
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
                      '${scripts[index].type.toUpperCase()} · ${scripts[index].linkName} · ${_installedLabel(scripts[index])}',
                      maxLines: 2,
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

  String _installedLabel(OnlineScript script) =>
      switch (_installedById[script.id]) {
        true => '已安装',
        false => '未安装',
        null => '状态未知',
      };

  String _formatCatalogTime(DateTime? value) {
    if (value == null) return '未知';
    final local = value.toLocal();
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute';
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
  final _installLogScrollController = ScrollController();
  String _document = '';
  String? _documentError;
  bool _documentLoading = true;
  bool? _installed;
  bool _installing = false;
  bool _checkingUpdate = false;
  OnlineScriptUpdateState? _updateState;
  String _installStatus = '';
  String _installLog = '';
  bool _autoScrollInstallLog = true;
  int _downloadedBytes = 0;
  int? _downloadTotalBytes;
  String? _installError;
  OperationCancellation? _cancellation;

  @override
  void initState() {
    super.initState();
    _loadDocument();
    _loadInstallState();
  }

  Future<void> _loadInstallState() async {
    try {
      final installed = await widget.manager.hasInstallTarget(
        widget.script,
        widget.installManager,
      );
      if (!mounted) return;
      setState(() => _installed = installed);
    } catch (error) {
      if (!mounted) return;
      setState(() => _installError = error.toString());
    }
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    _installLogScrollController.dispose();
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
    if (!widget.runtimeAvailable || _installing || _checkingUpdate) return;
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
      _autoScrollInstallLog = true;
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
          _appendInstallLog(line);
        },
      );
      if (!mounted) return;
      setState(() {
        _installStatus = '安装完成';
        _installed = true;
        _updateState = OnlineScriptUpdateState.upToDate;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('脚本已安装或更新')));
    } catch (error) {
      if (mounted) {
        setState(() {
          if (cancellation.isCancelled) {
            _installStatus = '已取消';
            _installError = null;
          } else {
            _installError = error.toString();
          }
        });
      }
    } finally {
      widget.onBusyChanged(false);
      _cancellation = null;
      if (mounted) setState(() => _installing = false);
    }
  }

  void _appendInstallLog(String line) {
    setState(() {
      final lines = [
        if (_installLog.isNotEmpty) ..._installLog.split('\n'),
        ...line.split('\n'),
      ];
      _installLog = lines.length > 300
          ? lines.skip(lines.length - 300).join('\n')
          : lines.join('\n');
    });
    if (!_autoScrollInstallLog) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_autoScrollInstallLog ||
          !_installLogScrollController.hasClients) {
        return;
      }
      _installLogScrollController.jumpTo(
        _installLogScrollController.position.maxScrollExtent,
      );
    });
  }

  void _toggleInstallLogAutoScroll() {
    setState(() => _autoScrollInstallLog = !_autoScrollInstallLog);
    if (!_autoScrollInstallLog) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _installLogScrollController.hasClients) {
        _installLogScrollController.jumpTo(
          _installLogScrollController.position.maxScrollExtent,
        );
      }
    });
  }

  Future<void> _copyInstallLog() async {
    try {
      await Clipboard.setData(ClipboardData(text: _installLog));
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('安装日志已复制')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('复制安装日志失败')));
    }
  }

  Future<void> _checkForUpdate() async {
    if (_installed != true || _checkingUpdate || _installing) return;
    final cancellation = OperationCancellation();
    _cancellation = cancellation;
    setState(() {
      _checkingUpdate = true;
      _installError = null;
      _installStatus = '准备检查更新';
      _downloadedBytes = 0;
      _downloadTotalBytes = null;
    });
    try {
      final result = await widget.manager.checkForUpdate(
        script: widget.script,
        installManager: widget.installManager,
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
      );
      if (!mounted) return;
      setState(() {
        _updateState = result.state;
        _installStatus = switch (result.state) {
          OnlineScriptUpdateState.notInstalled => '尚未安装',
          OnlineScriptUpdateState.upToDate => '已是最新版本',
          OnlineScriptUpdateState.updateAvailable => '有可用更新',
        };
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _installError = error.toString();
          if (cancellation.isCancelled) _installStatus = '已取消';
        });
      }
    } finally {
      _cancellation = null;
      if (mounted) setState(() => _checkingUpdate = false);
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
                if (_installed == true) ...[
                  OutlinedButton.icon(
                    onPressed: _installing || _checkingUpdate
                        ? null
                        : _checkForUpdate,
                    icon: const Icon(Icons.system_update_alt),
                    label: Text(_checkingUpdate ? _installStatus : '检查更新'),
                  ),
                  const SizedBox(height: 8),
                ],
                FilledButton.icon(
                  onPressed:
                      _installing || _checkingUpdate || !widget.runtimeAvailable
                      ? null
                      : _installOrUpdate,
                  icon: _installing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(
                    _installing
                        ? _installStatus
                        : _installed == true
                        ? '更新脚本'
                        : '安装脚本',
                  ),
                ),
                if (_installed == true) ...[
                  const SizedBox(height: 8),
                  Text(
                    switch (_updateState) {
                      OnlineScriptUpdateState.upToDate => '脚本已是最新版本',
                      OnlineScriptUpdateState.updateAvailable => '发现上游更新',
                      OnlineScriptUpdateState.notInstalled => '本机尚未安装',
                      null => '本机已安装，可检查上游更新',
                    },
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          _updateState ==
                              OnlineScriptUpdateState.updateAvailable
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (!widget.runtimeAvailable) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: widget.onOpenEnvironment,
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: const Text('先安装本机运行环境'),
                  ),
                ],
                if (!_installing &&
                    !_checkingUpdate &&
                    _installStatus == '已取消') ...[
                  const SizedBox(height: 8),
                  Text(
                    _installStatus,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ],
                if (_installing || _checkingUpdate) ...[
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '安装日志',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      IconButton(
                        tooltip: _autoScrollInstallLog ? '暂停自动滚动' : '恢复自动滚动',
                        onPressed: _toggleInstallLogAutoScroll,
                        icon: Icon(
                          _autoScrollInstallLog
                              ? Icons.pause
                              : Icons.play_arrow,
                        ),
                      ),
                      IconButton(
                        tooltip: '复制日志',
                        onPressed: _copyInstallLog,
                        icon: const Icon(Icons.copy),
                      ),
                    ],
                  ),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 260),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: Scrollbar(
                      controller: _installLogScrollController,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _installLogScrollController,
                        child: SelectableText(
                          _installLog,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(fontFamily: 'monospace'),
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
                  NativeMarkdownView(data: _document),
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

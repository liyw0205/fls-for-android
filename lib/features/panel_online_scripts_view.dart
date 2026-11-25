import 'dart:async';

import 'package:flutter/material.dart';

import '../models/panel_online_script.dart';
import '../services/panel_api_client.dart';
import '../services/panel_online_scripts_manager.dart';
import '../widgets/native_markdown_view.dart';
import 'panel_online_script_admin_view.dart';

Future<void> _expireNestedPanelSession(
  BuildContext context,
  Future<void> Function(Object error) onUnauthorized,
  Object error, {
  required int routesToClose,
}) async {
  final navigator = Navigator.of(context);
  await onUnauthorized(error);
  for (var index = 0; index < routesToClose && navigator.canPop(); index++) {
    navigator.pop();
  }
}

class PanelOnlineScriptInstallDraft {
  const PanelOnlineScriptInstallDraft({
    required this.proxyId,
    required this.importTasks,
    required this.enableTasks,
    required this.taskIndexes,
  });

  final String proxyId;
  final bool importTasks;
  final bool enableTasks;
  final List<int> taskIndexes;
}

class PanelOnlineScriptsView extends StatefulWidget {
  const PanelOnlineScriptsView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
    this.onOpenPanelFiles,
  });

  final PanelOnlineScriptsManager manager;
  final Future<void> Function(Object error) onUnauthorized;
  final VoidCallback? onOpenPanelFiles;

  @override
  State<PanelOnlineScriptsView> createState() => PanelOnlineScriptsViewState();
}

class PanelOnlineScriptsViewState extends State<PanelOnlineScriptsView> {
  final _searchController = TextEditingController();
  PanelOnlineScriptPage? _data;
  String _query = '';
  String? _error;
  bool _loading = true;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _request++;
    _searchController.dispose();
    super.dispose();
  }

  Future<void> refresh() => _load(page: _data?.page ?? 1);

  Future<void> _load({int page = 1}) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.manager.fetchCatalog(query: _query, page: page);
      if (!mounted || request != _request) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await widget.onUnauthorized(error);
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openScript(PanelOnlineScript script) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _PanelOnlineScriptDetailView(
          manager: widget.manager,
          scriptId: script.id,
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
  }

  Future<void> _openHistory() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _PanelOnlineInstallHistoryView(
          manager: widget.manager,
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
  }

  Future<void> _openAdmin() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PanelOnlineScriptAdminView(
          manager: widget.manager,
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
    if (mounted) await refresh();
  }

  void _submitSearch(String value) {
    setState(() => _query = value.trim());
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _submitSearch,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: '搜索在线脚本',
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜索',
                            onPressed: () {
                              _searchController.clear();
                              _submitSearch('');
                            },
                            icon: const Icon(Icons.close),
                          ),
                  ),
                ),
              ),
              if (widget.onOpenPanelFiles != null)
                IconButton(
                  tooltip: '面板文件',
                  onPressed: widget.onOpenPanelFiles,
                  icon: const Icon(Icons.folder_open_outlined),
                ),
              IconButton(
                tooltip: '安装历史',
                onPressed: _openHistory,
                icon: const Icon(Icons.history),
              ),
              IconButton(
                tooltip: '脚本源管理',
                onPressed: _openAdmin,
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
        ),
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            actions: [TextButton(onPressed: refresh, child: const Text('重试'))],
          ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(
            onRefresh: refresh,
            child: data == null || data.items.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 72),
                      Icon(
                        data == null || data.total == 0
                            ? Icons.terminal
                            : Icons.search_off,
                        size: 38,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: Text(
                          data == null || data.total == 0
                              ? '暂无在线脚本'
                              : '没有匹配的脚本',
                        ),
                      ),
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    itemCount: data.items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final script = data.items[index];
                      final details = <String>[
                        if (script.type.isNotEmpty) script.type.toUpperCase(),
                        if (script.sourceName.isNotEmpty) script.sourceName,
                        if (script.hasTasks) '${script.taskCount} 个任务',
                      ];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.terminal),
                        title: Text(
                          script.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          [
                            if (script.description.isNotEmpty)
                              script.description,
                            details.join(' · '),
                          ].where((line) => line.isNotEmpty).join('\n'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        isThreeLine: script.description.isNotEmpty,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openScript(script),
                      );
                    },
                  ),
          ),
        ),
        if (data != null && data.pages > 1)
          _PageControls(
            page: data.page,
            pages: data.pages,
            onPage: (page) => _load(page: page),
          ),
      ],
    );
  }
}

class _PanelOnlineScriptDetailView extends StatefulWidget {
  const _PanelOnlineScriptDetailView({
    required this.manager,
    required this.scriptId,
    required this.onUnauthorized,
  });

  final PanelOnlineScriptsManager manager;
  final String scriptId;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<_PanelOnlineScriptDetailView> createState() =>
      _PanelOnlineScriptDetailViewState();
}

class _PanelOnlineScriptDetailViewState
    extends State<_PanelOnlineScriptDetailView> {
  PanelOnlineScript? _script;
  PanelOnlineScriptDocument? _document;
  String? _error;
  String? _documentError;
  bool _loading = true;
  bool _starting = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _request++;
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final script = await widget.manager.fetchDetail(widget.scriptId);
      if (!mounted || request != _request) return;
      setState(() {
        _script = script;
        _loading = false;
        _document = null;
        _documentError = null;
      });
      if (!script.hasDoc) return;
      try {
        final document = await widget.manager.fetchDocument(script.id);
        if (!mounted || request != _request) return;
        setState(() => _document = document);
      } catch (error) {
        if (!mounted || request != _request) return;
        if (error is PanelApiException && error.statusCode == 401) {
          await _expireNestedPanelSession(
            context,
            widget.onUnauthorized,
            error,
            routesToClose: 1,
          );
          return;
        }
        setState(() => _documentError = error.toString());
      }
    } catch (error) {
      if (!mounted || request != _request) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _expireNestedPanelSession(
          context,
          widget.onUnauthorized,
          error,
          routesToClose: 1,
        );
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _install() async {
    final script = _script;
    if (script == null || _starting) return;
    final draft = await Navigator.of(context)
        .push<PanelOnlineScriptInstallDraft>(
          MaterialPageRoute<PanelOnlineScriptInstallDraft>(
            builder: (_) => _PanelOnlineScriptOptionsView(
              manager: widget.manager,
              script: script,
              onUnauthorized: widget.onUnauthorized,
            ),
          ),
        );
    if (draft == null || !mounted) return;
    setState(() => _starting = true);
    final requestId = PanelOnlineScriptsManager.newRequestId();
    try {
      var result = await widget.manager.startInstall(
        scriptId: script.id,
        requestId: requestId,
        proxyId: draft.proxyId,
        importTasks: draft.importTasks,
        enableTasks: draft.enableTasks,
        taskIndexes: draft.taskIndexes,
      );
      if (result['confirm_required'] == true) {
        if (!await _confirmOverwrite() || !mounted) return;
        result = await widget.manager.startInstall(
          scriptId: script.id,
          requestId: requestId,
          proxyId: draft.proxyId,
          importTasks: draft.importTasks,
          enableTasks: draft.enableTasks,
          force: true,
          taskIndexes: draft.taskIndexes,
        );
      }
      final installId = _safeInstallId(
        result['install_id'] ?? result['request_id'],
      );
      if (installId == null) throw const FormatException('安装响应缺少任务标识');
      if (mounted) await _openInstall(installId);
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _expireNestedPanelSession(
          context,
          widget.onUnauthorized,
          error,
          routesToClose: 1,
        );
      } else if (error is PanelApiException &&
          error.data?['confirm_required'] == true) {
        if (await _confirmOverwrite() && mounted) {
          await _startForcedInstall(script, draft, requestId);
        }
      } else if (error is PanelApiException && error.data?['running'] == true) {
        final installId = _safeInstallId(error.data?['install_id']);
        if (installId != null) await _openInstall(installId);
        _showMessage(error.toString());
      } else if (error is PanelApiException &&
          error.data?['accepted'] == true) {
        final installId = _safeInstallId(
          error.data?['install_id'] ?? error.data?['request_id'],
        );
        if (installId != null) await _openInstall(installId);
        _showMessage(error.toString());
      } else {
        _showMessage(error.toString());
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _importTasksOnly() async {
    final script = _script;
    if (script == null || !script.hasTasks || _starting) return;
    final draft = await Navigator.of(context)
        .push<PanelOnlineScriptInstallDraft>(
          MaterialPageRoute<PanelOnlineScriptInstallDraft>(
            builder: (_) => _PanelOnlineScriptOptionsView(
              manager: widget.manager,
              script: script,
              onUnauthorized: widget.onUnauthorized,
              importOnly: true,
            ),
          ),
        );
    if (draft == null || !mounted) return;
    final requestId = PanelOnlineScriptsManager.newRequestId();
    setState(() => _starting = true);
    try {
      final result = await widget.manager.importTasks(
        scriptId: script.id,
        requestId: requestId,
        taskIndexes: draft.taskIndexes,
        enableTasks: draft.enableTasks,
      );
      final operationId = _safeInstallId(result['request_id']) ?? requestId;
      if (mounted) await _openTaskOperation(operationId, taskImport: true);
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _expireNestedPanelSession(
          context,
          widget.onUnauthorized,
          error,
          routesToClose: 2,
        );
      } else if (error is PanelApiException &&
          (error.statusCode == null ||
              error.statusCode! >= 500 ||
              error.data?['accepted'] == true ||
              error.data?['scheduler_reload_required'] == true)) {
        await _openTaskOperation(requestId, taskImport: true);
      } else {
        _showMessage(error.toString());
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _syncTaskSource() async {
    final script = _script;
    if (script == null || !script.hasTaskSource || _starting) return;
    setState(() => _starting = true);
    String? requestId;
    try {
      final options = await widget.manager.fetchRefreshOptions();
      final proxies = (options['proxies'] as List? ?? const [])
          .whereType<Map>()
          .map(PanelOnlineScriptProxy.fromJson)
          .toList(growable: false);
      final proxyId = await _chooseTaskLinkProxy(proxies);
      if (proxyId == null || !mounted) return;
      requestId = PanelOnlineScriptsManager.newRequestId();
      final result = await widget.manager.linkTasks(
        scriptId: script.id,
        requestId: requestId,
        proxyId: proxyId,
      );
      final operationId = _safeInstallId(result['request_id']) ?? requestId;
      if (mounted) await _openTaskOperation(operationId, taskImport: false);
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _expireNestedPanelSession(
          context,
          widget.onUnauthorized,
          error,
          routesToClose: 1,
        );
      } else if (error is PanelApiException &&
          (error.statusCode == null ||
              error.statusCode! >= 500 ||
              error.data?['accepted'] == true ||
              error.data?['receipt_confirmation_required'] == true)) {
        if (requestId != null) {
          await _openTaskOperation(requestId, taskImport: false);
        } else {
          _showMessage(error.toString());
        }
      } else {
        _showMessage(error.toString());
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<String?> _chooseTaskLinkProxy(
    List<PanelOnlineScriptProxy> proxies,
  ) async {
    if (proxies.isEmpty) return '';
    var selected = proxies.first.id;
    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('同步外部任务源'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('从脚本配置的 task_link 拉取任务并合并到任务列表。'),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: selected,
                decoration: const InputDecoration(labelText: '同步代理'),
                items: proxies
                    .map(
                      (proxy) => DropdownMenuItem(
                        value: proxy.id,
                        child: Text(
                          '${proxy.name}${proxy.type.isEmpty ? '' : ' · ${proxy.type}'}',
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) setDialogState(() => selected = value);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: const Text('开始同步'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openTaskOperation(
    String requestId, {
    required bool taskImport,
  }) => Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => _PanelOnlineTaskOperationView(
        manager: widget.manager,
        requestId: requestId,
        taskImport: taskImport,
        onUnauthorized: widget.onUnauthorized,
      ),
    ),
  );

  Future<void> _startForcedInstall(
    PanelOnlineScript script,
    PanelOnlineScriptInstallDraft draft,
    String requestId,
  ) async {
    try {
      final result = await widget.manager.startInstall(
        scriptId: script.id,
        requestId: requestId,
        proxyId: draft.proxyId,
        importTasks: draft.importTasks,
        enableTasks: draft.enableTasks,
        force: true,
        taskIndexes: draft.taskIndexes,
      );
      final installId = _safeInstallId(
        result['install_id'] ?? result['request_id'],
      );
      if (installId != null && mounted) await _openInstall(installId);
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _expireNestedPanelSession(
          context,
          widget.onUnauthorized,
          error,
          routesToClose: 1,
        );
      } else {
        _showMessage(error.toString());
      }
    }
  }

  String? _safeInstallId(Object? value) {
    final id = value?.toString() ?? '';
    return RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ? id : null;
  }

  Future<bool> _confirmOverwrite() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('覆盖已有脚本？'),
          content: const Text('目标文件已存在。继续将由面板脚本安装流程覆盖该文件。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('覆盖安装'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _openInstall(String installId) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _PanelOnlineInstallView(
            manager: widget.manager,
            installId: installId,
            onUnauthorized: widget.onUnauthorized,
          ),
        ),
      );

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final script = _script;
    return Scaffold(
      appBar: AppBar(title: Text(script?.name ?? '在线脚本详情')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, textAlign: TextAlign.center),
                  TextButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : _buildDetails(context, script!),
      bottomNavigationBar: script?.hasInstall == true
          ? SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(
                onPressed: _starting ? null : _install,
                icon: _starting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download),
                label: Text(_starting ? '提交中' : '安装 / 更新'),
              ),
            )
          : null,
    );
  }

  Widget _buildDetails(BuildContext context, PanelOnlineScript script) {
    final document = _document;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Text(script.description, style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _MetadataChip(label: script.type.toUpperCase()),
            if (script.version.isNotEmpty) _MetadataChip(label: script.version),
            if (script.category.isNotEmpty)
              _MetadataChip(label: script.category),
            if (script.author.isNotEmpty) _MetadataChip(label: script.author),
          ],
        ),
        if (script.sourceName.isNotEmpty || script.sourceUrl.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('来源', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          SelectableText(
            [
              script.sourceName,
              script.sourceUrl,
            ].where((value) => value.isNotEmpty).join('\n'),
          ),
        ],
        if (script.tags.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: script.tags
                .map((tag) => _MetadataChip(label: tag))
                .toList(),
          ),
        ],
        if (script.hasTasks) ...[
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Text(
                  '可导入任务：${script.taskCount}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton.icon(
                onPressed: _starting ? null : _importTasksOnly,
                icon: const Icon(Icons.playlist_add),
                label: const Text('单独导入'),
              ),
            ],
          ),
        ],
        if (script.hasTaskSource) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _starting ? null : _syncTaskSource,
              icon: const Icon(Icons.link),
              label: const Text('同步外部任务源'),
            ),
          ),
        ],
        if (script.hasDoc) ...[
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Text(
                  '文档',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: '重新加载文档',
                onPressed: _load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (_documentError != null)
            Text(
              _documentError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (document == null && _documentError == null)
            const LinearProgressIndicator(minHeight: 2)
          else if (document != null)
            _documentBody(document),
        ],
      ],
    );
  }

  Widget _documentBody(PanelOnlineScriptDocument document) {
    switch (document.format) {
      case 'markdown':
        return NativeMarkdownView(data: document.content);
      case 'text':
      case 'html':
        return SelectableText(document.content);
      default:
        return const Text('此文档格式暂不支持原生显示');
    }
  }
}

class _PanelOnlineScriptOptionsView extends StatefulWidget {
  const _PanelOnlineScriptOptionsView({
    required this.manager,
    required this.script,
    required this.onUnauthorized,
    this.importOnly = false,
  });

  final PanelOnlineScriptsManager manager;
  final PanelOnlineScript script;
  final Future<void> Function(Object error) onUnauthorized;
  final bool importOnly;

  @override
  State<_PanelOnlineScriptOptionsView> createState() =>
      _PanelOnlineScriptOptionsViewState();
}

class _PanelOnlineScriptOptionsViewState
    extends State<_PanelOnlineScriptOptionsView> {
  final _queryController = TextEditingController();
  PanelOnlineScriptInstallOptions? _data;
  final Set<int> _selected = {};
  String _query = '';
  String _proxyId = '';
  String? _error;
  bool _loading = true;
  bool _importTasks = false;
  bool _enableTasks = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _importTasks = widget.importOnly;
    unawaited(_load());
  }

  @override
  void dispose() {
    _request++;
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _load({int page = 1}) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.manager.fetchInstallOptions(
        widget.script.id,
        query: _query,
        page: page,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _data = data;
        _loading = false;
        if (_proxyId.isEmpty && data.proxies.isNotEmpty) {
          _proxyId = data.proxies.first.id;
        }
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _expireNestedPanelSession(
          context,
          widget.onUnauthorized,
          error,
          routesToClose: 2,
        );
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  void _submitSearch(String query) {
    setState(() => _query = query.trim());
    unawaited(_load());
  }

  void _submit() {
    final data = _data;
    if (data == null) return;
    final invalidSelected = data.tasks.any(
      (task) => _selected.contains(task.index) && !task.valid,
    );
    if (_importTasks && (_selected.isEmpty || invalidSelected)) return;
    Navigator.of(context).pop(
      PanelOnlineScriptInstallDraft(
        proxyId: _proxyId,
        importTasks: _importTasks,
        enableTasks: _importTasks && _enableTasks,
        taskIndexes: _selected.toList()..sort(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(title: Text(widget.importOnly ? '选择要导入的任务' : '安装选项')),
      body: Column(
        children: [
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [TextButton(onPressed: _load, child: const Text('重试'))],
            ),
          if (data != null && data.proxies.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: DropdownButtonFormField<String>(
                initialValue: data.proxies.any((proxy) => proxy.id == _proxyId)
                    ? _proxyId
                    : data.proxies.first.id,
                decoration: const InputDecoration(labelText: '下载代理'),
                items: data.proxies
                    .map(
                      (proxy) => DropdownMenuItem(
                        value: proxy.id,
                        child: Text(
                          '${proxy.name}${proxy.type.isEmpty ? '' : ' · ${proxy.type}'}',
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _proxyId = value ?? ''),
              ),
            ),
          if (!widget.importOnly)
            SwitchListTile(
              value: _importTasks,
              onChanged: widget.script.hasTasks
                  ? (value) => setState(() {
                      _importTasks = value;
                      if (!value) _enableTasks = false;
                    })
                  : null,
              title: const Text('导入附带任务'),
            ),
          SwitchListTile(
            value: _enableTasks,
            onChanged: _importTasks
                ? (value) => setState(() => _enableTasks = value)
                : null,
            title: const Text('导入后启用任务'),
          ),
          if (_importTasks)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: TextField(
                controller: _queryController,
                textInputAction: TextInputAction.search,
                onSubmitted: _submitSearch,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: '筛选任务',
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除搜索',
                          onPressed: () {
                            _queryController.clear();
                            _submitSearch('');
                          },
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
            ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: !_importTasks
                ? const Center(child: Text('默认不导入任何任务'))
                : data == null || data.tasks.isEmpty
                ? Center(child: Text(data == null ? '正在读取任务选项' : '没有可选任务'))
                : ListView.builder(
                    itemCount: data.tasks.length,
                    itemBuilder: (context, index) {
                      final task = data.tasks[index];
                      return CheckboxListTile(
                        value: _selected.contains(task.index),
                        onChanged: task.valid
                            ? (checked) => setState(() {
                                if (checked == true) {
                                  _selected.add(task.index);
                                } else {
                                  _selected.remove(task.index);
                                }
                              })
                            : null,
                        title: Text(task.name),
                        subtitle: Text(
                          [
                            if (task.cron.isNotEmpty) task.cron,
                            if (task.command.isNotEmpty) task.command,
                            if (task.variableNames.isNotEmpty)
                              '变量：${task.variableNames.join(', ')}',
                            if (!task.valid) task.validationError,
                          ].join('\n'),
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                      );
                    },
                  ),
          ),
          if (_importTasks && data != null && data.pages > 1)
            _PageControls(
              page: data.page,
              pages: data.pages,
              onPage: (page) => _load(page: page),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton(
          onPressed:
              _loading ||
                  (_importTasks &&
                      (_selected.isEmpty ||
                          (data?.tasks.any(
                                (task) =>
                                    _selected.contains(task.index) &&
                                    !task.valid,
                              ) ??
                              false)))
              ? null
              : _submit,
          child: Text(
            _importTasks ? '继续 · 已选 ${_selected.length} 个任务' : '继续安装',
          ),
        ),
      ),
    );
  }
}

class _PanelOnlineInstallView extends StatefulWidget {
  const _PanelOnlineInstallView({
    required this.manager,
    required this.installId,
    required this.onUnauthorized,
  });

  final PanelOnlineScriptsManager manager;
  final String installId;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<_PanelOnlineInstallView> createState() =>
      _PanelOnlineInstallViewState();
}

class _PanelOnlineInstallViewState extends State<_PanelOnlineInstallView> {
  late String _installId;
  PanelOnlineInstallState? _state;
  String _log = '';
  String? _error;
  Timer? _timer;
  int _pollCount = 0;
  bool _actionBusy = false;
  bool _reading = true;

  @override
  void initState() {
    super.initState();
    _installId = widget.installId;
    unawaited(_poll(readLog: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll({bool readLog = false}) async {
    _timer?.cancel();
    try {
      final state = await widget.manager.fetchInstallState(_installId);
      if (!mounted) return;
      var log = _log;
      if (readLog || ++_pollCount % 3 == 0 || !state.running) {
        try {
          log = await widget.manager.fetchInstallLog(_installId);
        } catch (error) {
          if (error is PanelApiException && error.statusCode == 401) rethrow;
        }
      }
      if (!mounted) return;
      setState(() {
        _state = state;
        _log = log;
        _error = null;
        _reading = false;
      });
      if (state.running) {
        _timer = Timer(const Duration(seconds: 2), () => _poll());
      }
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _expireNestedPanelSession(
          context,
          widget.onUnauthorized,
          error,
          routesToClose: 2,
        );
        return;
      }
      setState(() {
        _error = error.toString();
        _reading = false;
      });
      _timer = Timer(const Duration(seconds: 5), () => _poll(readLog: true));
    }
  }

  Future<void> _perform(String action) async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      Map<String, dynamic> result;
      switch (action) {
        case 'stop':
          result = await widget.manager.stopInstall(_installId);
        case 'retry_start':
          result = await widget.manager.retryInstallStart(_installId);
        case 'confirm_tasks':
          result = await widget.manager.confirmImportedTasks(_installId);
        case 'retry_tasks':
          result = await widget.manager.retryImportedTasks(_installId);
        case 'reload_scheduler':
          result = await widget.manager.reloadScheduler(_installId);
        case 'retry':
          try {
            result = await widget.manager.retryInstall(_installId);
          } on PanelApiException catch (error) {
            if (error.data?['confirm_required'] != true) rethrow;
            if (!await _confirmRetryOverwrite() || !mounted) return;
            result = await widget.manager.retryInstall(_installId, force: true);
          }
        default:
          return;
      }
      final nextId = _safeInstallId(
        result['install_id'] ?? result['request_id'],
      );
      if (nextId != null) _installId = nextId;
      await _poll(readLog: true);
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _expireNestedPanelSession(
          context,
          widget.onUnauthorized,
          error,
          routesToClose: 2,
        );
      } else {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  String? _safeInstallId(Object? value) {
    final id = value?.toString() ?? '';
    return RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ? id : null;
  }

  Future<bool> _confirmRetryOverwrite() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('覆盖已有脚本？'),
          content: const Text('重试将覆盖已存在的脚本文件。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('覆盖并重试'),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final progressKnown = state?.percent != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('脚本安装'),
        actions: [
          IconButton(
            tooltip: '刷新状态',
            onPressed: _reading ? null : () => _poll(readLog: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [TextButton(onPressed: _poll, child: const Text('重试'))],
            ),
          if (_reading && state == null) const LinearProgressIndicator(),
          Text(
            state?.status ?? '读取安装状态',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (state != null) ...[
            const SizedBox(height: 4),
            Text('阶段：${state.phase} · ${state.running ? '运行中' : '已停止'}'),
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: progressKnown ? state.percent! / 100 : null,
              minHeight: 5,
            ),
            const SizedBox(height: 8),
            Text(_progressLabel(state)),
            if (state.error.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                PanelOnlineScriptsManager.sanitizeDiagnostic(state.error),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (state.running)
                  FilledButton.tonalIcon(
                    onPressed: _actionBusy ? null : () => _perform('stop'),
                    icon: const Icon(Icons.stop),
                    label: const Text('停止'),
                  ),
                if (state.startRetryAvailable)
                  OutlinedButton.icon(
                    onPressed: _actionBusy
                        ? null
                        : () => _perform('retry_start'),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('恢复启动'),
                  ),
                if (state.confirmTasksAvailable)
                  OutlinedButton.icon(
                    onPressed: _actionBusy
                        ? null
                        : () => _perform('confirm_tasks'),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('确认任务导入'),
                  ),
                if (state.retryTasksAvailable)
                  OutlinedButton.icon(
                    onPressed: _actionBusy
                        ? null
                        : () => _perform('retry_tasks'),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('恢复任务导入'),
                  ),
                if (state.reloadSchedulerAvailable ||
                    state.schedulerReloadPending)
                  OutlinedButton.icon(
                    onPressed: _actionBusy
                        ? null
                        : () => _perform('reload_scheduler'),
                    icon: const Icon(Icons.sync),
                    label: const Text('重新加载调度器'),
                  ),
                if (state.retryAvailable)
                  OutlinedButton.icon(
                    onPressed: _actionBusy ? null : () => _perform('retry'),
                    icon: const Icon(Icons.replay),
                    label: const Text('重试安装'),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Text('安装日志', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(minHeight: 140, maxHeight: 420),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                _log.isEmpty ? '暂无日志' : _log,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _progressLabel(PanelOnlineInstallState state) {
    if (state.downloadKind == 'git') {
      return 'Git 操作进行中，进度不可预估';
    }
    final downloaded = state.downloadedBytes;
    final total = state.totalBytes;
    if (downloaded == null) {
      return state.downloadState == 'pending' ? '等待下载开始' : '下载进度暂不可用';
    }
    if (state.percent != null && total != null) {
      return '${_formatBytes(downloaded)} / ${_formatBytes(total)} · ${state.percent}%';
    }
    if (state.phase == 'downloading' || state.phase == 'fetching') {
      return '已接收 ${_formatBytes(downloaded)} · 总量未知';
    }
    return '已接收 ${_formatBytes(downloaded)}';
  }
}

class _PanelOnlineTaskOperationView extends StatefulWidget {
  const _PanelOnlineTaskOperationView({
    required this.manager,
    required this.requestId,
    required this.taskImport,
    required this.onUnauthorized,
  });

  final PanelOnlineScriptsManager manager;
  final String requestId;
  final bool taskImport;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<_PanelOnlineTaskOperationView> createState() =>
      _PanelOnlineTaskOperationViewState();
}

class _PanelOnlineTaskOperationViewState
    extends State<_PanelOnlineTaskOperationView> {
  Timer? _timer;
  Map<String, dynamic>? _state;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    _timer?.cancel();
    try {
      final state = widget.taskImport
          ? await widget.manager.fetchTaskImportState(widget.requestId)
          : await widget.manager.fetchTaskLinkState(widget.requestId);
      if (!mounted) return;
      setState(() {
        _state = state;
        _error = null;
      });
      if (state['active'] == true || state['state'] == 'running') {
        _timer = Timer(const Duration(seconds: 2), _poll);
      }
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await widget.onUnauthorized(error);
        if (mounted) Navigator.of(context).pop();
        return;
      }
      setState(() => _error = error.toString());
      _timer = Timer(const Duration(seconds: 5), _poll);
    }
  }

  Future<void> _perform(String action) async {
    if (_busy) return;
    final state = _state;
    if (state == null) return;
    setState(() => _busy = true);
    try {
      switch (action) {
        case 'confirm':
          if (widget.taskImport) {
            await widget.manager.confirmTaskImport(widget.requestId);
          } else {
            await widget.manager.confirmTaskLink(widget.requestId);
          }
          break;
        case 'reload':
          await widget.manager.reloadTaskImportScheduler(widget.requestId);
          break;
        case 'retry_import':
          final indexes = (state['selected_task_indexes'] as List? ?? const [])
              .map((value) => int.tryParse(value.toString()))
              .whereType<int>()
              .toList();
          await widget.manager.importTasks(
            scriptId: state['script_id']?.toString() ?? '',
            requestId: widget.requestId,
            taskIndexes: indexes,
            enableTasks: state['enable_task'] == true,
          );
          break;
        case 'retry_link':
          await widget.manager.linkTasks(
            scriptId: state['script_id']?.toString() ?? '',
            requestId: widget.requestId,
            proxyId: state['proxy_id']?.toString() ?? '',
            refreshRequestId:
                state['origin_refresh_request_id']?.toString() ?? '',
          );
          break;
      }
      await _poll();
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await widget.onUnauthorized(error);
        if (mounted) Navigator.of(context).pop();
      } else {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final status = state?['state']?.toString() ?? '读取中';
    final rawMessage =
        state?['message']?.toString() ??
        state?['msg']?.toString() ??
        state?['error']?.toString();
    final message = rawMessage == null
        ? null
        : PanelOnlineScriptsManager.sanitizeDiagnostic(rawMessage);
    final schedulerError = PanelOnlineScriptsManager.sanitizeDiagnostic(
      state?['scheduler_reload_error']?.toString() ?? '',
    );
    final canConfirm =
        state?['receipt_confirmation_required'] == true || status == 'unknown';
    final canReload =
        widget.taskImport &&
        (state?['scheduler_reload_required'] == true ||
            status == 'scheduler_pending');
    final canRetry = state?['retry_allowed'] == true;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.taskImport ? '任务导入状态' : '外部任务同步状态'),
        actions: [
          IconButton(
            tooltip: '刷新状态',
            onPressed: _poll,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [TextButton(onPressed: _poll, child: const Text('重试'))],
            ),
          Text(status, style: Theme.of(context).textTheme.titleLarge),
          if (message != null && message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(message),
          ],
          if (schedulerError.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              schedulerError,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          SelectableText(
            '请求：${widget.requestId}',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          if (state != null) ...[
            const SizedBox(height: 8),
            Text('脚本：${state['script_name'] ?? state['script_id'] ?? '-'}'),
            if (widget.taskImport && state['selected_task_indexes'] is List)
              Text(
                '任务序号：${(state['selected_task_indexes'] as List).join(', ')}',
              ),
            if (!widget.taskImport && state['added'] != null)
              Text('新增任务：${state['added']} / ${state['total'] ?? '-'}'),
            if (state['updated_at'] != null)
              Text('更新时间：${state['updated_at']}'),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (canConfirm)
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _perform('confirm'),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('核对原请求'),
                ),
              if (canReload)
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : () => _perform('reload'),
                  icon: const Icon(Icons.sync),
                  label: const Text('重新加载调度器'),
                ),
              if (canRetry)
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _perform(
                          widget.taskImport ? 'retry_import' : 'retry_link',
                        ),
                  icon: const Icon(Icons.replay),
                  label: const Text('继续原请求'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PanelOnlineInstallHistoryView extends StatefulWidget {
  const _PanelOnlineInstallHistoryView({
    required this.manager,
    required this.onUnauthorized,
  });

  final PanelOnlineScriptsManager manager;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<_PanelOnlineInstallHistoryView> createState() =>
      _PanelOnlineInstallHistoryViewState();
}

class _PanelOnlineInstallHistoryViewState
    extends State<_PanelOnlineInstallHistoryView> {
  PanelOnlineInstallHistoryPage? _data;
  String? _snapshot;
  String? _error;
  bool _loading = true;
  int _offset = 0;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _request++;
    super.dispose();
  }

  Future<void> _load({bool reset = false, int? offset}) async {
    final request = ++_request;
    final targetOffset = reset ? 0 : offset ?? _offset;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.manager.fetchInstallHistory(
        limit: 30,
        offset: targetOffset,
        snapshot: reset ? null : _snapshot,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _data = data;
        _snapshot = data.snapshot;
        _offset = data.offset;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _expireNestedPanelSession(
          context,
          widget.onUnauthorized,
          error,
          routesToClose: 1,
        );
        return;
      }
      if (error is PanelApiException && error.statusCode == 409 && !reset) {
        setState(() {
          _snapshot = null;
          _offset = 0;
        });
        await _load(reset: true);
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _open(PanelOnlineInstallHistoryItem item) async {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(item.installId)) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _PanelOnlineInstallView(
          manager: widget.manager,
          installId: item.installId,
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(title: const Text('安装历史')),
      body: Column(
        children: [
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [TextButton(onPressed: _load, child: const Text('重试'))],
            ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: data == null || data.items.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 80),
                      Center(child: Text('暂无安装记录')),
                    ],
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: data.items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = data.items[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          item.running ? Icons.downloading : Icons.history,
                        ),
                        title: Text(
                          item.scriptName.isEmpty
                              ? item.scriptId
                              : item.scriptName,
                        ),
                        subtitle: Text('${item.status} · ${item.startedAt}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(item),
                      );
                    },
                  ),
          ),
          if (data != null && (data.offset > 0 || data.hasMore))
            SafeArea(
              top: false,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: '上一页',
                    onPressed: _loading || data.offset == 0
                        ? null
                        : () => _load(
                            offset: (data.offset - data.limit).clamp(
                              0,
                              data.total,
                            ),
                          ),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text(
                    '${data.total == 0 ? 0 : data.offset + 1}-${data.offset + data.items.length} / ${data.total}',
                  ),
                  IconButton(
                    tooltip: '下一页',
                    onPressed: _loading || !data.hasMore
                        ? null
                        : () => _load(offset: data.offset + data.limit),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PageControls extends StatelessWidget {
  const _PageControls({
    required this.page,
    required this.pages,
    required this.onPage,
  });

  final int page;
  final int pages;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: '上一页',
          onPressed: page > 1 ? () => onPage(page - 1) : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Text('$page / $pages'),
        IconButton(
          tooltip: '下一页',
          onPressed: page < pages ? () => onPage(page + 1) : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    ),
  );
}

class _MetadataChip extends StatelessWidget {
  const _MetadataChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Chip(
    label: Text(label),
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

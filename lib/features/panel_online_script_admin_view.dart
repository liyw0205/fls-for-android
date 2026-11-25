import 'dart:async';

import 'package:flutter/material.dart';

import '../services/panel_api_client.dart';
import '../services/panel_online_scripts_manager.dart';

class PanelOnlineScriptAdminView extends StatelessWidget {
  const PanelOnlineScriptAdminView({
    super.key,
    required this.manager,
    required this.onUnauthorized,
    this.initialTabIndex = 0,
  });

  final PanelOnlineScriptsManager manager;
  final Future<void> Function(Object error) onUnauthorized;
  final int initialTabIndex;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    initialIndex: initialTabIndex,
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('脚本源管理'),
        bottom: const TabBar(
          tabs: [
            Tab(text: '源同步', icon: Icon(Icons.sync)),
            Tab(text: '源 JSON', icon: Icon(Icons.data_object)),
            Tab(text: '任务记录', icon: Icon(Icons.playlist_add_check)),
          ],
        ),
      ),
      body: TabBarView(
        children: [
          _RefreshTab(manager: manager, onUnauthorized: onUnauthorized),
          _SourceEditorTab(manager: manager, onUnauthorized: onUnauthorized),
          _TaskHistoryTab(manager: manager, onUnauthorized: onUnauthorized),
        ],
      ),
    ),
  );
}

class _RefreshTab extends StatefulWidget {
  const _RefreshTab({required this.manager, required this.onUnauthorized});

  final PanelOnlineScriptsManager manager;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<_RefreshTab> createState() => _RefreshTabState();
}

class _RefreshTabState extends State<_RefreshTab> {
  List<Map<String, dynamic>> _proxies = const [];
  List<Map<String, dynamic>> _history = const [];
  String _proxyId = '';
  String? _error;
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final values = await Future.wait([
        widget.manager.fetchRefreshOptions(),
        widget.manager.fetchRefreshHistory(limit: 10),
      ]);
      final proxyPayload = values[0];
      final historyPayload = values[1];
      if (!mounted) return;
      setState(() {
        _proxies = _maps(proxyPayload['proxies']);
        _history = _maps(historyPayload['items']);
        if (!_proxies.any((item) => item['id'] == _proxyId)) {
          _proxyId = _proxies.isEmpty ? '' : '${_proxies.first['id'] ?? ''}';
        }
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _expire(error, routesToClose: 1);
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _start() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final requestId = PanelOnlineScriptsManager.newRequestId();
    try {
      final result = await widget.manager.startRefresh(
        requestId: requestId,
        proxyId: _proxyId,
      );
      final acceptedId = result['request_id']?.toString() ?? requestId;
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _RefreshJobView(
            manager: widget.manager,
            requestId: acceptedId,
            onUnauthorized: widget.onUnauthorized,
          ),
        ),
      );
      if (mounted) await _load();
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await _expire(error, routesToClose: 1);
      } else if (error is PanelApiException &&
          (error.statusCode == null ||
              error.statusCode! >= 500 ||
              error.data?['accepted'] == true ||
              error.data?['replayed'] == true)) {
        final existingId = error.data?['request_id']?.toString() ?? requestId;
        if (_validRequestId(existingId)) {
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => _RefreshJobView(
                manager: widget.manager,
                requestId: existingId,
                onUnauthorized: widget.onUnauthorized,
              ),
            ),
          );
          if (mounted) await _load();
        } else {
          setState(() => _error = error.toString());
        }
      } else {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _open(Map<String, dynamic> item) async {
    final requestId = item['request_id']?.toString() ?? '';
    if (!_validRequestId(requestId)) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _RefreshJobView(
          manager: widget.manager,
          requestId: requestId,
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _expire(Object error, {required int routesToClose}) async {
    final navigator = Navigator.of(context);
    await widget.onUnauthorized(error);
    for (var index = 0; index < routesToClose && navigator.canPop(); index++) {
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (_error != null)
        MaterialBanner(
          content: Text(_error!),
          actions: [TextButton(onPressed: _load, child: const Text('重试'))],
        ),
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_proxies.isNotEmpty)
              DropdownButtonFormField<String>(
                initialValue: _proxyId,
                decoration: const InputDecoration(labelText: '刷新代理'),
                items: _proxies
                    .map(
                      (proxy) => DropdownMenuItem(
                        value: '${proxy['id'] ?? ''}',
                        child: Text(
                          '${proxy['name'] ?? '未命名代理'}${proxy['type'] == null || proxy['type'] == '' ? '' : ' · ${proxy['type']}'}',
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _proxyId = value ?? ''),
              )
            else
              const Text('未配置启用的代理，将使用直连。'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _loading || _submitting ? null : _start,
              icon: _submitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              label: Text(_submitting ? '正在提交' : '同步脚本源'),
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '最近同步',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: '刷新历史',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
      Expanded(
        child: _history.isEmpty
            ? const Center(child: Text('暂无同步记录'))
            : ListView.separated(
                itemCount: _history.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final item = _history[index];
                  final status = item['status']?.toString() ?? '未知';
                  final running = item['running'] == true;
                  return ListTile(
                    leading: Icon(
                      running ? Icons.sync : Icons.history,
                      color: running
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    title: Text(status),
                    subtitle: Text(
                      [
                        item['updated_at']?.toString() ?? '',
                        PanelOnlineScriptsManager.sanitizeDiagnostic(
                          item['error']?.toString() ?? '',
                        ),
                      ].where((value) => value.isNotEmpty).join('\n'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(item),
                  );
                },
              ),
      ),
    ],
  );

  List<Map<String, dynamic>> _maps(Object? value) => value is List
      ? value.whereType<Map>().map(Map<String, dynamic>.from).toList()
      : const [];
}

class _RefreshJobView extends StatefulWidget {
  const _RefreshJobView({
    required this.manager,
    required this.requestId,
    required this.onUnauthorized,
  });

  final PanelOnlineScriptsManager manager;
  final String requestId;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<_RefreshJobView> createState() => _RefreshJobViewState();
}

class _RefreshJobViewState extends State<_RefreshJobView> {
  Timer? _timer;
  Map<String, dynamic>? _state;
  String _log = '';
  String? _error;
  bool _busy = false;
  bool _receiptMissing = false;

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
      final state = await widget.manager.fetchRefreshState(widget.requestId);
      String log = _log;
      try {
        log = await widget.manager.fetchRefreshLog(widget.requestId);
      } on PanelApiException catch (error) {
        if (error.statusCode == 401) rethrow;
      }
      if (!mounted) return;
      setState(() {
        _state = state;
        _log = log;
        _error = null;
        _receiptMissing = false;
      });
      if (state['running'] == true) {
        _timer = Timer(const Duration(seconds: 2), _poll);
      }
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await widget.onUnauthorized(error);
        if (mounted) Navigator.of(context).pop();
        return;
      }
      setState(() {
        _error = error.toString();
        _receiptMissing = error is PanelApiException && error.statusCode == 404;
      });
      _timer = Timer(const Duration(seconds: 5), _poll);
    }
  }

  Future<void> _action(String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      switch (action) {
        case 'recover':
          await widget.manager.recoverRefresh(widget.requestId);
          break;
        case 'confirm':
          await widget.manager.confirmRefresh(widget.requestId);
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

  Future<void> _retryRefresh() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重试脚本源同步？'),
        content: const Text('将使用服务端原请求绑定的源和缓存状态重试；已完成、已变化或结果未确认的请求会被拒绝。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('明确重试'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final retryId = PanelOnlineScriptsManager.newRequestId();
    try {
      final result = await widget.manager.retryRefresh(
        requestId: widget.requestId,
        retryRequestId: retryId,
        proxyId: _state?['proxy_id']?.toString() ?? '',
      );
      final acceptedId = result['request_id']?.toString() ?? retryId;
      if (!mounted || !_validRequestId(acceptedId)) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _RefreshJobView(
            manager: widget.manager,
            requestId: acceptedId,
            onUnauthorized: widget.onUnauthorized,
          ),
        ),
      );
      if (mounted) await _poll();
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

  Future<void> _retryTaskFailure(Map failure) async {
    if (_busy) return;
    final scriptId = failure['script_id']?.toString() ?? '';
    final requestId = failure['task_link_request_id']?.toString() ?? '';
    final originId = _state?['request_id']?.toString() ?? widget.requestId;
    if (scriptId.isEmpty ||
        !_validRequestId(requestId) ||
        !_validRequestId(originId)) {
      setState(() => _error = '失败项缺少有效的恢复标识，请从同步历史重新读取。');
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await widget.manager.linkTasks(
        scriptId: scriptId,
        requestId: requestId,
        proxyId: failure['proxy_id']?.toString() ?? '',
        refreshRequestId: originId,
      );
      final acceptedId = result['request_id']?.toString() ?? requestId;
      if (!mounted || !_validRequestId(acceptedId)) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _TaskHistoryOperationView(
            manager: widget.manager,
            requestId: acceptedId,
            taskImport: false,
            onUnauthorized: widget.onUnauthorized,
          ),
        ),
      );
      if (mounted) await _poll();
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
    final failures = state?['task_link_failures'];
    return Scaffold(
      appBar: AppBar(
        title: const Text('脚本源同步状态'),
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
          Text(
            state?['status']?.toString() ?? '正在读取状态',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (state?['message'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                PanelOnlineScriptsManager.sanitizeDiagnostic(
                  state!['message'].toString(),
                ),
              ),
            ),
          if (state?['error'] != null && state!['error'].toString().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                PanelOnlineScriptsManager.sanitizeDiagnostic(
                  state['error'].toString(),
                ),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          SelectableText(
            '请求：${widget.requestId}',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_receiptMissing || state?['receipt_missing'] == true)
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _action('recover'),
                  icon: const Icon(Icons.healing),
                  label: const Text('修复回执'),
                ),
              if (state?['status'] == '结果未知' || state?['status'] == 'unknown')
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _action('confirm'),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('核对结果'),
                ),
              if (state?['running'] != true &&
                  const {'失败', '启动失败'}.contains(state?['status']))
                OutlinedButton.icon(
                  onPressed: _busy ? null : _retryRefresh,
                  icon: const Icon(Icons.replay),
                  label: const Text('重试同步'),
                ),
            ],
          ),
          if (failures is List && failures.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('外部任务源失败', style: Theme.of(context).textTheme.titleMedium),
            for (final failure in failures.whereType<Map>())
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.warning_amber),
                title: Text(failure['name']?.toString() ?? '脚本'),
                subtitle: const Text('外部任务源同步失败，可用原请求安全重试。'),
                trailing: IconButton(
                  tooltip: '重试此任务源',
                  onPressed: _busy ? null : () => _retryTaskFailure(failure),
                  icon: const Icon(Icons.sync),
                ),
              ),
          ],
          const SizedBox(height: 20),
          Text('同步日志', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText(_log.isEmpty ? '暂无日志' : _log),
        ],
      ),
    );
  }
}

class _SourceEditorTab extends StatefulWidget {
  const _SourceEditorTab({required this.manager, required this.onUnauthorized});

  final PanelOnlineScriptsManager manager;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<_SourceEditorTab> createState() => _SourceEditorTabState();
}

class _SourceEditorTabState extends State<_SourceEditorTab> {
  final _controller = TextEditingController();
  String _revision = '';
  String? _conflictRevision;
  String? _currentText;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load({bool replaceDraft = true}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final payload = await widget.manager.fetchSourceCache();
      if (!mounted) return;
      final current = payload['json_text']?.toString() ?? '[]';
      setState(() {
        final revision = payload['cache_revision']?.toString() ?? '';
        if (replaceDraft) {
          _revision = revision;
          _conflictRevision = null;
        } else {
          _conflictRevision = revision;
        }
        _currentText = current;
        if (replaceDraft) _controller.text = current;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await widget.onUnauthorized(error);
        if (mounted) Navigator.of(context).pop();
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_saving || _revision.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final payload = await widget.manager.saveSourceCache(
        jsonText: _controller.text,
        cacheRevision: _revision,
      );
      if (!mounted) return;
      setState(() {
        _revision = payload['cache_revision']?.toString() ?? '';
        _conflictRevision = null;
        _controller.text = payload['json_text']?.toString() ?? _controller.text;
        _currentText = _controller.text;
        _error = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存 ${payload['count'] ?? 0} 条脚本源')),
      );
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await widget.onUnauthorized(error);
        if (mounted) Navigator.of(context).pop();
      } else if (error is PanelApiException && error.statusCode == 409) {
        await _load(replaceDraft: false);
        if (mounted) {
          setState(() => _error = '缓存已被其他操作修改。当前草稿保留；可查看新版本后决定是否替换。');
        }
      } else {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _showCurrent() async {
    final current = _currentText;
    if (current == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('服务器当前缓存'),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: SingleChildScrollView(child: SelectableText(current)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () {
              _adoptCurrent();
              Navigator.pop(context);
            },
            child: const Text('使用服务器版本'),
          ),
        ],
      ),
    );
  }

  void _adoptCurrent() {
    final current = _currentText;
    if (current == null) return;
    setState(() {
      _controller.text = current;
      _revision = _conflictRevision ?? _revision;
      _conflictRevision = null;
      _error = null;
    });
  }

  Future<void> _reloadSafely() async {
    if (_controller.text != _currentText) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('丢弃未保存草稿？'),
          content: const Text('重新读取会用服务器缓存替换当前编辑内容。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('丢弃并重载'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    await _load();
  }

  void _continueWithDraft() {
    final latestRevision = _conflictRevision;
    if (latestRevision == null) return;
    setState(() {
      _revision = latestRevision;
      _conflictRevision = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (_error != null)
        MaterialBanner(
          content: Text(_error!),
          actions: [
            if (_conflictRevision != null)
              TextButton(onPressed: _showCurrent, child: const Text('查看当前')),
            if (_currentText != null && _controller.text != _currentText)
              TextButton(
                onPressed: _adoptCurrent,
                child: const Text('使用服务器版本'),
              ),
            if (_currentText != null && _controller.text != _currentText)
              TextButton(
                onPressed: _continueWithDraft,
                child: const Text('保留草稿并继续'),
              ),
            TextButton(
              onPressed: () =>
                  _load(replaceDraft: _conflictRevision == null ? true : false),
              child: const Text('重新读取'),
            ),
          ],
        ),
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _controller,
            enabled: !_loading && !_saving,
            expands: true,
            minLines: null,
            maxLines: null,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              labelText: '在线脚本源 JSON',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ),
      SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _loading || _saving ? null : _reloadSafely,
                icon: const Icon(Icons.refresh),
                label: const Text('重载'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed:
                    _loading ||
                        _saving ||
                        _conflictRevision != null ||
                        _revision.isEmpty
                    ? null
                    : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: Text(_saving ? '保存中' : '保存'),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

bool _validRequestId(String value) => RegExp(r'^[a-f0-9]{32}$').hasMatch(value);

class _TaskHistoryTab extends StatefulWidget {
  const _TaskHistoryTab({required this.manager, required this.onUnauthorized});

  final PanelOnlineScriptsManager manager;
  final Future<void> Function(Object error) onUnauthorized;

  @override
  State<_TaskHistoryTab> createState() => _TaskHistoryTabState();
}

class _TaskHistoryTabState extends State<_TaskHistoryTab> {
  String _kind = 'import';
  List<Map<String, dynamic>> _items = const [];
  String? _error;
  bool _loading = true;
  bool _hasMore = false;
  int _offset = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool append = false}) async {
    final offset = append ? _offset + 20 : 0;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final payload = _kind == 'import'
          ? await widget.manager.fetchTaskImportHistory(
              limit: 20,
              offset: offset,
            )
          : await widget.manager.fetchTaskLinkHistory(
              limit: 20,
              offset: offset,
            );
      if (!mounted) return;
      final records = payload['items'];
      setState(() {
        final pageItems = records is List
            ? records.whereType<Map>().map(Map<String, dynamic>.from).toList()
            : <Map<String, dynamic>>[];
        _items = append ? [..._items, ...pageItems] : pageItems;
        _offset = offset;
        _hasMore = payload['has_more'] == true;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await widget.onUnauthorized(error);
        if (mounted) Navigator.of(context).pop();
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _open(Map<String, dynamic> item) async {
    final requestId = item['request_id']?.toString() ?? '';
    if (!_validRequestId(requestId)) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _TaskHistoryOperationView(
          manager: widget.manager,
          requestId: requestId,
          taskImport: _kind == 'import',
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          children: [
            Expanded(
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'import', label: Text('任务导入')),
                  ButtonSegment(value: 'link', label: Text('外部任务同步')),
                ],
                selected: {_kind},
                onSelectionChanged: (selected) {
                  setState(() {
                    _kind = selected.first;
                    _items = const [];
                    _offset = 0;
                    _hasMore = false;
                  });
                  unawaited(_load());
                },
              ),
            ),
            IconButton(
              tooltip: '刷新记录',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
      if (_error != null)
        MaterialBanner(
          content: Text(_error!),
          actions: [TextButton(onPressed: _load, child: const Text('重试'))],
        ),
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      Expanded(
        child: _items.isEmpty
            ? const Center(child: Text('暂无任务操作记录'))
            : ListView.separated(
                itemCount: _items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final item = _items[index];
                  return ListTile(
                    leading: Icon(
                      item['active'] == true || item['retry_allowed'] == true
                          ? Icons.pending_actions
                          : Icons.check_circle_outline,
                    ),
                    title: Text(
                      item['script_name']?.toString() ??
                          item['script_id']?.toString() ??
                          '脚本任务',
                    ),
                    subtitle: Text(
                      '${item['state'] ?? '未知'} · ${item['updated_at'] ?? ''}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(item),
                  );
                },
              ),
      ),
      if (_hasMore)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextButton.icon(
            onPressed: _loading ? null : () => _load(append: true),
            icon: const Icon(Icons.expand_more),
            label: const Text('加载更多记录'),
          ),
        ),
    ],
  );
}

class _TaskHistoryOperationView extends StatefulWidget {
  const _TaskHistoryOperationView({
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
  State<_TaskHistoryOperationView> createState() =>
      _TaskHistoryOperationViewState();
}

class _TaskHistoryOperationViewState extends State<_TaskHistoryOperationView> {
  Timer? _timer;
  Map<String, dynamic>? _record;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    _timer?.cancel();
    try {
      final record = widget.taskImport
          ? await widget.manager.fetchTaskImportState(widget.requestId)
          : await widget.manager.fetchTaskLinkState(widget.requestId);
      if (!mounted) return;
      setState(() {
        _record = record;
        _error = null;
      });
      if (record['active'] == true || record['state'] == 'running') {
        _timer = Timer(const Duration(seconds: 2), _load);
      }
    } catch (error) {
      if (!mounted) return;
      if (error is PanelApiException && error.statusCode == 401) {
        await widget.onUnauthorized(error);
        if (mounted) Navigator.of(context).pop();
        return;
      }
      setState(() => _error = error.toString());
      _timer = Timer(const Duration(seconds: 5), _load);
    }
  }

  Future<void> _action(String action) async {
    final record = _record;
    if (record == null || _busy) return;
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
        case 'retry':
          if (widget.taskImport) {
            final indexes =
                (record['selected_task_indexes'] as List? ?? const [])
                    .map((value) => int.tryParse(value.toString()))
                    .whereType<int>()
                    .toList();
            await widget.manager.importTasks(
              scriptId: record['script_id']?.toString() ?? '',
              requestId: widget.requestId,
              taskIndexes: indexes,
              enableTasks: record['enable_task'] == true,
            );
          } else {
            await widget.manager.linkTasks(
              scriptId: record['script_id']?.toString() ?? '',
              requestId: widget.requestId,
              proxyId: record['proxy_id']?.toString() ?? '',
              refreshRequestId:
                  record['origin_refresh_request_id']?.toString() ?? '',
            );
          }
          break;
        case 'archive':
          if (widget.taskImport) {
            await widget.manager.archiveTaskImport(widget.requestId);
          } else {
            await widget.manager.archiveTaskLink(widget.requestId);
          }
          break;
      }
      await _load();
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
    final record = _record;
    final status = record?['state']?.toString() ?? '读取中';
    final canConfirm =
        record?['receipt_confirmation_required'] == true || status == 'unknown';
    final canReload =
        widget.taskImport &&
        (record?['scheduler_reload_required'] == true ||
            status == 'scheduler_pending');
    final canRetry = record?['retry_allowed'] == true;
    final canArchive =
        record?['active'] != true &&
        record?['archived'] != true &&
        (widget.taskImport
            ? const {'failed', 'unknown', 'scheduler_pending'}.contains(status)
            : const {'failed', 'unknown'}.contains(status));
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.taskImport ? '任务导入记录' : '外部任务同步记录'),
        actions: [
          IconButton(
            tooltip: '刷新状态',
            onPressed: _load,
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
              actions: [TextButton(onPressed: _load, child: const Text('重试'))],
            ),
          Text(status, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (record?['message'] != null || record?['error'] != null)
            Text(
              PanelOnlineScriptsManager.sanitizeDiagnostic(
                (record!['message'] ?? record['error']).toString(),
              ),
            ),
          SelectableText(
            '请求：${widget.requestId}',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          if (record != null) ...[
            Text('脚本：${record['script_name'] ?? record['script_id'] ?? '-'}'),
            if (record['updated_at'] != null)
              Text('更新于 ${record['updated_at']}'),
            if (record['selected_task_indexes'] is List)
              Text(
                '任务序号：${(record['selected_task_indexes'] as List).join(', ')}',
              ),
            if (!widget.taskImport && record['added'] != null)
              Text('新增任务：${record['added']} / ${record['total'] ?? '-'}'),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (canConfirm)
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _action('confirm'),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('核对原请求'),
                ),
              if (canReload)
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : () => _action('reload'),
                  icon: const Icon(Icons.sync),
                  label: const Text('重新加载调度器'),
                ),
              if (canRetry)
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _action('retry'),
                  icon: const Icon(Icons.replay),
                  label: const Text('继续原请求'),
                ),
              if (canArchive)
                TextButton.icon(
                  onPressed: _busy ? null : () => _confirmArchive(),
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('归档记录'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmArchive() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('归档此请求？'),
        content: const Text('只归档这条失败或未知请求记录，不会修改任务或脚本缓存。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('归档记录'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _action('archive');
  }
}

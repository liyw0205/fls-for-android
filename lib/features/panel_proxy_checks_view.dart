import 'dart:async';

import 'package:flutter/material.dart';

import '../models/panel_proxy.dart';
import '../models/panel_proxy_check.dart';
import '../services/panel_api_client.dart';
import '../services/panel_proxy_manager.dart';

class ProxyCheckOptions {
  const ProxyCheckOptions(this.kind, this.targets);
  final String kind;
  final List<String>? targets;
}

Future<ProxyCheckOptions?> proxyCheckOptions(
  BuildContext context, {
  bool customTargets = true,
}) async {
  final targets = TextEditingController();
  var kind = 'test';
  String? error;
  try {
    return await showDialog<ProxyCheckOptions>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('代理检测'),
          scrollable: true,
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('检测网络：当前 FLS 面板'),
                const SizedBox(height: 16),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'test',
                      icon: Icon(Icons.network_check),
                      label: Text('连接'),
                    ),
                    ButtonSegment(
                      value: 'quality',
                      icon: Icon(Icons.speed),
                      label: Text('质量'),
                    ),
                  ],
                  selected: {kind},
                  onSelectionChanged: (value) => setState(() {
                    kind = value.single;
                    error = null;
                  }),
                ),
                if (customTargets) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: targets,
                    maxLength: 5120,
                    minLines: 2,
                    maxLines: 5,
                    decoration: InputDecoration(
                      labelText: '检测目标（可选）',
                      hintText: 'https://www.baidu.com',
                      errorText: error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final urls = targets.text
                    .split(RegExp(r'\s+'))
                    .where((value) => value.isNotEmpty)
                    .toList();
                if (urls.isNotEmpty &&
                    (urls.length > (kind == 'test' ? 1 : 5) ||
                        urls.toSet().length != urls.length ||
                        urls.any((value) {
                          final uri = Uri.tryParse(value);
                          return value.length > 1024 ||
                              uri == null ||
                              !const ['http', 'https'].contains(uri.scheme) ||
                              uri.host.isEmpty ||
                              uri.userInfo.isNotEmpty ||
                              uri.hasQuery ||
                              uri.hasFragment ||
                              value.contains('\\');
                        }))) {
                  setState(
                    () => error = kind == 'test'
                        ? '填写一个无凭据或查询串的 HTTP/HTTPS 地址'
                        : '最多五个不同的 HTTP/HTTPS 地址，每行一个',
                  );
                  return;
                }
                Navigator.pop(
                  context,
                  ProxyCheckOptions(kind, urls.isEmpty ? null : urls),
                );
              },
              child: const Text('开始检测'),
            ),
          ],
        ),
      ),
    );
  } finally {
    // Route disposal follows the closing animation.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    targets.dispose();
  }
}

class PanelProxyChecksView extends StatefulWidget {
  const PanelProxyChecksView({
    super.key,
    required this.manager,
    required this.recovery,
    required this.onUnauthorized,
    this.proxyId = '',
  });
  final PanelProxyManager manager;
  final PanelProxyRecovery recovery;
  final Future<void> Function(PanelApiException) onUnauthorized;
  final String proxyId;
  @override
  State<PanelProxyChecksView> createState() => _PanelProxyChecksViewState();
}

class _PanelProxyChecksViewState extends State<PanelProxyChecksView> {
  PanelProxyCheckPage? _page;
  String _status = '', _kind = '';
  String? _error;
  bool _loading = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load([int page = 1]) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await widget.manager.checkHistory(
        page: page,
        proxyId: widget.proxyId,
        status: _status,
        kind: _kind,
      );
      if (mounted && generation == _generation) setState(() => _page = value);
    } on PanelApiException catch (error) {
      if (!mounted || generation != _generation) return;
      if (error.statusCode == 401) {
        await widget.onUnauthorized(error);
        return;
      }
      setState(() => _error = error.message);
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = '检测历史读取失败');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open(String id) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PanelProxyCheckView(
          manager: widget.manager,
          recovery: widget.recovery,
          id: id,
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
    if (mounted) _load(_page?.page ?? 1);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('代理检测历史'),
      actions: [
        IconButton(
          tooltip: '刷新检测历史',
          onPressed: _loading ? null : () => _load(_page?.page ?? 1),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        DropdownButtonFormField<String>(
          initialValue: _kind,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '检测类型'),
          items: const [
            DropdownMenuItem(value: '', child: Text('全部检测')),
            DropdownMenuItem(value: 'test', child: Text('连接检测')),
            DropdownMenuItem(value: 'quality', child: Text('质量检测')),
          ],
          onChanged: _loading
              ? null
              : (value) {
                  setState(() => _kind = value!);
                  _load();
                },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _status,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '检测状态'),
          items: [
            const DropdownMenuItem(value: '', child: Text('全部状态')),
            for (final state in proxyCheckStates)
              DropdownMenuItem(
                value: state,
                child: Text(proxyCheckStateLabel(state)),
              ),
          ],
          onChanged: _loading
              ? null
              : (value) {
                  setState(() => _status = value!);
                  _load();
                },
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: SelectableText(_error!),
          ),
        for (final id in widget.recovery.checkIds)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.restore),
            title: const Text('查询未确认检测'),
            subtitle: Text(id),
            onTap: () => _open(id),
          ),
        if (_page != null && _page!.items.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Text('暂无检测记录')),
        for (final check in _page?.items ?? <PanelProxyCheck>[]) ...[
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              check.kind == 'test' ? Icons.network_check : Icons.speed,
            ),
            title: Text(check.proxyName.isEmpty ? '未命名代理' : check.proxyName),
            subtitle: Text(
              '${proxyCheckStateLabel(check.status)} · ${check.completed}/${check.total}\n${check.createdAt}${check.source == 'draft' ? '\n未保存草稿' : ''}${check.source == 'legacy' ? '\n旧版记录' : ''}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(check.id),
          ),
        ],
        if (_page != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '上一页',
                onPressed: _loading || _page!.page <= 1
                    ? null
                    : () => _load(_page!.page - 1),
                icon: const Icon(Icons.chevron_left),
              ),
              Flexible(
                child: Text(
                  '${_page!.page} / ${_page!.pages} · ${_page!.total} 条',
                ),
              ),
              IconButton(
                tooltip: '下一页',
                onPressed: _loading || _page!.page >= _page!.pages
                    ? null
                    : () => _load(_page!.page + 1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
      ],
    ),
  );
}

class PanelProxyCheckView extends StatefulWidget {
  const PanelProxyCheckView({
    super.key,
    required this.manager,
    required this.recovery,
    required this.id,
    required this.onUnauthorized,
    this.submission,
    this.retryOf,
  });
  final PanelProxyManager manager;
  final PanelProxyRecovery recovery;
  final String id;
  final Future<void> Function(PanelApiException) onUnauthorized;
  // Consumed once; credential-bearing submissions are cleared after sending.
  final Map<String, Object?>? submission;
  final String? retryOf;
  @override
  State<PanelProxyCheckView> createState() => _PanelProxyCheckViewState();
}

class _PanelProxyCheckViewState extends State<PanelProxyCheckView>
    with WidgetsBindingObserver {
  Timer? _timer;
  PanelProxyCheck? _check;
  String? _error;
  bool _busy = false, _foreground = true, _closed = false, _rejected = false;
  int _polls = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.submission != null) {
      _start();
    } else {
      _read();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    widget.submission?.clear();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _timer?.cancel();
    if (_foreground && !_busy) {
      _polls = 0;
      _read();
    }
  }

  void _accept(PanelProxyCheck check) {
    _check = check;
    widget.recovery.checkIds.remove(widget.id);
  }

  Future<void> _handle(PanelApiException error) async {
    if (!mounted || _closed) return;
    if (error.statusCode == 401) {
      widget.submission?.clear();
      _timer?.cancel();
      _closed = true;
      await widget.onUnauthorized(error);
      return;
    }
    setState(
      () => _error = error.statusCode == 404
          ? '检测记录未找到，执行情况尚未确认，请勿重复提交'
          : error.message,
    );
  }

  Future<void> _start() async {
    widget.recovery.checkIds.add(widget.id);
    setState(() => _busy = true);
    try {
      final check = widget.retryOf == null
          ? await widget.manager.startCheck(widget.submission!)
          : await widget.manager.retryCheck(
              widget.retryOf!,
              requestId: widget.id,
              version: widget.submission!['version'] as String,
            );
      if (mounted && !_closed) setState(() => _accept(check));
    } on PanelApiException catch (error) {
      if (error.data?['accepted'] == false) {
        widget.recovery.checkIds.remove(widget.id);
        _rejected = true;
      }
      await _handle(error);
    } catch (_) {
      if (mounted && !_closed) setState(() => _error = '检测受理结果未知，请查询原检测');
    } finally {
      widget.submission?.clear();
      if (mounted && !_closed) {
        setState(() => _busy = false);
        _schedule();
      }
    }
  }

  Future<void> _read() async {
    if (_busy || _closed) return;
    _timer?.cancel();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final check = await widget.manager.check(widget.id);
      if (mounted && !_closed) setState(() => _accept(check));
    } on PanelApiException catch (error) {
      await _handle(error);
    } catch (_) {
      if (mounted && !_closed) setState(() => _error = '检测状态读取失败');
    } finally {
      if (mounted && !_closed) {
        setState(() => _busy = false);
        _schedule();
      }
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (_foreground &&
        !_closed &&
        _error == null &&
        (_check?.active ?? false) &&
        _polls++ < 90) {
      _timer = Timer(const Duration(seconds: 2), _read);
    }
  }

  Future<void> _retry() async {
    final check = _check;
    if (check == null ||
        !check.retryAllowed ||
        _busy ||
        widget.recovery.checkIds.isNotEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final current = await widget.manager.fetch(check.proxyId);
      if (!mounted || _closed) return;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重新检测当前代理？'),
          scrollable: true,
          content: Text(
            '${current.name}\n${current.address}\n${current.version == check.version ? '配置与原检测一致' : '配置与原检测不同，将检测当前配置'}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: current.enabled
                  ? () => Navigator.pop(context, true)
                  : null,
              child: Text(current.enabled ? '重新检测' : '代理已停用'),
            ),
          ],
        ),
      );
      if (confirm != true || !mounted || _closed) return;
      final id = PanelProxyManager.newRequestId();
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => PanelProxyCheckView(
            manager: widget.manager,
            recovery: widget.recovery,
            id: id,
            onUnauthorized: widget.onUnauthorized,
            retryOf: check.id,
            submission: {'request_id': id, 'version': current.version},
          ),
        ),
      );
    } on PanelApiException catch (error) {
      await _handle(error);
    } catch (_) {
      if (mounted && !_closed) setState(() => _error = '当前代理读取失败');
    } finally {
      if (mounted && !_closed) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final check = _check;
    return Scaffold(
      appBar: AppBar(
        title: const Text('代理检测结果'),
        actions: [
          IconButton(
            tooltip: '查询原检测',
            onPressed: _busy
                ? null
                : () {
                    _polls = 0;
                    _read();
                  },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) ...[
            SelectableText(_error!),
            if (!_rejected)
              TextButton.icon(
                onPressed: _busy ? null : _read,
                icon: const Icon(Icons.restore),
                label: const Text('查询原检测'),
              ),
          ],
          if (check == null) SelectableText('检测 ID：${widget.id}'),
          if (check != null) ...[
            Text(
              check.proxyName,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              '${check.kind == 'test' ? '连接检测' : '质量检测'} · ${proxyCheckStateLabel(check.status)}',
            ),
            const Text('检测网络：当前 FLS 面板'),
            if (check.source == 'draft') const Text('未保存草稿'),
            if (check.source == 'legacy') const Text('旧版检测记录'),
            if (check.proxyId.isNotEmpty && !check.proxyExists)
              const Text('代理已删除'),
            if (check.proxyExists && !check.currentMatches)
              const Text('当前代理配置与本次检测不同'),
            if (check.createdAt.isNotEmpty) Text('开始：${check.createdAt}'),
            if (check.updatedAt.isNotEmpty) Text('更新：${check.updatedAt}'),
            if (check.retryOf.isNotEmpty)
              SelectableText('原检测：${check.retryOf}'),
            const SizedBox(height: 12),
            Text('已完成 ${check.completed} / ${check.total}'),
            if (check.total > 0)
              LinearProgressIndicator(value: check.completed / check.total),
            if (check.errorCode.isNotEmpty)
              Text(proxyCheckErrorLabel(check.errorCode)),
            for (final item in check.items) ...[
              const Divider(height: 24),
              Text(switch (item.mode) {
                'github_git' => 'Git 仓库',
                'github_raw' => 'GitHub 文件',
                'github_ping' => '代理服务',
                _ => 'HTTP 目标',
              }, style: Theme.of(context).textTheme.titleSmall),
              SelectableText(item.target),
              Text(switch (item.status) {
                'pending' => '等待',
                'running' => '检测中',
                'succeeded' => '检测完成',
                'failed' => '检测失败',
                _ => '结果未知',
              }),
              if (item.reachable != null)
                Text(item.reachable! ? '网络可达' : '网络不可达'),
              if (item.statusCode != null)
                Text(
                  'HTTP ${item.statusCode} · ${item.httpSuccess == true ? '目标响应成功' : '目标返回非成功状态'}',
                ),
              if (item.elapsedMs != null) Text('${item.elapsedMs} ms'),
              if (item.errorCode.isNotEmpty)
                Text(proxyCheckErrorLabel(item.errorCode)),
            ],
            if (check.retryAllowed)
              OutlinedButton.icon(
                onPressed: _busy || widget.recovery.checkIds.isNotEmpty
                    ? null
                    : _retry,
                icon: const Icon(Icons.replay),
                label: const Text('重新检测当前代理'),
              ),
          ],
        ],
      ),
    );
  }
}

class PanelProxyBatchCheckView extends StatefulWidget {
  const PanelProxyBatchCheckView({
    super.key,
    required this.manager,
    required this.proxies,
    required this.options,
    required this.recovery,
    required this.onUnauthorized,
  });
  final PanelProxyManager manager;
  final List<PanelProxy> proxies;
  final ProxyCheckOptions options;
  final PanelProxyRecovery recovery;
  final Future<void> Function(PanelApiException) onUnauthorized;
  @override
  State<PanelProxyBatchCheckView> createState() =>
      _PanelProxyBatchCheckViewState();
}

class _PanelProxyBatchCheckViewState extends State<PanelProxyBatchCheckView>
    with WidgetsBindingObserver {
  final Map<String, String> _ids = {}, _errors = {};
  final Map<String, PanelProxyCheck> _results = {};
  final Set<String> _rejected = {};
  bool _closed = false, _foreground = true, _polling = false;
  Timer? _timer;
  int _polls = 0;
  int _accepted = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _timer?.cancel();
    if (_foreground) {
      _polls = 0;
      _poll();
    }
  }

  Future<void> _start() async {
    // Submit in order; the server bounds concurrent probes and queued work.
    for (final proxy in widget.proxies) {
      if (_closed) break;
      final id = PanelProxyManager.newRequestId();
      _ids[proxy.id] = id;
      widget.recovery.checkIds.add(id);
      try {
        final check = await widget.manager.startCheck({
          'request_id': id,
          'proxy_id': proxy.id,
          'version': proxy.version,
          'kind': widget.options.kind,
          if (proxy.type != 'github' && widget.options.targets != null)
            'targets': widget.options.targets,
        });
        widget.recovery.checkIds.remove(id);
        if (mounted) {
          setState(() {
            _results[proxy.id] = check;
            _accepted++;
          });
        }
      } on PanelApiException catch (error) {
        if (error.data?['accepted'] == false) {
          widget.recovery.checkIds.remove(id);
          _rejected.add(proxy.id);
        }
        if (error.statusCode == 401) {
          if (!mounted || _closed) break;
          _closed = true;
          await widget.onUnauthorized(error);
          break;
        }
        if (mounted) {
          setState(() {
            _errors[proxy.id] = error.message;
            _accepted++;
          });
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            _errors[proxy.id] = '受理结果未知';
            _accepted++;
          });
        }
      }
    }
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (!_closed &&
        _foreground &&
        _polls++ < 90 &&
        _results.values.any((check) => check.active)) {
      _timer = Timer(const Duration(seconds: 2), _poll);
    }
  }

  Future<void> _poll() async {
    if (_closed || _polling) return;
    _timer?.cancel();
    _polling = true;
    try {
      for (final entry in _ids.entries.toList()) {
        if (_closed || !_foreground) break;
        if (_rejected.contains(entry.key) ||
            _results[entry.key]?.active == false) {
          continue;
        }
        try {
          final check = await widget.manager.check(entry.value);
          widget.recovery.checkIds.remove(entry.value);
          if (mounted) {
            setState(() {
              _results[entry.key] = check;
              _errors.remove(entry.key);
            });
          }
        } on PanelApiException catch (error) {
          if (error.statusCode == 401) {
            if (!mounted || _closed) return;
            _closed = true;
            await widget.onUnauthorized(error);
            return;
          }
          if (mounted) setState(() => _errors[entry.key] = error.message);
        } catch (_) {
          if (mounted) setState(() => _errors[entry.key] = '检测状态读取失败');
        }
      }
    } finally {
      _polling = false;
      _schedule();
    }
  }

  Future<void> _open(PanelProxy proxy) async {
    final id = _ids[proxy.id];
    if (id == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PanelProxyCheckView(
          manager: widget.manager,
          recovery: widget.recovery,
          id: id,
          onUnauthorized: widget.onUnauthorized,
        ),
      ),
    );
    if (!mounted) return;
    try {
      final check = await widget.manager.check(id);
      if (mounted) {
        setState(() {
          _results[proxy.id] = check;
          _errors.remove(proxy.id);
        });
      }
    } on PanelApiException catch (error) {
      if (error.statusCode == 401) {
        if (!mounted || _closed) return;
        await widget.onUnauthorized(error);
        return;
      }
      if (mounted) setState(() => _errors[proxy.id] = error.message);
    } catch (_) {
      if (mounted) setState(() => _errors[proxy.id] = '检测状态读取失败');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('批量代理检测'),
      actions: [
        IconButton(
          tooltip: '刷新批量检测',
          onPressed: () {
            _polls = 0;
            _poll();
          },
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('已处理 $_accepted / ${widget.proxies.length}'),
        LinearProgressIndicator(value: _accepted / widget.proxies.length),
        for (final proxy in widget.proxies)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(proxy.name),
            subtitle: Text(
              _errors[proxy.id] ??
                  (_results[proxy.id] == null
                      ? '等待提交'
                      : '${proxyCheckStateLabel(_results[proxy.id]!.status)} · ${_results[proxy.id]!.completed}/${_results[proxy.id]!.total}'),
            ),
            trailing: _ids[proxy.id] == null || _rejected.contains(proxy.id)
                ? null
                : const Icon(Icons.chevron_right),
            onTap: _ids[proxy.id] == null || _rejected.contains(proxy.id)
                ? null
                : () => _open(proxy),
          ),
      ],
    ),
  );
}

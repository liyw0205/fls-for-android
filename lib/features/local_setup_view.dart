import 'package:flutter/material.dart';

import '../services/local_install_manager.dart';
import '../services/local_panel_host.dart';
import 'remote_web_view.dart';
import '../models/panel_server.dart';

class LocalSetupView extends StatefulWidget {
  const LocalSetupView({super.key});

  @override
  State<LocalSetupView> createState() => _LocalSetupViewState();
}

class _LocalSetupViewState extends State<LocalSetupView> {
  final _manager = LocalInstallManager();
  bool _loading = true;
  bool _installing = false;
  bool _installed = false;
  bool _panelReady = false;
  double _progress = 0;
  String _phase = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final results = await Future.wait([
      _manager.hasRuntime(),
      _manager.hasProject(),
      LocalPanelHost.isRunning(),
    ]);
    if (!mounted) return;
    setState(() {
      _installed = results[0] && results[1];
      _panelReady = results[2];
      _loading = false;
    });
  }

  Future<void> _installOrUpdate() async {
    setState(() {
      _installing = true;
      _error = null;
      _progress = 0;
      _phase = '检查设备运行时';
    });
    try {
      if (!await _manager.hasRuntime()) {
        final abis = await LocalPanelHost.supportedAbis();
        setState(() => _phase = '下载并校验 Python 容器');
        await _manager.installRuntime(
          supportedAbis: abis,
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
        );
      }
      if (_panelReady) await LocalPanelHost.stop();
      setState(() {
        _phase = '同步 FLS 面板';
        _progress = 0;
      });
      await _manager.updatePanel(
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      setState(() => _phase = '启动本机面板');
      await _manager.startPanel();
      await _refreshStatus();
      if (mounted && _panelReady) _openLocalPanel();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _togglePanel() async {
    try {
      if (_panelReady) {
        await LocalPanelHost.stop();
      } else {
        await _manager.startPanel();
        _openLocalPanel();
      }
      await _refreshStatus();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  void _openLocalPanel() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const RemoteWebView(
          server: PanelServer(name: '本机 FLS', url: 'http://127.0.0.1:5700'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return CustomScrollView(
      slivers: [
        const SliverAppBar(pinned: true, title: Text('本机面板')),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE7F3ED),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.phone_android,
                          color: Color(0xFF147D72),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'FLS 本机实例',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _loading
                                  ? '正在检查安装状态'
                                  : _panelReady
                                  ? '运行中 · 127.0.0.1:5700'
                                  : _installed
                                  ? '已安装 · 当前停止'
                                  : '尚未安装',
                              style: TextStyle(
                                color: _panelReady
                                    ? const Color(0xFF147D72)
                                    : colorScheme.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_loading)
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Icon(
                          _panelReady
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: _panelReady
                              ? const Color(0xFF147D72)
                              : colorScheme.outline,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_installing) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _phase,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: _progress == 0 ? null : _progress,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (_error != null) ...[
                Material(
                  color: const Color(0xFFFFF0EC),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: Color(0xFFB54732),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text(_error!)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (_installed)
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _installing ? null : _togglePanel,
                        icon: Icon(_panelReady ? Icons.stop : Icons.play_arrow),
                        label: Text(_panelReady ? '停止面板' : '启动面板'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _installing ? null : _installOrUpdate,
                        icon: const Icon(Icons.system_update_alt),
                        label: const Text('更新面板'),
                      ),
                    ),
                  ],
                )
              else
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _installing || _loading
                        ? null
                        : _installOrUpdate,
                    icon: const Icon(Icons.download),
                    label: const Text('安装本机 FLS'),
                  ),
                ),
              const SizedBox(height: 20),
              Text('本机存储', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: const [
                    _StorageRow(label: '容器与 Python', path: 'fls/runtime'),
                    Divider(height: 1, indent: 14, endIndent: 14),
                    _StorageRow(label: 'FLS 面板程序', path: 'fls/project'),
                    Divider(height: 1, indent: 14, endIndent: 14),
                    _StorageRow(
                      label: '任务、日志和脚本',
                      path: 'fls/data · fls/log · fls/scripts',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ]),
          ),
        ),
      ],
    );
  }
}

class _StorageRow extends StatelessWidget {
  const _StorageRow({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              path,
              textAlign: TextAlign.end,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

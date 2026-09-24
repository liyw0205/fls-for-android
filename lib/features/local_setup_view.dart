import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/local_install_manager.dart';
import '../services/local_file_bridge.dart';
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
  bool _runtimeInstalled = false;
  bool _panelReady = false;
  RuntimeProfile _selectedProfile = RuntimeProfile.python;
  RuntimeProfile? _installedProfile;
  double _progress = 0;
  String _phase = '';
  String? _error;
  final _mirrorController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _mirrorController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final values = await Future.wait([
      _manager.installedRuntimeProfile(),
      _manager.hasProject(),
      LocalPanelHost.isRunning(),
      _manager.loadGithubMirror(),
    ]);
    if (!mounted) return;
    final profile = values[0] as RuntimeProfile?;
    _mirrorController.text = values[3] as String;
    setState(() {
      _installedProfile = profile;
      _selectedProfile = profile ?? RuntimeProfile.python;
      _runtimeInstalled = profile != null;
      _installed = profile != null && values[1] as bool;
      _panelReady = values[2] as bool;
      _loading = false;
    });
  }

  Future<void> _refreshStatus() async {
    final values = await Future.wait([
      _manager.installedRuntimeProfile(),
      _manager.hasProject(),
      LocalPanelHost.isRunning(),
    ]);
    if (!mounted) return;
    final profile = values[0] as RuntimeProfile?;
    setState(() {
      _installedProfile = profile;
      _runtimeInstalled = profile != null;
      _installed = profile != null && values[1] as bool;
      _panelReady = values[2] as bool;
    });
  }

  void _selectProfile(RuntimeProfile profile) {
    setState(() => _selectedProfile = profile);
    unawaited(_manager.saveGithubMirror(_mirrorController.text));
  }

  Future<File> _temporaryArchive(String name) async {
    final root = await _manager.root;
    await root.create(recursive: true);
    return File(
      p.join(
        root.path,
        '.$name-${DateTime.now().millisecondsSinceEpoch}.tar.gz',
      ),
    );
  }

  Future<void> _installOrUpdate() async {
    setState(() {
      _installing = true;
      _error = null;
      _progress = 0;
      _phase = '检查设备运行时';
    });
    final shouldOpen = _panelReady;
    try {
      await _manager.saveGithubMirror(_mirrorController.text);
      if (_panelReady) await LocalPanelHost.stop();
      if (!await _manager.hasRuntime(profile: _selectedProfile)) {
        final abis = await LocalPanelHost.supportedAbis();
        setState(() => _phase = '下载并校验 ${_selectedProfile.label} 容器');
        await _manager.installRuntime(
          supportedAbis: abis,
          profile: _selectedProfile,
          githubMirror: _mirrorController.text,
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
        );
      }
      setState(() {
        _phase = '同步 FLS 面板';
        _progress = 0;
      });
      await _manager.updatePanel(
        githubMirror: _mirrorController.text,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      setState(() => _phase = '启动本机面板');
      await _manager.startPanel();
      await _refreshStatus();
      if (mounted && shouldOpen) _openLocalPanel();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _importContainer() async {
    if (_installing) return;
    setState(() {
      _installing = true;
      _error = null;
      _phase = '选择容器文件';
      _progress = 0;
    });
    File? archive;
    try {
      final uri = await LocalFileBridge.pickContainer();
      if (uri == null) return;
      archive = await _temporaryArchive('fls-import');
      setState(() => _phase = '导入并校验容器');
      final copied = await LocalFileBridge.copyUriToPath(
        uri: uri,
        path: archive.path,
      );
      if (!copied) throw StateError('无法读取所选容器文件');
      if (_panelReady) await LocalPanelHost.stop();
      final profile = await _manager.importRuntime(
        archive,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      _selectedProfile = profile;
      await _refreshStatus();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (archive != null && await archive.exists()) await archive.delete();
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _exportContainer() async {
    if (_installing || !_runtimeInstalled) return;
    setState(() {
      _installing = true;
      _error = null;
      _phase = '准备导出容器';
      _progress = 0;
    });
    File? archive;
    try {
      archive = await _manager.exportRuntime();
      final profile = _installedProfile ?? RuntimeProfile.python;
      final saved = await LocalFileBridge.saveFile(
        path: archive.path,
        filename: 'fls-container-${profile.id}-arm64.tar.gz',
      );
      if (!saved) throw StateError('未选择导出位置');
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (archive != null && await archive.exists()) await archive.delete();
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
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.asset(
                            'assets/fls_panel_icon.png',
                            fit: BoxFit.cover,
                          ),
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
                                  : _runtimeInstalled
                                  ? '${_installedProfile?.label ?? 'Python'} 容器已安装 · 尚未同步面板'
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
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '容器版本',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      SegmentedButton<RuntimeProfile>(
                        expandedInsets: EdgeInsets.zero,
                        segments: [
                          ButtonSegment(
                            value: RuntimeProfile.python,
                            label: const Text('Python'),
                            icon: const Icon(Icons.code),
                          ),
                          ButtonSegment(
                            value: RuntimeProfile.all,
                            label: const Text('Full'),
                            icon: const Icon(Icons.layers_outlined),
                          ),
                        ],
                        selected: {_selectedProfile},
                        onSelectionChanged: _installing
                            ? null
                            : (selection) {
                                if (selection.isNotEmpty) {
                                  _selectProfile(selection.first);
                                }
                              },
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _selectedProfile == RuntimeProfile.python
                            ? '仅包含 Python 运行环境，占用空间较小。'
                            : '包含 Linux 常用运行环境，适合运行更多脚本。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _mirrorController,
                        enabled: !_installing,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'GitHub 加速源（可选）',
                          hintText: '留空使用 GitHub 官方地址',
                          prefixIcon: Icon(Icons.bolt_outlined),
                        ),
                        onChanged: (value) {
                          unawaited(_manager.saveGithubMirror(value));
                        },
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _installing ? null : _importContainer,
                              icon: const Icon(Icons.file_open_outlined),
                              label: const Text('导入容器'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _installing || !_runtimeInstalled
                                  ? null
                                  : _exportContainer,
                              icon: const Icon(Icons.ios_share_outlined),
                              label: const Text('导出容器'),
                            ),
                          ),
                        ],
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
                    label: Text(_runtimeInstalled ? '同步并启动本机 FLS' : '安装本机 FLS'),
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

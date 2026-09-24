import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fls_for_android/services/directory_replacement.dart';

void main() {
  test('replaces a read-only directory without following symlinks', () async {
    final root = await Directory.systemTemp.createTemp('fls-replace-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    final target = Directory(p.join(root.path, 'runtime'));
    final oldFiles = Directory(p.join(target.path, 'rootfs', 'readonly'));
    final outside = Directory(p.join(root.path, 'outside'));
    final outsideFile = File(p.join(outside.path, 'keep'));
    await oldFiles.create(recursive: true);
    await outside.create();
    await File(p.join(oldFiles.path, 'old')).writeAsString('old');
    await outsideFile.writeAsString('outside');
    final outsideMode = (await outsideFile.stat()).mode & 0x1ff;
    await Link(p.join(target.path, 'root-link')).create(outside.path);

    final chmod = Platform.isAndroid ? '/system/bin/chmod' : 'chmod';
    final readOnly = await Process.run(chmod, ['-R', 'a-w', target.path]);
    expect(readOnly.exitCode, 0);

    final staged = Directory(p.join(root.path, 'runtime-staging'));
    await staged.create();
    await File(p.join(staged.path, 'new')).writeAsString('new');
    await replaceDirectoryWithBackup(staged, target);

    expect(await File(p.join(target.path, 'new')).readAsString(), 'new');
    expect(await Directory('${target.path}.previous').exists(), isFalse);
    expect(await outside.exists(), isTrue);
    expect((await outsideFile.stat()).mode & 0x1ff, outsideMode);
  });
}

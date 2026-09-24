import 'dart:io';

import 'package:flutter/foundation.dart';

Future<void> replaceDirectoryWithBackup(
  Directory staged,
  Directory target,
) async {
  final backup = Directory('${target.path}.previous');
  await _deleteDirectoryTree(backup);
  if (await target.exists()) await target.rename(backup.path);

  try {
    await staged.rename(target.path);
  } catch (_) {
    if (!await target.exists() && await backup.exists()) {
      await backup.rename(target.path);
    }
    rethrow;
  }

  try {
    await _deleteDirectoryTree(backup);
  } catch (error) {
    debugPrint('Old panel data retained at ${backup.path}: $error');
  }
}

Future<void> _deleteDirectoryTree(Directory directory) async {
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type == FileSystemEntityType.link) {
    await Link(directory.path).delete();
    return;
  }
  if (type != FileSystemEntityType.directory) {
    await File(directory.path).delete();
    return;
  }

  final chmod = Platform.isAndroid ? '/system/bin/chmod' : 'chmod';
  final permissions = await Process.run(chmod, ['-R', 'u+rwX', directory.path]);
  if (permissions.exitCode != 0) {
    throw StateError('无法准备删除旧目录：${permissions.stderr}');
  }
  await directory.delete(recursive: true);
}

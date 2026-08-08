import 'package:dual_volume_compressor_android/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('输入项可以从原生映射恢复', () {
    final item = InputItem.fromMap({
      'path': '/tmp/demo.txt',
      'name': 'demo.txt',
      'isDirectory': false,
      'size': 128,
    });
    expect(item.name, 'demo.txt');
    expect(item.size, 128);
    expect(item.isDirectory, isFalse);
  });

  test('带备注的整套方案可以完整序列化', () {
    const profile = CompressionProfile(
      name: '网盘八分卷',
      note: '每次上传网盘时复用',
      baseName: 'backup',
      password: 'visible-password',
      doubleCompressionEnabled: true,
      innerFormat: '7z',
      outerFormat: 'zip',
      separateOutputs: false,
      volumeMode: 'count',
      volumeSize: 500,
      volumeUnit: 'MB',
      volumeCount: 8,
      level: 7,
      overwrite: true,
      keepParts: true,
      encryptHeaders: true,
      outputUri: 'content://output/tree',
      outputName: '输出目录',
      updatedAt: '2026-08-08T00:00:00.000Z',
    );

    final restored = CompressionProfile.fromJson(profile.toJson());
    expect(restored.name, '网盘八分卷');
    expect(restored.note, '每次上传网盘时复用');
    expect(restored.volumeMode, 'count');
    expect(restored.volumeCount, 8);
    expect(restored.password, 'visible-password');
    expect(restored.doubleCompressionEnabled, isTrue);
    expect(restored.outputUri, 'content://output/tree');
  });

  test('旧方案默认启用双重模式，普通模式可以持久化', () {
    final legacy = CompressionProfile.fromJson({'name': '旧方案'});
    expect(legacy.doubleCompressionEnabled, isTrue);

    final ordinary = CompressionProfile.fromJson({
      ...legacy.toJson(),
      'name': '普通压缩',
      'doubleCompressionEnabled': false,
      'separateOutputs': true,
    });
    expect(ordinary.doubleCompressionEnabled, isFalse);
    expect(ordinary.separateOutputs, isTrue);
  });
}

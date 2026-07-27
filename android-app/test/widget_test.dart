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
}

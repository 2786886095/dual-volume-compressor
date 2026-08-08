import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DualVolumeCompressorApp());
}

class DualVolumeCompressorApp extends StatelessWidget {
  const DualVolumeCompressorApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF365E9D);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '双层分卷压缩器',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        scaffoldBackgroundColor: const Color(0xFFF5F7FB),
        cardTheme: const CardTheme(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            side: BorderSide(color: Color(0xFFE0E5EF)),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
          isDense: true,
        ),
      ),
      home: const CompressorPage(),
    );
  }
}

class InputItem {
  const InputItem({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.size,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final int size;

  factory InputItem.fromMap(Map<Object?, Object?> map) => InputItem(
        path: map['path']?.toString() ?? '',
        name: map['name']?.toString() ?? '未命名',
        isDirectory: map['isDirectory'] == true,
        size: (map['size'] as num?)?.toInt() ?? 0,
      );
}

class CompressionProfile {
  const CompressionProfile({
    required this.name,
    required this.note,
    required this.baseName,
    required this.password,
    required this.doubleCompressionEnabled,
    required this.innerFormat,
    required this.outerFormat,
    required this.separateOutputs,
    required this.volumeMode,
    required this.volumeSize,
    required this.volumeUnit,
    required this.volumeCount,
    required this.level,
    required this.overwrite,
    required this.keepParts,
    required this.encryptHeaders,
    required this.outputUri,
    required this.outputName,
    required this.updatedAt,
  });

  final String name;
  final String note;
  final String baseName;
  final String password;
  final bool doubleCompressionEnabled;
  final String innerFormat;
  final String outerFormat;
  final bool separateOutputs;
  final String volumeMode;
  final int volumeSize;
  final String volumeUnit;
  final int volumeCount;
  final int level;
  final bool overwrite;
  final bool keepParts;
  final bool encryptHeaders;
  final String? outputUri;
  final String? outputName;
  final String updatedAt;

  factory CompressionProfile.fromJson(Map<String, dynamic> json) =>
      CompressionProfile(
        name: json['name']?.toString() ?? '',
        note: json['note']?.toString() ?? '',
        baseName: json['baseName']?.toString() ?? '',
        password: json['password']?.toString() ?? '',
        doubleCompressionEnabled: json['doubleCompressionEnabled'] != false,
        innerFormat: json['innerFormat']?.toString() ?? '7z',
        outerFormat: json['outerFormat']?.toString() ?? '7z',
        separateOutputs: json['separateOutputs'] == true,
        volumeMode: json['volumeMode']?.toString() ?? 'size',
        volumeSize: (json['volumeSize'] as num?)?.toInt() ?? 500,
        volumeUnit: json['volumeUnit']?.toString() ?? 'MB',
        volumeCount: (json['volumeCount'] as num?)?.toInt() ?? 5,
        level: (json['level'] as num?)?.toInt() ?? 5,
        overwrite: json['overwrite'] == true,
        keepParts: json['keepParts'] == true,
        encryptHeaders: json['encryptHeaders'] != false,
        outputUri: json['outputUri']?.toString(),
        outputName: json['outputName']?.toString(),
        updatedAt: json['updatedAt']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'note': note,
        'baseName': baseName,
        'password': password,
        'doubleCompressionEnabled': doubleCompressionEnabled,
        'innerFormat': innerFormat,
        'outerFormat': outerFormat,
        'separateOutputs': separateOutputs,
        'volumeMode': volumeMode,
        'volumeSize': volumeSize,
        'volumeUnit': volumeUnit,
        'volumeCount': volumeCount,
        'level': level,
        'overwrite': overwrite,
        'keepParts': keepParts,
        'encryptHeaders': encryptHeaders,
        'outputUri': outputUri,
        'outputName': outputName,
        'updatedAt': updatedAt,
      };
}

class CompressorPage extends StatefulWidget {
  const CompressorPage({super.key});

  @override
  State<CompressorPage> createState() => _CompressorPageState();
}

class _CompressorPageState extends State<CompressorPage> {
  static const _channel = MethodChannel(
    'com.langbaistudio.dual_volume_compressor/native',
  );
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final _baseNameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _volumeSizeController = TextEditingController(text: '500');
  final _volumeCountController = TextEditingController(text: '5');
  final _profileNameController = TextEditingController();
  final _profileNoteController = TextEditingController();
  final _logController = ScrollController();

  final List<InputItem> _inputs = [];
  final List<String> _namePresets = [];
  final List<String> _passwordPresets = [];
  final List<CompressionProfile> _compressionProfiles = [];
  final List<String> _logs = [];

  bool _loading = true;
  bool _running = false;
  bool _separateOutputs = false;
  bool _overwrite = false;
  bool _keepParts = false;
  bool _encryptHeaders = true;
  bool _doubleCompressionEnabled = true;
  String _innerFormat = '7z';
  String _outerFormat = '7z';
  String _volumeMode = 'size';
  String _volumeUnit = 'MB';
  int _level = 5;
  String? _outputUri;
  String? _outputName;
  int? _selectedCompressionProfileIndex;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_handleNativeCall);
    _loadSettings();
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'progress') {
      _appendLog(call.arguments?.toString() ?? '');
    } else if (call.method == 'sharedInputs') {
      _addNativeItems(call.arguments);
    }
  }

  Future<void> _loadSettings() async {
    final preferences = await SharedPreferences.getInstance();
    final passwordJson = await _secureStorage.read(key: 'password_presets');
    final selectedPassword =
        await _secureStorage.read(key: 'selected_password');
    final profileJson = await _secureStorage.read(key: 'compression_profiles');
    final loadedProfiles = <CompressionProfile>[];
    if (profileJson != null && profileJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(profileJson);
        if (decoded is List) {
          loadedProfiles.addAll(
            decoded.whereType<Map>().map(
                  (value) => CompressionProfile.fromJson(
                    Map<String, dynamic>.from(value),
                  ),
                ),
          );
        }
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _baseNameController.text = preferences.getString('base_name') ??
          'double-archive-${DateTime.now().millisecondsSinceEpoch}';
      _namePresets
        ..clear()
        ..addAll(preferences.getStringList('name_presets') ?? const []);
      _compressionProfiles
        ..clear()
        ..addAll(loadedProfiles.where((profile) => profile.name.isNotEmpty));
      if (passwordJson != null && passwordJson.isNotEmpty) {
        try {
          _passwordPresets
            ..clear()
            ..addAll(
                (jsonDecode(passwordJson) as List).map((e) => e.toString()));
        } catch (_) {}
      }
      if (selectedPassword != null &&
          _passwordPresets.contains(selectedPassword)) {
        _passwordController.text = selectedPassword;
        _confirmController.text = selectedPassword;
      }
      _innerFormat = preferences.getString('inner_format') ?? '7z';
      _outerFormat = preferences.getString('outer_format') ?? '7z';
      _volumeMode = preferences.getString('volume_mode') ?? 'size';
      _volumeUnit = preferences.getString('volume_unit') ?? 'MB';
      _volumeSizeController.text =
          (preferences.getInt('volume_size') ?? 500).toString();
      _volumeCountController.text =
          (preferences.getInt('volume_count') ?? 5).toString();
      _level = preferences.getInt('level') ?? 5;
      _separateOutputs = preferences.getBool('separate_outputs') ?? false;
      _overwrite = preferences.getBool('overwrite') ?? false;
      _keepParts = preferences.getBool('keep_parts') ?? false;
      _encryptHeaders = preferences.getBool('encrypt_headers') ?? true;
      _doubleCompressionEnabled =
          preferences.getBool('double_compression_enabled') ?? true;
      _outputUri = preferences.getString('output_uri');
      _outputName = preferences.getString('output_name');
      _loading = false;
    });

    try {
      final initial = await _channel.invokeMethod<List<Object?>>(
        'getInitialInputs',
      );
      _addNativeItems(initial);
    } on PlatformException catch (error) {
      _appendLog('分享文件导入失败: ${error.message}');
    }
  }

  Future<void> _saveSettings() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('base_name', _baseNameController.text.trim());
    await preferences.setStringList('name_presets', _namePresets);
    await preferences.setString('inner_format', _innerFormat);
    await preferences.setString('outer_format', _outerFormat);
    await preferences.setString('volume_mode', _volumeMode);
    await preferences.setString('volume_unit', _volumeUnit);
    await preferences.setInt(
      'volume_size',
      int.tryParse(_volumeSizeController.text) ?? 500,
    );
    await preferences.setInt(
      'volume_count',
      int.tryParse(_volumeCountController.text) ?? 5,
    );
    await preferences.setInt('level', _level);
    await preferences.setBool('separate_outputs', _separateOutputs);
    await preferences.setBool('overwrite', _overwrite);
    await preferences.setBool('keep_parts', _keepParts);
    await preferences.setBool('encrypt_headers', _encryptHeaders);
    await preferences.setBool(
      'double_compression_enabled',
      _doubleCompressionEnabled,
    );
    if (_outputUri == null) {
      await preferences.remove('output_uri');
      await preferences.remove('output_name');
    } else {
      await preferences.setString('output_uri', _outputUri!);
      await preferences.setString('output_name', _outputName ?? '已选择目录');
    }
    await _secureStorage.write(
      key: 'password_presets',
      value: jsonEncode(_passwordPresets),
    );
    await _secureStorage.write(
      key: 'compression_profiles',
      value: jsonEncode(
        _compressionProfiles.map((profile) => profile.toJson()).toList(),
      ),
    );
    final password = _passwordController.text;
    if (_passwordPresets.contains(password)) {
      await _secureStorage.write(key: 'selected_password', value: password);
    } else {
      await _secureStorage.delete(key: 'selected_password');
    }
  }

  void _addNativeItems(dynamic rawItems) {
    if (rawItems is! List) return;
    final newItems = rawItems
        .whereType<Map<Object?, Object?>>()
        .map(InputItem.fromMap)
        .where((item) => item.path.isNotEmpty);
    if (!mounted) return;
    setState(() {
      for (final item in newItems) {
        if (_inputs.every((existing) => existing.path != item.path)) {
          _inputs.add(item);
        }
      }
    });
  }

  Future<void> _pickFiles() async {
    try {
      final items = await _channel.invokeMethod<List<Object?>>('pickFiles');
      _addNativeItems(items);
    } on PlatformException catch (error) {
      _showMessage(error.message ?? '选择文件失败');
    }
  }

  Future<void> _pickFolder() async {
    try {
      final items = await _channel.invokeMethod<List<Object?>>('pickFolder');
      _addNativeItems(items);
    } on PlatformException catch (error) {
      _showMessage(error.message ?? '选择文件夹失败');
    }
  }

  Future<void> _pickOutput() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'pickOutputDirectory',
      );
      if (result == null || !mounted) return;
      setState(() {
        _outputUri = result['uri']?.toString();
        _outputName = result['name']?.toString();
      });
      unawaited(_saveSettings());
    } on PlatformException catch (error) {
      _showMessage(error.message ?? '选择输出目录失败');
    }
  }

  void _saveNamePreset() {
    final value = _sanitizeName(_baseNameController.text);
    if (value.isEmpty) return;
    final exists = _namePresets.any(
      (item) => item.toLowerCase() == value.toLowerCase(),
    );
    setState(() {
      _baseNameController.text = value;
      if (!exists) _namePresets.add(value);
    });
    unawaited(_saveSettings());
  }

  void _deleteNamePreset() {
    final value = _baseNameController.text;
    setState(() {
      _namePresets.removeWhere(
        (item) => item.toLowerCase() == value.toLowerCase(),
      );
      _baseNameController.clear();
    });
    unawaited(_saveSettings());
  }

  void _savePasswordPreset() {
    final value = _passwordController.text;
    if (value.isEmpty) {
      _showMessage('请输入要保存的密码');
      return;
    }
    setState(() {
      if (!_passwordPresets.contains(value)) _passwordPresets.add(value);
      _confirmController.text = value;
    });
    unawaited(_saveSettings());
  }

  void _deletePasswordPreset() {
    final value = _passwordController.text;
    setState(() {
      _passwordPresets.remove(value);
      _passwordController.clear();
      _confirmController.clear();
    });
    unawaited(_saveSettings());
  }

  CompressionProfile _captureCompressionProfile(String name, String note) =>
      CompressionProfile(
        name: name.trim(),
        note: note.trim(),
        baseName: _baseNameController.text.trim(),
        password: _passwordController.text,
        doubleCompressionEnabled: _doubleCompressionEnabled,
        innerFormat: _innerFormat,
        outerFormat: _outerFormat,
        separateOutputs: _separateOutputs,
        volumeMode: _volumeMode,
        volumeSize: int.tryParse(_volumeSizeController.text) ?? 500,
        volumeUnit: _volumeUnit,
        volumeCount: int.tryParse(_volumeCountController.text) ?? 5,
        level: _level,
        overwrite: _overwrite,
        keepParts: _keepParts,
        encryptHeaders: _encryptHeaders,
        outputUri: _outputUri,
        outputName: _outputName,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );

  Future<void> _applyCompressionProfile(CompressionProfile profile) async {
    setState(() {
      _baseNameController.text = profile.baseName;
      _passwordController.text = profile.password;
      _confirmController.text = profile.password;
      _doubleCompressionEnabled = profile.doubleCompressionEnabled;
      _innerFormat = profile.innerFormat;
      _outerFormat = profile.outerFormat;
      _separateOutputs = profile.separateOutputs;
      _volumeMode = profile.volumeMode;
      _volumeSizeController.text = profile.volumeSize.toString();
      _volumeUnit = profile.volumeUnit;
      _volumeCountController.text = profile.volumeCount.toString();
      _level = profile.level;
      _overwrite = profile.overwrite;
      _keepParts = profile.keepParts;
      _encryptHeaders = profile.encryptHeaders;
      _outputUri = profile.outputUri;
      _outputName = profile.outputName;
    });
    await _saveSettings();
    _showMessage('已应用方案预设：${profile.name}');
  }

  void _selectCompressionProfile(int? index) {
    setState(() {
      _selectedCompressionProfileIndex = index;
      if (index != null && index >= 0 && index < _compressionProfiles.length) {
        final profile = _compressionProfiles[index];
        _profileNameController.text = profile.name;
        _profileNoteController.text = profile.note;
      }
    });
  }

  void _newCompressionProfile() {
    setState(() {
      _selectedCompressionProfileIndex = null;
      _profileNameController.clear();
      _profileNoteController.clear();
    });
  }

  Future<void> _saveCurrentCompressionProfile() async {
    final name = _profileNameController.text.trim();
    if (name.isEmpty) {
      _showMessage('请输入预设名称。');
      return;
    }

    final profile =
        _captureCompressionProfile(name, _profileNoteController.text);
    var targetIndex = _selectedCompressionProfileIndex;
    targetIndex ??= _compressionProfiles.indexWhere(
      (item) => item.name.toLowerCase() == name.toLowerCase(),
    );
    setState(() {
      if (targetIndex != null && targetIndex! >= 0) {
        _compressionProfiles[targetIndex!] = profile;
      } else {
        _compressionProfiles.add(profile);
        targetIndex = _compressionProfiles.length - 1;
      }
      _selectedCompressionProfileIndex = targetIndex;
    });
    await _saveSettings();
    _showMessage('当前配置已保存为：$name');
  }

  Future<void> _applySelectedCompressionProfile() async {
    final index = _selectedCompressionProfileIndex;
    if (index == null || index < 0 || index >= _compressionProfiles.length) {
      _showMessage('请先选择一个方案预设。');
      return;
    }
    await _applyCompressionProfile(_compressionProfiles[index]);
  }

  Future<void> _deleteSelectedCompressionProfile() async {
    final index = _selectedCompressionProfileIndex;
    if (index == null || index < 0 || index >= _compressionProfiles.length) {
      return;
    }
    setState(() {
      _compressionProfiles.removeAt(index);
      _selectedCompressionProfileIndex = null;
      _profileNameController.clear();
      _profileNoteController.clear();
    });
    await _saveSettings();
  }

  Future<void> _startCompression() async {
    if (_inputs.isEmpty) {
      _showMessage('请先添加文件或文件夹');
      return;
    }
    if (_outputUri == null) {
      _showMessage('请选择输出目录');
      return;
    }
    if (_passwordController.text != _confirmController.text) {
      _showMessage('两次输入的密码不一致');
      return;
    }
    if (!_separateOutputs && _sanitizeName(_baseNameController.text).isEmpty) {
      _showMessage('请输入压缩包名称');
      return;
    }
    final volumeSize = int.tryParse(_volumeSizeController.text);
    final volumeCount = int.tryParse(_volumeCountController.text);
    if (_doubleCompressionEnabled &&
        _volumeMode == 'size' &&
        (volumeSize == null || volumeSize < 1)) {
      _showMessage('分卷大小必须大于 0');
      return;
    }
    if (_doubleCompressionEnabled &&
        _volumeMode == 'count' &&
        (volumeCount == null || volumeCount < 2 || volumeCount > 999)) {
      _showMessage('固定分卷数量必须在 2–999 之间');
      return;
    }

    _baseNameController.text = _sanitizeName(_baseNameController.text);
    await _saveSettings();
    if (!mounted) return;
    setState(() {
      _running = true;
      _logs.clear();
    });
    _appendLog('任务开始，共 ${_inputs.length} 个输入项');

    try {
      final outputs = await _channel.invokeMethod<List<Object?>>(
        'runCompression',
        {
          'inputs': _inputs.map((item) => item.path).toList(),
          'outputUri': _outputUri,
          'separateOutputs': _separateOutputs,
          'baseName': _baseNameController.text,
          'doubleCompressionEnabled': _doubleCompressionEnabled,
          'innerFormat': _innerFormat,
          'outerFormat': _outerFormat,
          'volumeMode': _volumeMode,
          'volumeSize': volumeSize ?? 500,
          'volumeUnit': _volumeUnit,
          'volumeCount': volumeCount ?? 5,
          'level': _level,
          'password': _passwordController.text,
          'encryptHeaders': _encryptHeaders,
          'keepParts': _keepParts,
          'overwrite': _overwrite,
        },
      );
      _appendLog('全部完成，生成 ${outputs?.length ?? 0} 个最终压缩包');
      _showMessage('压缩完成，文件已保存到 $_outputName');
    } on PlatformException catch (error) {
      if (error.code == 'CANCELLED') {
        _appendLog('任务已取消');
      } else {
        _appendLog('失败: ${error.message}');
        _showMessage(error.message ?? '压缩失败');
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _cancelCompression() async {
    await _channel.invokeMethod('cancelCompression');
    _appendLog('正在取消任务…');
  }

  void _appendLog(String line) {
    if (line.trim().isEmpty || !mounted) return;
    setState(() {
      _logs.add('[${TimeOfDay.now().format(context)}] $line');
      if (_logs.length > 250) _logs.removeAt(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logController.hasClients) {
        _logController.animateTo(
          _logController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _sanitizeName(String value) => value
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .trim()
      .replaceFirst(RegExp(r'[. ]+$'), '');

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('双层分卷压缩器'),
        centerTitle: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              avatar: const Icon(Icons.security, size: 18),
              label: Text(_running ? '压缩中' : '就绪'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildIntroCard(),
                    const SizedBox(height: 12),
                    _buildCompressionProfileCard(),
                    const SizedBox(height: 12),
                    _buildInputCard(),
                    const SizedBox(height: 12),
                    _buildOutputCard(),
                    const SizedBox(height: 12),
                    _buildArchiveCard(),
                    const SizedBox(height: 12),
                    _buildPasswordCard(),
                    const SizedBox(height: 12),
                    _buildOptionsCard(),
                    const SizedBox(height: 12),
                    _buildLogCard(),
                  ],
                ),
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildIntroCard() => Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                Icons.inventory_2_outlined,
                size: 34,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Text(
                  '可选择双重分卷压缩，或关闭后按普通方式生成单个压缩包。也可从系统“分享”菜单直接导入文件。',
                  style: TextStyle(height: 1.45),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _buildCompressionProfileCard() => _sectionCard(
        title: '方案预设',
        icon: Icons.bookmarks_outlined,
        trailing: Text('${_compressionProfiles.length} 个'),
        child: Column(
          children: [
            DropdownButtonFormField<int>(
              value: _selectedCompressionProfileIndex,
              decoration: const InputDecoration(labelText: '选择已保存方案'),
              hint: const Text('尚未选择'),
              items: _compressionProfiles
                  .asMap()
                  .entries
                  .map(
                    (entry) => DropdownMenuItem<int>(
                      value: entry.key,
                      child: Text(
                        entry.value.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: _running ? null : _selectCompressionProfile,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _profileNameController,
              enabled: !_running,
              maxLength: 80,
              decoration: const InputDecoration(labelText: '预设名称'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _profileNoteController,
              enabled: !_running,
              minLines: 2,
              maxLines: 4,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: '自定义备注',
                hintText: '例如：网盘上传、固定 8 个分卷',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: _running ? null : _newCompressionProfile,
                  icon: const Icon(Icons.add),
                  label: const Text('新建'),
                ),
                TextButton.icon(
                  onPressed:
                      _running || _selectedCompressionProfileIndex == null
                          ? null
                          : _deleteSelectedCompressionProfile,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                ),
                OutlinedButton(
                  onPressed:
                      _running || _selectedCompressionProfileIndex == null
                          ? null
                          : _applySelectedCompressionProfile,
                  child: const Text('应用所选'),
                ),
                FilledButton.icon(
                  onPressed: _running ? null : _saveCurrentCompressionProfile,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存当前配置'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '保存普通/双重模式、格式、分卷参数、压缩等级、输出目录、选项和密码；输入文件列表不会保存。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      );

  Widget _buildInputCard() => _sectionCard(
        title: '待压缩项目',
        icon: Icons.file_copy_outlined,
        trailing: Text('${_inputs.length} 项'),
        child: Column(
          children: [
            if (_inputs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Text('尚未添加文件或文件夹'),
              )
            else
              ..._inputs.asMap().entries.map(
                    (entry) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        entry.value.isDirectory
                            ? Icons.folder_outlined
                            : Icons.insert_drive_file_outlined,
                      ),
                      title: Text(
                        entry.value.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(_formatSize(entry.value.size)),
                      trailing: IconButton(
                        tooltip: '移除',
                        onPressed: _running
                            ? null
                            : () => setState(() => _inputs.removeAt(entry.key)),
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _running ? null : _pickFiles,
                    icon: const Icon(Icons.note_add_outlined),
                    label: const Text('添加文件'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _running ? null : _pickFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('添加文件夹'),
                  ),
                ),
                IconButton(
                  tooltip: '清空',
                  onPressed: _running || _inputs.isEmpty
                      ? null
                      : () {
                          setState(_inputs.clear);
                          unawaited(
                              _channel.invokeMethod('clearImportedFiles'));
                        },
                  icon: const Icon(Icons.delete_sweep_outlined),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _buildOutputCard() => _sectionCard(
        title: '输出目录',
        icon: Icons.save_alt_outlined,
        child: Row(
          children: [
            Expanded(
              child: Text(
                _outputName ?? '尚未选择',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _outputUri == null
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: _running ? null : _pickOutput,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('选择'),
            ),
          ],
        ),
      );

  Widget _buildArchiveCard() => _sectionCard(
        title: '压缩设置',
        icon: Icons.tune,
        child: Column(
          children: [
            _presetTextField(
              controller: _baseNameController,
              label: '压缩包名称',
              presets: _namePresets,
              enabled: !_running && !_separateOutputs,
              onSelected: (value) =>
                  setState(() => _baseNameController.text = value),
              onSave: _saveNamePreset,
              onDelete: _deleteNamePreset,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _doubleCompressionEnabled,
              onChanged: _running
                  ? null
                  : (value) {
                      setState(() {
                        _doubleCompressionEnabled = value;
                      });
                      unawaited(_saveSettings());
                    },
              title: const Text('启用双重分卷压缩'),
              subtitle: Text(
                _doubleCompressionEnabled
                    ? '先生成分卷，再封装为最终压缩包'
                    : '普通压缩模式：不生成分卷，可继续使用单独压缩',
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _separateOutputs,
              onChanged: _running
                  ? null
                  : (value) {
                      setState(() => _separateOutputs = value);
                      unawaited(_saveSettings());
                    },
              title: const Text('每个输入项单独生成最终包'),
              subtitle: const Text('文件使用去扩展名后的名称，文件夹使用文件夹名'),
            ),
            const SizedBox(height: 8),
            if (_doubleCompressionEnabled)
              Row(
                children: [
                  Expanded(
                    child: _dropdown(
                      label: '分卷格式',
                      value: _innerFormat,
                      values: const {'7z': '7z', 'zip': 'zip'},
                      onChanged: (value) =>
                          setState(() => _innerFormat = value),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _dropdown(
                      label: '最终格式',
                      value: _outerFormat,
                      values: const {'7z': '7z', 'zip': 'zip'},
                      onChanged: (value) =>
                          setState(() => _outerFormat = value),
                    ),
                  ),
                ],
              )
            else
              _dropdown(
                label: '压缩格式',
                value: _outerFormat,
                values: const {'7z': '7z', 'zip': 'zip'},
                onChanged: (value) => setState(() => _outerFormat = value),
              ),
            const SizedBox(height: 12),
            if (_doubleCompressionEnabled)
              _dropdown(
                label: '分卷模式',
                value: _volumeMode,
                values: const {'size': '按分卷大小', 'count': '固定分卷数量'},
                onChanged: (value) => setState(() => _volumeMode = value),
              )
            else
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.inventory_2_outlined),
                title: Text('普通单层压缩'),
                subtitle: Text('分卷大小和分卷数量设置已停用'),
              ),
            const SizedBox(height: 12),
            if (_doubleCompressionEnabled && _volumeMode == 'size')
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _volumeSizeController,
                      enabled: !_running,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: '每卷大小'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 110,
                    child: _dropdown(
                      label: '单位',
                      value: _volumeUnit,
                      values: const {'MB': 'MB', 'GB': 'GB'},
                      onChanged: (value) => setState(() => _volumeUnit = value),
                    ),
                  ),
                ],
              )
            else if (_doubleCompressionEnabled)
              TextField(
                controller: _volumeCountController,
                enabled: !_running,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: '分卷数量',
                  suffixText: '个',
                  helperText: '根据完整压缩包实际大小均分，严格生成指定数量',
                ),
              ),
            const SizedBox(height: 12),
            _dropdown(
              label: '压缩等级',
              value: _level.toString(),
              values: const {
                '0': '0 - 仅打包',
                '1': '1 - 最快',
                '5': '5 - 标准',
                '7': '7 - 高',
                '9': '9 - 极限',
              },
              onChanged: (value) => setState(() => _level = int.parse(value)),
            ),
          ],
        ),
      );

  Widget _buildPasswordCard() => _sectionCard(
        title: '统一密码',
        icon: Icons.password,
        child: Column(
          children: [
            _presetTextField(
              controller: _passwordController,
              label: '密码（始终显示）',
              presets: _passwordPresets,
              enabled: !_running,
              keyboardType: TextInputType.visiblePassword,
              onSelected: (value) {
                setState(() {
                  _passwordController.text = value;
                  _confirmController.text = value;
                });
                unawaited(_saveSettings());
              },
              onSave: _savePasswordPreset,
              onDelete: _deletePasswordPreset,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirmController,
              enabled: !_running,
              keyboardType: TextInputType.visiblePassword,
              obscureText: false,
              decoration: const InputDecoration(labelText: '确认密码'),
            ),
            const SizedBox(height: 8),
            Text(
              '只有点击“保存”后才会进入密码预设；预设使用 Android 加密存储。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );

  Widget _buildOptionsCard() => _sectionCard(
        title: '其他选项',
        icon: Icons.checklist,
        child: Column(
          children: [
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _overwrite,
              onChanged: _running
                  ? null
                  : (value) => setState(() => _overwrite = value ?? false),
              title: const Text('覆盖同名最终包'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _keepParts,
              onChanged: _running || !_doubleCompressionEnabled
                  ? null
                  : (value) => setState(() => _keepParts = value ?? false),
              title: const Text('保留第一阶段分卷'),
              subtitle:
                  _doubleCompressionEnabled ? null : const Text('普通压缩模式下不生成分卷'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _encryptHeaders,
              onChanged: _running ||
                      (_doubleCompressionEnabled
                          ? (_innerFormat != '7z' && _outerFormat != '7z')
                          : _outerFormat != '7z')
                  ? null
                  : (value) => setState(() => _encryptHeaders = value ?? true),
              title: const Text('7z 文件名加密'),
              subtitle: const Text('ZIP 格式不支持隐藏文件名'),
            ),
          ],
        ),
      );

  Widget _buildLogCard() => _sectionCard(
        title: '运行日志',
        icon: Icons.terminal,
        child: Container(
          height: 170,
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF111827),
            borderRadius: BorderRadius.circular(12),
          ),
          child: _logs.isEmpty
              ? const Text('等待任务…', style: TextStyle(color: Color(0xFF9CA3AF)))
              : ListView.builder(
                  controller: _logController,
                  itemCount: _logs.length,
                  itemBuilder: (context, index) => Text(
                    _logs[index],
                    style: const TextStyle(
                      color: Color(0xFFE5E7EB),
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ),
        ),
      );

  Widget _buildBottomBar() => Material(
        elevation: 10,
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                if (_running)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _cancelCompression,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('取消'),
                    ),
                  )
                else
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _startCompression,
                      icon: const Icon(Icons.archive_outlined),
                      label: const Text('开始双层压缩'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );

  Widget _sectionCard({
    required String title,
    required IconData icon,
    required Widget child,
    Widget? trailing,
  }) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(icon, size: 21),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  if (trailing != null) trailing,
                ],
              ),
              const SizedBox(height: 14),
              child,
            ],
          ),
        ),
      );

  Widget _presetTextField({
    required TextEditingController controller,
    required String label,
    required List<String> presets,
    required bool enabled,
    required ValueChanged<String> onSelected,
    required VoidCallback onSave,
    required VoidCallback onDelete,
    TextInputType? keyboardType,
  }) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              keyboardType: keyboardType,
              obscureText: false,
              decoration: InputDecoration(
                labelText: label,
                suffixIcon: PopupMenuButton<String>(
                  tooltip: '选择预设',
                  enabled: enabled && presets.isNotEmpty,
                  icon: const Icon(Icons.arrow_drop_down),
                  onSelected: onSelected,
                  itemBuilder: (context) => presets
                      .map(
                        (value) => PopupMenuItem<String>(
                          value: value,
                          child: Text(value,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton.filledTonal(
            tooltip: '保存预设',
            onPressed: enabled ? onSave : null,
            icon: const Icon(Icons.bookmark_add_outlined),
          ),
          IconButton(
            tooltip: '删除预设',
            onPressed: enabled ? onDelete : null,
            icon: const Icon(Icons.bookmark_remove_outlined),
          ),
        ],
      );

  Widget _dropdown({
    required String label,
    required String value,
    required Map<String, String> values,
    required ValueChanged<String> onChanged,
  }) =>
      DropdownButtonFormField<String>(
        value: value,
        decoration: InputDecoration(labelText: label),
        items: values.entries
            .map(
              (entry) => DropdownMenuItem<String>(
                value: entry.key,
                child: Text(entry.value),
              ),
            )
            .toList(),
        onChanged: _running
            ? null
            : (newValue) {
                if (newValue != null) {
                  onChanged(newValue);
                  unawaited(_saveSettings());
                }
              },
      );

  @override
  void dispose() {
    _baseNameController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _volumeSizeController.dispose();
    _volumeCountController.dispose();
    _profileNameController.dispose();
    _profileNoteController.dispose();
    _logController.dispose();
    super.dispose();
  }
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

const String _defaultWorkerUrl = 'https://link-proxy.username.workers.dev';
const Duration _httpTimeout = Duration(seconds: 15);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('vault_box');
  await Hive.openBox('settings_box');

  runApp(const DataVaultApp());
}

class DataVaultApp extends StatelessWidget {
  const DataVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Data Vault - Offline & Cloud',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF090B0D),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF2E8B57),
          secondary: Color(0xFF55C878),
          surface: Color(0xFF151819),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF16191B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
        ),
      ),
      home: const AuthWrapper(),
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    final settingsBox = Hive.box('settings_box');
    return ValueListenableBuilder(
      valueListenable: settingsBox.listenable(keys: ['active_user']),
      builder: (context, Box box, _) {
        final activeUser = box.get('active_user');
        if (activeUser == null || activeUser.toString().isEmpty) {
          return const LoginPage();
        }
        return VaultDashboardPage(
          key: ValueKey(activeUser),
          username: activeUser.toString(),
        );
      },
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _userController = TextEditingController();
  final _settingsBox = Hive.box('settings_box');

  @override
  void dispose() {
    _userController.dispose();
    super.dispose();
  }

  void _login() {
    final user = _userController.text.trim();
    if (user.isEmpty) return;
    _settingsBox.put('active_user', user);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          TextButton.icon(
            onPressed: () => showWorkerSettingsDialog(context),
            icon: const Icon(Icons.settings, size: 18, color: Colors.white70),
            label: const Text('Pengaturan Worker', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 400),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF151819),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircleAvatar(
                    radius: 30,
                    backgroundColor: Color(0x332E8B57),
                    child: Icon(Icons.lock_person, color: Color(0xFF55C878), size: 30),
                  ),
                  const SizedBox(height: 16),
                  const Text('Buka Ruang Simpan', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text(
                    'Masukkan nama pengguna lokal Anda. Mendukung penyimpanan Full Offline, Backup Teks JSON, dan Cloud.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.white60),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _userController,
                    decoration: InputDecoration(
                      labelText: 'Nama Pengguna (Username)',
                      hintText: 'Contoh: adit, pribadi',
                      prefixIcon: const Icon(Icons.alternate_email),
                      filled: true,
                      fillColor: const Color(0xFF101314),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onSubmitted: (_) => _login(),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: _login,
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('Masuk ke Vault', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class VaultDashboardPage extends StatefulWidget {
  final String username;
  const VaultDashboardPage({super.key, required this.username});

  @override
  State<VaultDashboardPage> createState() => _VaultDashboardPageState();
}

class _VaultDashboardPageState extends State<VaultDashboardPage> {
  final Box _localBox = Hive.box('vault_box');
  final Box _settingsBox = Hive.box('settings_box');
  final _searchController = TextEditingController();

  late StreamSubscription<List<ConnectivityResult>> _connectivitySub;
  bool _isOnline = false;
  bool _isSyncing = false;
  String _selectedCategory = 'all';
  String _searchQuery = '';

  String get _workerUrl =>
      _settingsBox.get('worker_url', defaultValue: _defaultWorkerUrl).toString();

  /// Cloud dianggap belum dikonfigurasi selama URL masih placeholder bawaan.
  bool get _cloudConfigured => _workerUrl != _defaultWorkerUrl && _workerUrl.isNotEmpty;

  String get _pendingDeleteKey => 'pending_deletes_${widget.username}';

  List<String> get _pendingDeletes {
    final raw = _settingsBox.get(_pendingDeleteKey, defaultValue: <dynamic>[]);
    return (raw as List).map((e) => e.toString()).toList();
  }

  @override
  void initState() {
    super.initState();
    _checkInitialConnection();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (!mounted) return;
      final online = !results.contains(ConnectivityResult.none);
      setState(() => _isOnline = online);
      if (online) _syncWithWorker();
    });
  }

  Future<void> _checkInitialConnection() async {
    final results = await Connectivity().checkConnectivity();
    if (!mounted) return;
    final online = !results.contains(ConnectivityResult.none);
    setState(() => _isOnline = online);
    if (online) _syncWithWorker();
  }

  @override
  void dispose() {
    _connectivitySub.cancel();
    _searchController.dispose();
    super.dispose();
  }

  // ==========================================================
  // FITUR EXPORT & IMPORT BACKUP VIA TEKS JSON LANGSUNG
  // ==========================================================
  String _generateJsonBackupString() {
    final userItems = _localBox.values
        .map((e) => Map<String, dynamic>.from(e))
        .where((item) => item['owner'] == widget.username)
        .toList();

    final backupPayload = {
      'app': 'DataVault',
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'owner': widget.username,
      'items': userItems,
    };

    return const JsonEncoder.withIndent('  ').convert(backupPayload);
  }

  void _showExportTextDialog() {
    final jsonText = _generateJsonBackupString();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151819),
        title: const Row(
          children: [
            Icon(Icons.code, color: Colors.amber, size: 20),
            SizedBox(width: 8),
            Text('Export Teks JSON', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Salin kode JSON di bawah ini dan simpan di tempat aman (catatan, WA, atau email):',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 10),
              Container(
                height: 220,
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0C0E),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    jsonText,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.greenAccent),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup')),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: jsonText));
              Navigator.pop(ctx);
              _showSnack('Kode JSON berhasil disalin ke clipboard!');
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Salin Semua JSON'),
          ),
        ],
      ),
    );
  }

  void _showImportTextDialog() {
    final importCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151819),
        title: const Row(
          children: [
            Icon(Icons.restore_page, color: Colors.greenAccent, size: 20),
            SizedBox(width: 8),
            Text('Import / Restore Teks JSON', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Tempel (paste) kode JSON hasil export sebelumnya ke kotak di bawah:',
                  style: TextStyle(fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: importCtrl,
                  maxLines: 8,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  decoration: InputDecoration(
                    hintText: '{\n  "app": "DataVault",\n  "items": [ ... ]\n}',
                    filled: true,
                    fillColor: const Color(0xFF0A0C0E),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          OutlinedButton.icon(
            onPressed: () async {
              final clipData = await Clipboard.getData(Clipboard.kTextPlain);
              if (clipData?.text != null) {
                importCtrl.text = clipData!.text!;
              }
            },
            icon: const Icon(Icons.paste, size: 16),
            label: const Text('Tempel'),
          ),
          FilledButton.icon(
            onPressed: () async {
              final success = await _processJsonImport(importCtrl.text.trim());
              if (success && ctx.mounted) {
                Navigator.pop(ctx);
              }
            },
            icon: const Icon(Icons.check, size: 16),
            label: const Text('Pulihkan'),
          ),
        ],
      ),
    );
  }

  Future<bool> _processJsonImport(String rawText) async {
    if (rawText.isEmpty) {
      _showSnack('Kotak teks JSON masih kosong.');
      return false;
    }

    try {
      final decoded = jsonDecode(rawText);
      List<dynamic> importedList = [];

      if (decoded is Map && decoded['items'] is List) {
        importedList = decoded['items'];
      } else if (decoded is List) {
        importedList = decoded;
      } else {
        _showSnack('Format JSON tidak dikenali.');
        return false;
      }

      int restoredCount = 0;
      int skippedCount = 0;
      for (var raw in importedList) {
        if (raw is Map) {
          final id = (raw['id'] ?? const Uuid().v4()).toString();

          // Jangan timpa catatan yang sudah ada (mencegah duplikat / kehilangan data).
          if (_localBox.containsKey(id)) {
            skippedCount++;
            continue;
          }

          await _localBox.put(id, {
            'id': id,
            'owner': widget.username,
            'judul': (raw['judul'] ?? 'Tanpa Judul').toString(),
            'url': (raw['url'] ?? '').toString(),
            'kategori': (raw['kategori'] ?? 'text').toString(),
            'pinned': raw['pinned'] == true,
            'is_local_only': raw['is_local_only'] != false,
            'is_synced': false,
            'pin_dirty': false,
          });
          restoredCount++;
        }
      }

      _showSnack(
        skippedCount > 0
            ? 'Dipulihkan $restoredCount catatan, $skippedCount dilewati (sudah ada).'
            : 'Berhasil memulihkan $restoredCount catatan!',
      );
      if (_isOnline) _syncWithWorker();
      return true;
    } catch (e) {
      _showSnack('Kode JSON tidak valid / terpotong. Periksa kembali.');
      return false;
    }
  }

  void _showBackupMenuModal() {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: const Color(0xFF151819),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            const Text('Backup & Restore (Teks JSON)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
              'Salin dan tempel kode JSON langsung tanpa perlu menyimpan file di HP.',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0x33F59E0B),
                child: Icon(Icons.copy_all, color: Colors.amber),
              ),
              title: const Text('Export ke Teks JSON', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Tampilkan & salin kode cadangan JSON', style: TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                _showExportTextDialog();
              },
            ),
            const Divider(color: Colors.white12),
            ListTile(
              leading: const CircleAvatar(
                backgroundColor: Color(0x3310B981),
                child: Icon(Icons.paste, color: Colors.greenAccent),
              ),
              title: const Text('Import dari Teks JSON', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Tempel kode JSON untuk memulihkan catatan', style: TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                _showImportTextDialog();
              },
            ),
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================================
  // SINKRONISASI CLOUD (CLOUDFLARE WORKER)
  // ==========================================================
  Future<void> _syncWithWorker() async {
    if (_isSyncing || !_isOnline) return;
    if (!_cloudConfigured) return; // URL Worker belum diatur, lewati sync.

    setState(() => _isSyncing = true);

    try {
      final headers = {'Content-Type': 'application/json'};

      // 1) Kirim penghapusan yang tertunda (dihapus saat offline).
      final pending = _pendingDeletes;
      final stillPending = <String>[];
      for (final id in pending) {
        try {
          final res = await http
              .delete(Uri.parse('$_workerUrl/links?id=$id'))
              .timeout(_httpTimeout);
          final ok = (res.statusCode >= 200 && res.statusCode < 300) || res.statusCode == 404;
          if (!ok) stillPending.add(id);
        } catch (_) {
          stillPending.add(id);
        }
      }
      await _settingsBox.put(_pendingDeleteKey, stillPending);

      // 2) Upload item baru yang belum tersinkron.
      for (final key in _localBox.keys.toList()) {
        final stored = _localBox.get(key);
        if (stored == null) continue;
        final item = Map<String, dynamic>.from(stored);
        final isLocalOnly = item['is_local_only'] == true;

        if (item['owner'] == widget.username && !isLocalOnly && item['is_synced'] != true) {
          try {
            final res = await http
                .post(
                  Uri.parse('$_workerUrl/links'),
                  headers: headers,
                  body: jsonEncode({
                    'owner': item['owner'],
                    'judul': item['judul'],
                    'url': item['url'],
                    'kategori': item['kategori'],
                    'pinned': item['pinned'] ?? false,
                  }),
                )
                .timeout(_httpTimeout);

            if (res.statusCode >= 200 && res.statusCode < 300) {
              // Coba pakai id dari server agar item tidak hilang bila GET gagal.
              String? serverId;
              try {
                final body = jsonDecode(res.body);
                if (body is Map && body['id'] != null) {
                  serverId = body['id'].toString();
                }
              } catch (_) {}

              await _localBox.delete(key);
              if (serverId != null) {
                await _localBox.put(serverId, {
                  ...item,
                  'id': serverId,
                  'is_synced': true,
                  'pin_dirty': false,
                });
              }
            }
          } catch (e) {
            debugPrint('Gagal upload item: $e');
          }
        }
      }

      // 3) Kirim perubahan pin yang tertunda.
      for (final key in _localBox.keys.toList()) {
        final stored = _localBox.get(key);
        if (stored == null) continue;
        final item = Map<String, dynamic>.from(stored);

        if (item['owner'] == widget.username &&
            item['is_local_only'] != true &&
            item['is_synced'] == true &&
            item['pin_dirty'] == true) {
          try {
            final res = await http
                .patch(
                  Uri.parse('$_workerUrl/links?id=${item['id']}'),
                  headers: headers,
                  body: jsonEncode({'pinned': item['pinned'] == true}),
                )
                .timeout(_httpTimeout);
            if (res.statusCode >= 200 && res.statusCode < 300) {
              item['pin_dirty'] = false;
              await _localBox.put(key, item);
            }
          } catch (e) {
            debugPrint('Gagal update pin: $e');
          }
        }
      }

      // 4) Ambil data terbaru dari server.
      final response = await http
          .get(Uri.parse('$_workerUrl/links?user=${Uri.encodeComponent(widget.username)}'))
          .timeout(_httpTimeout);

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is List) {
          final deleteQueue = _pendingDeletes.toSet();

          final keysToDelete = _localBox.keys.where((k) {
            final val = Map<String, dynamic>.from(_localBox.get(k));
            return val['owner'] == widget.username &&
                val['is_local_only'] != true &&
                val['is_synced'] == true &&
                val['pin_dirty'] != true;
          }).toList();
          await _localBox.deleteAll(keysToDelete);

          for (var raw in decoded) {
            if (raw is! Map || raw['id'] == null) continue;
            final id = raw['id'].toString();
            if (deleteQueue.contains(id)) continue;

            // Jangan timpa perubahan lokal yang belum terkirim.
            final existing = _localBox.get(id);
            if (existing != null && Map<String, dynamic>.from(existing)['pin_dirty'] == true) {
              continue;
            }

            await _localBox.put(id, {
              'id': id,
              'owner': raw['owner'] ?? widget.username,
              'judul': (raw['judul'] ?? '').toString(),
              'url': (raw['url'] ?? '').toString(),
              'kategori': (raw['kategori'] ?? 'link').toString(),
              'pinned': raw['pinned'] == true,
              'is_local_only': false,
              'is_synced': true,
              'pin_dirty': false,
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Error sinkronisasi Worker: $e');
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<void> _addNewItem(String judul, String url, String kategori, bool isLocalOnly) async {
    final tempId = const Uuid().v4();
    await _localBox.put(tempId, {
      'id': tempId,
      'owner': widget.username,
      'judul': judul,
      'url': url,
      'kategori': kategori,
      'pinned': false,
      'is_local_only': isLocalOnly,
      'is_synced': false,
      'pin_dirty': false,
    });

    if (!isLocalOnly) {
      if (!_cloudConfigured) {
        _showSnack('URL Worker belum diatur. Catatan akan diantre sampai URL diisi.');
      } else if (_isOnline) {
        await _syncWithWorker();
      }
    }
  }

  Future<void> _togglePin(Map<String, dynamic> item) async {
    final newStatus = !(item['pinned'] == true);
    final isCloudSynced = item['is_local_only'] != true && item['is_synced'] == true;

    item['pinned'] = newStatus;
    item['pin_dirty'] = isCloudSynced; // tandai agar dikirim saat sync
    await _localBox.put(item['id'], item);

    if (isCloudSynced && _isOnline && _cloudConfigured) {
      _syncWithWorker();
    }
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    final id = item['id'].toString();
    final wasOnCloud = item['is_local_only'] != true && item['is_synced'] == true;

    await _localBox.delete(id);

    if (wasOnCloud) {
      // Antrekan penghapusan agar tetap terhapus di server walau saat ini offline.
      final pending = _pendingDeletes;
      if (!pending.contains(id)) pending.add(id);
      await _settingsBox.put(_pendingDeleteKey, pending);

      if (_isOnline && _cloudConfigured) {
        _syncWithWorker();
      }
    }
    _showSnack('Catatan dihapus');
  }

  void _confirmDelete(Map<String, dynamic> item) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151819),
        title: const Text('Hapus Data Ini?', style: TextStyle(fontSize: 16)),
        content: Text(
          'Yakin ingin menghapus "${item['judul']}" secara permanen?',
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2E8B57)),
            onPressed: () {
              Navigator.pop(ctx);
              _deleteItem(item);
            },
            child: const Text('Ya, Hapus'),
          ),
        ],
      ),
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  void _showAddModal() {
    final judulCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    String kategori = 'text';
    bool isLocalOnly = true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF151819),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: (MediaQuery.of(ctx).viewInsets.bottom > MediaQuery.of(ctx).viewPadding.bottom
                    ? MediaQuery.of(ctx).viewInsets.bottom
                    : MediaQuery.of(ctx).viewPadding.bottom) +
                20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Tambah Catatan / Data Baru', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF101314),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isLocalOnly
                          ? Colors.amber.withValues(alpha: 0.4)
                          : Colors.greenAccent.withValues(alpha: 0.3),
                    ),
                  ),
                  child: SwitchListTile(
                    title: Text(
                      isLocalOnly ? 'Full Offline (Hanya di Memori HP)' : 'Sinkron ke Cloud (Cloudflare Worker)',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      isLocalOnly
                          ? 'Tidak akan pernah di-upload ke internet/server.'
                          : 'Otomatis di-upload & bisa diakses dari web.',
                      style: const TextStyle(fontSize: 11, color: Colors.white60),
                    ),
                    secondary: Icon(
                      isLocalOnly ? Icons.phone_android : Icons.cloud_upload,
                      color: isLocalOnly ? Colors.amber : Colors.greenAccent,
                    ),
                    value: isLocalOnly,
                    activeColor: Colors.amber,
                    onChanged: (val) => setModalState(() => isLocalOnly = val),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: kategori,
                  decoration: InputDecoration(
                    labelText: 'Kategori',
                    filled: true,
                    fillColor: const Color(0xFF101314),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'text', child: Text('📝 Catatan / Teks')),
                    DropdownMenuItem(value: 'link', child: Text('🔗 Tautan / Link Web')),
                    DropdownMenuItem(value: 'code', child: Text('💻 Kode Script')),
                    DropdownMenuItem(value: 'media', child: Text('🎬 Media / Video')),
                  ],
                  onChanged: (val) => setModalState(() => kategori = val ?? 'text'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: judulCtrl,
                  decoration: InputDecoration(
                    labelText: 'Judul Catatan',
                    filled: true,
                    fillColor: const Color(0xFF101314),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlCtrl,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: 'Isi Catatan / URL / Kode',
                    filled: true,
                    fillColor: const Color(0xFF101314),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: () {
                      if (judulCtrl.text.trim().isNotEmpty && urlCtrl.text.trim().isNotEmpty) {
                        _addNewItem(judulCtrl.text.trim(), urlCtrl.text.trim(), kategori, isLocalOnly);
                        Navigator.pop(ctx);
                      } else {
                        _showSnack('Judul dan isi tidak boleh kosong.');
                      }
                    },
                    icon: Icon(isLocalOnly ? Icons.save : Icons.cloud_upload),
                    label: Text(isLocalOnly ? 'Simpan Lokal di HP' : 'Simpan & Upload ke Cloud'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E1113),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Data Vault', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text('User: @${widget.username}', style: const TextStyle(fontSize: 12, color: Color(0xFF55C878))),
          ],
        ),
        actions: [
          Icon(
            _isOnline ? Icons.wifi : Icons.wifi_off,
            size: 18,
            color: _isOnline ? Colors.greenAccent : Colors.white38,
          ),
          IconButton(
            icon: const Icon(Icons.data_object, color: Colors.amber),
            tooltip: 'Export / Import Teks JSON',
            onPressed: _showBackupMenuModal,
          ),
          IconButton(
            icon: _isSyncing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            tooltip: 'Sinkronkan Cloud',
            onPressed: _isOnline
                ? () {
                    if (!_cloudConfigured) {
                      _showSnack('Atur URL Worker terlebih dahulu di Pengaturan.');
                      return;
                    }
                    _syncWithWorker();
                  }
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Pengaturan Worker',
            onPressed: () => showWorkerSettingsDialog(context, onSaved: _syncWithWorker),
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.greenAccent),
            tooltip: 'Keluar',
            onPressed: () => _settingsBox.delete('active_user'),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  onChanged: (val) => setState(() => _searchQuery = val.toLowerCase()),
                  decoration: InputDecoration(
                    hintText: 'Cari catatan lokal & cloud...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFF151819),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildFilterChip('all', 'Semua'),
                      _buildFilterChip('local', '📱 Full Offline'),
                      _buildFilterChip('text', '📝 Catatan'),
                      _buildFilterChip('link', '🔗 Link'),
                      _buildFilterChip('code', '💻 Kode'),
                      _buildFilterChip('media', '🎬 Media'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ValueListenableBuilder(
              valueListenable: _localBox.listenable(),
              builder: (context, Box box, _) {
                final items = box.values
                    .map((e) => Map<String, dynamic>.from(e))
                    .where((item) => item['owner'] == widget.username)
                    .where((item) {
                      bool matchCat = true;
                      if (_selectedCategory == 'local') {
                        matchCat = item['is_local_only'] == true;
                      } else if (_selectedCategory != 'all') {
                        matchCat = item['kategori'] == _selectedCategory;
                      }
                      final matchSearch = item['judul'].toString().toLowerCase().contains(_searchQuery) ||
                          item['url'].toString().toLowerCase().contains(_searchQuery);
                      return matchCat && matchSearch;
                    })
                    .toList();

                items.sort((a, b) {
                  final pinA = a['pinned'] == true ? 1 : 0;
                  final pinB = b['pinned'] == true ? 1 : 0;
                  return pinB.compareTo(pinA);
                });

                if (items.isEmpty) {
                  return const Center(
                    child: Text(
                      'Belum ada catatan.\nTekan tombol + untuk menambah.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final isPinned = item['pinned'] == true;
                    final isLocalOnly = item['is_local_only'] == true;
                    final isSynced = item['is_synced'] == true;
                    final cleanContent = item['url'].toString().replaceAll(r'\n', '\n');

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color: isPinned
                              ? Colors.amber.withValues(alpha: 0.6)
                              : Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                _buildCategoryBadge(item['kategori'] ?? 'text'),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: isLocalOnly
                                        ? Colors.amber.withValues(alpha: 0.15)
                                        : (isSynced
                                            ? Colors.greenAccent.withValues(alpha: 0.15)
                                            : Colors.grey.withValues(alpha: 0.15)),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    isLocalOnly
                                        ? '📱 Lokal HP'
                                        : (isSynced ? '☁️ Cloud' : '⏳ Antre Sync'),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: isLocalOnly
                                          ? Colors.amber
                                          : (isSynced ? Colors.greenAccent : Colors.white70),
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                IconButton(
                                  icon: Icon(
                                    Icons.push_pin,
                                    size: 18,
                                    color: isPinned ? Colors.amber : Colors.white38,
                                  ),
                                  onPressed: () => _togglePin(item),
                                ),
                              ],
                            ),
                            Text(
                              item['judul'].toString(),
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              constraints: const BoxConstraints(maxHeight: 140),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0C0F10),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                              ),
                              child: SingleChildScrollView(
                                child: SelectableText(
                                  cleanContent,
                                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white70),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    minimumSize: Size.zero,
                                  ),
                                  onPressed: () {
                                    Clipboard.setData(ClipboardData(text: cleanContent));
                                    _showSnack('Teks tersalin ke clipboard!');
                                  },
                                  icon: const Icon(Icons.copy, size: 14),
                                  label: const Text('Salin', style: TextStyle(fontSize: 12)),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.greenAccent, size: 20),
                                  onPressed: () => _confirmDelete(item),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddModal,
        icon: const Icon(Icons.add),
        label: const Text('Tambah'),
      ),
    );
  }

  Widget _buildFilterChip(String value, String label) {
    final isSelected = _selectedCategory == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: isSelected,
        selectedColor: const Color(0xFF2E8B57),
        onSelected: (_) => setState(() => _selectedCategory = value),
      ),
    );
  }

  Widget _buildCategoryBadge(String kat) {
    final map = {
      'code': ('💻 Kode', Colors.indigoAccent),
      'text': ('📝 Catatan', Colors.tealAccent),
      'media': ('🎬 Media', Colors.purpleAccent),
      'link': ('🔗 Link', Colors.lightBlueAccent),
    };
    final info = map[kat] ?? ('📝 Catatan', Colors.tealAccent);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: info.$2.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(info.$1, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: info.$2)),
    );
  }
}

void showWorkerSettingsDialog(BuildContext context, {VoidCallback? onSaved}) {
  final settingsBox = Hive.box('settings_box');
  final ctrl = TextEditingController(
    text: settingsBox.get('worker_url', defaultValue: _defaultWorkerUrl).toString(),
  );

  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF151819),
      title: const Text('Pengaturan Cloudflare Worker', style: TextStyle(fontSize: 16)),
      content: TextField(
        controller: ctrl,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        decoration: const InputDecoration(
          labelText: 'Worker Proxy URL (Opsional jika Full Offline)',
          hintText: _defaultWorkerUrl,
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
        FilledButton(
          onPressed: () {
            final url = ctrl.text.trim().replaceAll(RegExp(r'/+$'), '');
            final valid = Uri.tryParse(url)?.hasScheme == true && url.startsWith('http');
            if (valid) {
              settingsBox.put('worker_url', url);
              Navigator.pop(ctx);
              onSaved?.call();
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('URL harus diawali http:// atau https://')),
              );
            }
          },
          child: const Text('Simpan URL'),
        ),
      ],
    ),
  );
}
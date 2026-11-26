import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const StrukApp());

class StrukApp extends StatelessWidget {
  const StrukApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Struk Toko',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HalamanStruk(),
    );
  }
}

class Item {
  String nama;
  int qty;
  int harga;
  Item(this.nama, this.qty, this.harga);
  int get total => qty * harga;
}

class HalamanStruk extends StatefulWidget {
  const HalamanStruk({super.key});

  @override
  State<HalamanStruk> createState() => _HalamanStrukState();
}

class _HalamanStrukState extends State<HalamanStruk> {
  // ---- Pengaturan toko (tersimpan permanen) ----
  final tokoCtrl = TextEditingController(text: 'TOKO SAYA');
  final alamatCtrl = TextEditingController(text: 'Jl. Contoh No. 1');
  final footerCtrl = TextEditingController(text: 'Terima kasih atas kunjungan Anda');
  String? logoPath;

  // ---- Data transaksi ----
  final metodeCtrl = TextEditingController(text: 'Tunai');
  final dibayarCtrl = TextEditingController();
  final namaCtrl = TextEditingController();
  final qtyCtrl = TextEditingController(text: '1');
  final hargaCtrl = TextEditingController();
  final List<Item> items = [];
  DateTime waktu = DateTime.now();
  String noTrx = _buatNoTrx();

  // ---- Printer ----
  List<BluetoothInfo> perangkat = [];
  BluetoothInfo? terpilih;
  bool terhubung = false;
  bool lebar80mm = false;
  int tambahMm = 7; // tambahan lebar cetak (mm)
  int ruangBawah = 1; // jumlah baris kosong di bawah struk
  double logoUkuran = 110; // lebar logo di struk

  final GlobalKey strukKey = GlobalKey();
  final GlobalKey kompKey = GlobalKey();
  static const MethodChannel _kanal = MethodChannel('struk/share');

  static String _buatNoTrx() {
    final n = DateTime.now();
    return 'TRX${n.year}${_d(n.month)}${_d(n.day)}${_d(n.hour)}${_d(n.minute)}${_d(n.second)}';
  }

  static String _d(int v) => v.toString().padLeft(2, '0');

  @override
  void initState() {
    super.initState();
    _muatPengaturan().then((_) => _mulaiTerimaShare());
  }

  Future<void> _muatPengaturan() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      tokoCtrl.text = p.getString('toko') ?? tokoCtrl.text;
      alamatCtrl.text = p.getString('alamat') ?? alamatCtrl.text;
      footerCtrl.text = p.getString('footer') ?? footerCtrl.text;
      final path = p.getString('logo');
      if (path != null && File(path).existsSync()) logoPath = path;
      lebar80mm = p.getBool('lebar80') ?? false;
      tambahMm = p.getInt('tambahMm') ?? 7;
      ruangBawah = p.getInt('ruangBawah') ?? 1;
      logoUkuran = p.getDouble('logoUkuran') ?? 110;
    });
  }

  Future<void> _simpanPengaturan() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('toko', tokoCtrl.text);
    await p.setString('alamat', alamatCtrl.text);
    await p.setString('footer', footerCtrl.text);
    await p.setBool('lebar80', lebar80mm);
    await p.setInt('tambahMm', tambahMm);
    await p.setInt('ruangBawah', ruangBawah);
    await p.setDouble('logoUkuran', logoUkuran);
    if (logoPath != null) {
      await p.setString('logo', logoPath!);
    } else {
      await p.remove('logo');
    }
  }

  // ---- Helper ----
  int get grandTotal => items.fold(0, (a, b) => a + b.total);
  int get dibayar => int.tryParse(dibayarCtrl.text) ?? 0;

  String rp(int n) {
    final s = n.abs().toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
      buf.write(s[i]);
    }
    return '${n < 0 ? '-' : ''}Rp$buf';
  }

  String get tanggalTeks =>
      '${_d(waktu.day)}-${_d(waktu.month)}-${waktu.year}  ${_d(waktu.hour)}:${_d(waktu.minute)}';

  void pesan(String teks) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(teks)));
  }

  // ---- Logo ----
  Future<void> pilihLogo() async {
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, maxWidth: 600, maxHeight: 600);
    if (picked == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final tujuan = '${dir.path}/logo_${DateTime.now().millisecondsSinceEpoch}.png';
    await File(picked.path).copy(tujuan);
    setState(() => logoPath = tujuan);
    _simpanPengaturan();
  }

  void hapusLogo() {
    setState(() => logoPath = null);
    _simpanPengaturan();
  }

  // ---- Item ----
  void tambahItem() {
    final nama = namaCtrl.text.trim();
    final qty = int.tryParse(qtyCtrl.text) ?? 0;
    final harga = int.tryParse(hargaCtrl.text) ?? 0;
    if (nama.isEmpty || qty <= 0 || harga <= 0) {
      pesan('Isi nama, jumlah, dan harga dengan benar');
      return;
    }
    setState(() {
      items.add(Item(nama, qty, harga));
      namaCtrl.clear();
      qtyCtrl.text = '1';
      hargaCtrl.clear();
    });
  }

  void strukBaru() {
    setState(() {
      items.clear();
      dibayarCtrl.clear();
      waktu = DateTime.now();
      noTrx = _buatNoTrx();
    });
  }

  // ---- Tangkap struk jadi gambar PNG ----
  Future<Uint8List> tangkapStruk({double pixelRatio = 3}) =>
      tangkap(strukKey, pixelRatio: pixelRatio);

  Future<Uint8List> tangkap(GlobalKey key, {double pixelRatio = 3}) async {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  Future<void> bagikan() async {
    if (items.isEmpty) {
      pesan('Belum ada item');
      return;
    }
    final bytes = await tangkapStruk();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$noTrx.png');
    await file.writeAsBytes(bytes);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'image/png')],
      text: 'Struk ${tokoCtrl.text}',
    );
  }

  // ---- Bluetooth ----
  Future<void> cariPerangkat() async {
    await [
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location,
    ].request();
    if (!await PrintBluetoothThermal.bluetoothEnabled) {
      pesan('Nyalakan Bluetooth dulu');
      return;
    }
    final list = await PrintBluetoothThermal.pairedBluetooths;
    setState(() => perangkat = list);
    if (list.isEmpty) {
      pesan('Belum ada printer yang dipasangkan. Pairing dulu di Pengaturan Bluetooth HP.');
    }
  }

  Future<void> sambungkan() async {
    if (terpilih == null) {
      pesan('Pilih printer dulu');
      return;
    }
    final ok = await PrintBluetoothThermal.connect(
        macPrinterAddress: terpilih!.macAdress);
    setState(() => terhubung = ok);
    if (ok) {
      final p = await SharedPreferences.getInstance();
      await p.setString('printerMac', terpilih!.macAdress);
    }
    pesan(ok ? 'Terhubung ke ${terpilih!.name}' : 'Gagal terhubung');
  }

  Future<void> cetak() async {
    if (items.isEmpty) {
      pesan('Belum ada item');
      return;
    }
    await cetakKey(strukKey);
  }

  // Cetak widget (struk / gambar dari aplikasi lain) sebagai gambar
  // hitam-putih pekat, memakai cara kirim yang sudah terbukti jalan.
  Future<void> cetakKey(GlobalKey key) async {
    if (!await pastikanTerhubung()) return;
    final dasar = lebar80mm ? 576 : 384; // titik cetak (8 titik = 1 mm)
    final lebar = (((dasar + tambahMm * 8) / 8).round()) * 8;
    // Kelebihan lebar dipangkas sama banyak di kiri dan kanan
    final potong = ((lebar - dasar) / 2).round();
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final asli =
        await boundary.toImage(pixelRatio: lebar / boundary.size.width);

    // Pekatkan teks: ubah jadi hitam-putih dengan ambang tinggi (~200 dari 255)
    const double k = 20.0;
    const double o = 127.5 - k * 200;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(
      asli,
      Offset(-potong.toDouble(), 0),
      Paint()
        ..colorFilter = const ColorFilter.matrix(<double>[
          0.299 * k, 0.587 * k, 0.114 * k, 0, o,
          0.299 * k, 0.587 * k, 0.114 * k, 0, o,
          0.299 * k, 0.587 * k, 0.114 * k, 0, o,
          0, 0, 0, 1, 0,
        ]),
    );
    final hitamPutih =
        await recorder.endRecording().toImage(dasar, asli.height);
    final data = await hitamPutih.toByteData(format: ui.ImageByteFormat.png);
    final decoded =
        data == null ? null : img.decodeImage(data.buffer.asUint8List());
    if (decoded == null) {
      pesan('Gagal membuat gambar struk');
      return;
    }
    final kecil =
        decoded.width == dasar ? decoded : img.copyResize(decoded, width: dasar);
    final profile = await CapabilityProfile.load();
    final gen = Generator(lebar80mm ? PaperSize.mm80 : PaperSize.mm58, profile);
    List<int> b = [];
    b += gen.imageRaster(kecil);
    if (ruangBawah > 0) b += gen.feed(ruangBawah);
    final ok = await PrintBluetoothThermal.writeBytes(b);
    pesan(ok ? 'Struk dicetak' : 'Gagal mencetak');
  }

  Widget stepper(String label, int nilai, int min, int max, ValueChanged<int> onChanged) {
    return Row(children: [
      Expanded(child: Text('$label: $nilai')),
      IconButton(
        onPressed: nilai > min ? () => onChanged(nilai - 1) : null,
        icon: const Icon(Icons.remove_circle_outline),
      ),
      IconButton(
        onPressed: nilai < max ? () => onChanged(nilai + 1) : null,
        icon: const Icon(Icons.add_circle_outline),
      ),
    ]);
  }

  // ---- Sambung otomatis ke printer terakhir ----
  Future<bool> pastikanTerhubung() async {
    if (await PrintBluetoothThermal.connectionStatus) {
      setState(() => terhubung = true);
      return true;
    }
    final p = await SharedPreferences.getInstance();
    final mac = terpilih?.macAdress ?? p.getString('printerMac');
    if (mac == null) {
      pesan('Pilih dan sambungkan printer dulu di menu "Cetak ke printer Bluetooth"');
      return false;
    }
    await [Permission.bluetoothConnect, Permission.bluetoothScan].request();
    final ok = await PrintBluetoothThermal.connect(macPrinterAddress: mac);
    setState(() => terhubung = ok);
    if (!ok) pesan('Gagal terhubung ke printer. Pastikan printer menyala.');
    return ok;
  }

  // ---- Terima gambar dari aplikasi lain (DANA, OVO, GoPay, bank, dll) ----
  void _mulaiTerimaShare() {
    _kanal.setMethodCallHandler((call) async {
      if (call.method == 'onShare') {
        _terimaGambar(call.arguments as String);
      }
    });
    _kanal.invokeMethod<String>('getInitialShare').then((p) {
      if (p != null) _terimaGambar(p);
    }).catchError((_) {});
  }

  void _terimaGambar(String path) {
    if (!mounted) return;
    _tampilkanSheet(path);
  }

  Future<void> pilihGambarDariGaleri() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    _terimaGambar(picked.path);
  }

  Widget kompWidget(String path, bool header) {
    return RepaintBoundary(
      key: kompKey,
      child: Container(
        width: 340,
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 6),
        child: DefaultTextStyle(
          style: const TextStyle(color: Color(0xFF222222), fontSize: 13),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (header) ...[
                if (logoPath != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(File(logoPath!),
                            width: logoUkuran, fit: BoxFit.contain),
                      ),
                    ),
                  ),
                Text(
                  tokoCtrl.text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                if (alamatCtrl.text.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(alamatCtrl.text,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF666666))),
                  ),
                const SizedBox(height: 10),
                const _GarisPutus(),
                const SizedBox(height: 10),
              ],
              Image.file(File(path),
                  fit: BoxFit.fitWidth, filterQuality: FilterQuality.high),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _tampilkanSheet(String path) async {
    bool pakaiHeader = true;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Struk dari aplikasi lain',
                    style: Theme.of(ctx).textTheme.titleMedium),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Tambahkan logo & nama toko di atas'),
                  value: pakaiHeader,
                  onChanged: (v) => setSheet(() => pakaiHeader = v),
                ),
                Center(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black12),
                    ),
                    child: kompWidget(path, pakaiHeader),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () async {
                    await cetakKey(kompKey);
                  },
                  icon: const Icon(Icons.print),
                  label: const Text('Cetak'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Tutup'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- Tampilan struk (inilah yang dibagikan/dicetak) ----
  Widget baris(String kiri, String kanan, {bool tebal = false, double size = 13}) {
    final style = TextStyle(
      fontSize: size,
      fontWeight: tebal ? FontWeight.w700 : FontWeight.w400,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(kiri, style: style)),
          const SizedBox(width: 12),
          Text(kanan, style: style, textAlign: TextAlign.right),
        ],
      ),
    );
  }

  Widget strukWidget() {
    final kembalian = dibayar - grandTotal;
    return RepaintBoundary(
      key: strukKey,
      child: Container(
        width: 340,
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 12),
        child: DefaultTextStyle(
          style: const TextStyle(color: Color(0xFF222222), fontSize: 13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (logoPath != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.file(File(logoPath!),
                          width: logoUkuran, fit: BoxFit.contain),
                    ),
                  ),
                ),
              Text(
                tokoCtrl.text,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              if (alamatCtrl.text.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(alamatCtrl.text,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12, color: Color(0xFF666666))),
                ),
              const SizedBox(height: 14),
              const _GarisPutus(),
              const SizedBox(height: 10),
              baris('No. Transaksi', noTrx, size: 12),
              baris('Tanggal', tanggalTeks, size: 12),
              baris('Pembayaran', metodeCtrl.text, size: 12),
              const SizedBox(height: 8),
              const _GarisPutus(),
              const SizedBox(height: 10),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('(belum ada item)',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF999999))),
                ),
              ...items.map((it) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(it.nama,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        baris('${it.qty} x ${rp(it.harga)}', rp(it.total),
                            size: 12),
                      ],
                    ),
                  )),
              const SizedBox(height: 4),
              const _GarisPutus(),
              const SizedBox(height: 10),
              baris('TOTAL', rp(grandTotal), tebal: true, size: 16),
              if (dibayar > 0) ...[
                baris('Dibayar', rp(dibayar), size: 12),
                baris('Kembalian', rp(kembalian < 0 ? 0 : kembalian), size: 12),
              ],
              const SizedBox(height: 10),
              const _GarisPutus(),
              const SizedBox(height: 14),
              Text(
                footerCtrl.text,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Halaman ----
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Struk Toko'),
        actions: [
          IconButton(
            tooltip: 'Struk baru',
            onPressed: strukBaru,
            icon: const Icon(Icons.note_add_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Pengaturan toko
          ExpansionTile(
            title: const Text('Logo & nama toko'),
            initiallyExpanded: true,
            childrenPadding: const EdgeInsets.only(bottom: 12),
            children: [
              Row(children: [
                FilledButton.tonalIcon(
                  onPressed: pilihLogo,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Pilih logo'),
                ),
                const SizedBox(width: 8),
                if (logoPath != null)
                  TextButton(onPressed: hapusLogo, child: const Text('Hapus logo')),
              ]),
              Row(children: [
                const Text('Ukuran logo'),
                Expanded(
                  child: Slider(
                    value: logoUkuran,
                    min: 40,
                    max: 290,
                    divisions: 25,
                    label: '${logoUkuran.round()}',
                    onChanged: (v) => setState(() => logoUkuran = v),
                    onChangeEnd: (_) => _simpanPengaturan(),
                  ),
                ),
              ]),
              TextField(
                controller: tokoCtrl,
                decoration: const InputDecoration(labelText: 'Nama toko'),
                onChanged: (_) {
                  setState(() {});
                  _simpanPengaturan();
                },
              ),
              TextField(
                controller: alamatCtrl,
                decoration: const InputDecoration(labelText: 'Alamat / keterangan'),
                onChanged: (_) {
                  setState(() {});
                  _simpanPengaturan();
                },
              ),
              TextField(
                controller: footerCtrl,
                decoration: const InputDecoration(labelText: 'Teks bawah struk'),
                onChanged: (_) {
                  setState(() {});
                  _simpanPengaturan();
                },
              ),
            ],
          ),
          ExpansionTile(
            title: const Text('Tambah item'),
            initiallyExpanded: true,
            childrenPadding: const EdgeInsets.only(bottom: 12),
            children: [
              TextField(
                controller: namaCtrl,
                decoration: const InputDecoration(labelText: 'Nama barang'),
              ),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: qtyCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Jumlah'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: hargaCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Harga satuan'),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: tambahItem,
                  icon: const Icon(Icons.add),
                  label: const Text('Tambah'),
                ),
              ),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: metodeCtrl,
                    decoration: const InputDecoration(labelText: 'Metode bayar'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: dibayarCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Uang dibayar'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ]),
              ...items.asMap().entries.map((e) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(e.value.nama),
                    subtitle: Text('${e.value.qty} x ${rp(e.value.harga)}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => setState(() => items.removeAt(e.key)),
                    ),
                  )),
            ],
          ),
          const SizedBox(height: 8),
          Text('Pratinjau struk', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Center(
            child: Container(
              decoration: BoxDecoration(
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: strukWidget(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: bagikan,
            icon: const Icon(Icons.share),
            label: const Text('Bagikan struk (gambar)'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: pilihGambarDariGaleri,
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Cetak gambar struk dari galeri'),
          ),
          const SizedBox(height: 24),
          ExpansionTile(
            title: const Text('Cetak ke printer Bluetooth'),
            childrenPadding: const EdgeInsets.only(bottom: 12),
            children: [
              Row(children: [
                Expanded(
                  child: DropdownButton<BluetoothInfo>(
                    isExpanded: true,
                    hint: const Text('Pilih printer'),
                    value: terpilih,
                    items: perangkat
                        .map((e) => DropdownMenuItem(
                            value: e, child: Text('${e.name} (${e.macAdress})')))
                        .toList(),
                    onChanged: (v) => setState(() => terpilih = v),
                  ),
                ),
                IconButton(
                    onPressed: cariPerangkat, icon: const Icon(Icons.refresh)),
              ]),
              Row(children: [
                FilledButton.tonal(
                  onPressed: sambungkan,
                  child: Text(terhubung ? 'Terhubung' : 'Sambungkan'),
                ),
                const SizedBox(width: 16),
                const Text('Kertas 80mm'),
                Switch(
                  value: lebar80mm,
                  onChanged: (v) {
                    setState(() => lebar80mm = v);
                    _simpanPengaturan();
                  },
                ),
              ]),
              stepper('Tambah lebar cetak (mm)', tambahMm, 0, 20, (v) {
                setState(() => tambahMm = v);
                _simpanPengaturan();
              }),
              stepper('Ruang kosong di bawah (baris)', ruangBawah, 0, 6, (v) {
                setState(() => ruangBawah = v);
                _simpanPengaturan();
              }),
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Isi struk dilebarkan, lalu kelebihannya dipangkas sama banyak di kiri dan kanan. Kalau tepi struk terpotong, kurangi angkanya.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: cetak,
                  icon: const Icon(Icons.print),
                  label: const Text('Cetak struk'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GarisPutus extends StatelessWidget {
  const _GarisPutus();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final n = (c.maxWidth / 7).floor();
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(
          n,
          (_) => const SizedBox(
            width: 3,
            height: 1,
            child: DecoratedBox(decoration: BoxDecoration(color: Color(0xFF999999))),
          ),
        ),
      );
    });
  }
}

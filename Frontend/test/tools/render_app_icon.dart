import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'app_icon_art.dart';

/// 应用图标的渲染工具：**出源图**，不铺平台资源。
///
/// 铺图交给 `flutter_launcher_icons`（配置见 `flutter_launcher_icons.yaml`）：Android
/// 的自适应 XML + 五档前景、iOS 的 15 张、macOS 的 7 张、Windows 的 `.ico`、web 的
/// 192/512 与 maskable，各平台的尺寸表、iOS 的去 alpha、ICO 的容器格式都是它的事
/// ——那些地方手写只会写错。这里只负责**设计**：3 张源图，全由代码确定性画出来。
///
/// 用法（文件名故意不叫 `*_test.dart`，`flutter test` 不会顺手跑它）：
///
/// ```sh
/// # 1. 出源图（assets/icon/）
/// flutter test test/tools/render_app_icon.dart
/// # 2. 铺到各平台
/// dart run flutter_launcher_icons
/// ```
///
/// 想换概念或调比例，改 `app_icon_art.dart` 再跑上面两条——所有尺寸、所有平台一起
/// 变，不会出现「16 px 那张还是旧版」。
void main() {
  test('生成 flutter_launcher_icons 的三张源图', () async {
    TestWidgetsFlutterBinding.ensureInitialized();

    final out = Directory('assets/icon')..createSync(recursive: true);

    // iOS / Android 旧图标 / web / Windows：满幅不透明方图。
    // iOS 图标必须铺满且不带透明像素（yaml 里的 `remove_alpha_ios` 再兜一层）。
    await _writePng(
      '${out.path}/app_icon.png',
      await renderIcon(IconConcept.stacked, IconTarget.fullBleed, 1024),
    );

    // Android 自适应图标的前景：只有图形、透明底，图形已经落在 66/108 的安全圆内
    // ——所以 yaml 里 `adaptive_icon_foreground_inset` 必须是 0，否则会被再缩一圈。
    await _writePng(
      '${out.path}/app_icon_foreground.png',
      await renderIcon(IconConcept.stacked, IconTarget.androidForeground, 1024),
    );

    // macOS：系统不裁也不加效果，留白、圆角、投影都在图里。
    await _writePng(
      '${out.path}/app_icon_macos.png',
      await renderIcon(IconConcept.stacked, IconTarget.macOS, 1024),
    );

    for (final name in const [
      'app_icon.png',
      'app_icon_foreground.png',
      'app_icon_macos.png',
    ]) {
      expect(
        File('${out.path}/$name').existsSync(),
        isTrue,
        reason: '$name 没生成出来，flutter_launcher_icons 会拿不到输入',
      );
    }
  });

  test('渲染概念对比预览（选方向时用）', () async {
    TestWidgetsFlutterBinding.ensureInitialized();

    final out = Directory('test/tools/out')..createSync(recursive: true);
    final rendered = <Image>[];

    for (final concept in IconConcept.values) {
      // 预览用圆角方图，接近系统裁完的样子；每个概念再出 48/32 看小尺寸可读性。
      final image = await renderIcon(concept, IconTarget.rounded, 1024);
      rendered.add(image);
      for (final size in const [1024.0, 48.0, 32.0]) {
        await _writePng(
          '${out.path}/${concept.fileName}_${size.round()}.png',
          await _scale(image, size),
        );
      }
    }

    await _writePng('${out.path}/compare.png', await _compareSheet(rendered));

    expect(
      out.listSync().whereType<File>().length,
      IconConcept.values.length * 3 + 1,
    );
  });
}

Future<void> _writePng(String path, Image image) async {
  final data = await image.toByteData(format: ImageByteFormat.png);
  File(path).writeAsBytesSync(data!.buffer.asUint8List());
}

Future<Image> _scale(Image source, double size) async {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImageRect(
    source,
    Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    Rect.fromLTWH(0, 0, size, size),
    Paint()..filterQuality = FilterQuality.high,
  );
  return recorder.endRecording().toImage(size.round(), size.round());
}

/// 对比图：上排 288 px，下排 64 / 48 / 32，从左到右是 [IconConcept] 的顺序。
Future<Image> _compareSheet(List<Image> images) async {
  const margin = 24.0;
  const column = 288.0;
  const gap = 24.0;
  const row = 64.0;
  final width = margin * 2 + column * images.length + gap * (images.length - 1);
  final height = margin * 2 + column + gap + row;

  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = const Color(0xFFEDEFEF),
  );

  final full = Rect.fromLTWH(0, 0, 1024, 1024);
  for (var i = 0; i < images.length; i++) {
    final left = margin + i * (column + gap);
    canvas.drawImageRect(
      images[i],
      full,
      Rect.fromLTWH(left, margin, column, column),
      Paint()..filterQuality = FilterQuality.high,
    );
    var x = left;
    for (final size in const [64.0, 48.0, 32.0]) {
      canvas.drawImageRect(
        images[i],
        full,
        Rect.fromLTWH(x, margin + column + gap, size, size),
        Paint()..filterQuality = FilterQuality.high,
      );
      x += size + 12;
    }
  }

  return recorder.endRecording().toImage(width.round(), height.round());
}

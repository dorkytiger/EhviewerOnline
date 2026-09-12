/// 应用图标的**图形定义**：只描述「画什么」，不管「画给谁」。
///
/// 两个使用方共享这一份：
/// * `render_app_icon.dart`：出源图 + 概念对比预览；
/// * `flutter_launcher_icons.yaml`：把源图铺到各平台。
///
/// 图形用代码画而不是位图：改一处比例、换一个色值，所有尺寸与所有平台一起变；也不会
/// 出现「16 px 那张还是旧版」这种只改了一半的事故。
///
/// 设计约束（真机与商店都踩过）：
/// * iOS 要满幅**不透明**方图，圆角由系统裁；带透明像素的 1024 会被 App Store 拒。
/// * Android 自适应图标只保证中间 66/108 的**圆**可见，图形要按对角线缩进去。
/// * macOS 系统不裁图标，留白、圆角、投影都得自己画。
/// * web 的 maskable 版安全区是直径 80% 的圆。
library;

import 'dart:math' as math;
import 'dart:ui';

/// 候选方向。当前采用 [IconConcept.stacked]（层叠封面）。
enum IconConcept {
  /// 层叠封面：三张错位叠放的封面卡，正面那张是 2×2 封面格。
  stacked('A_stacked'),

  /// 打开的书：两页微微张开，每页一格格封面。
  openBook('B_open_book'),

  /// 眼睛：瞳孔由 2×2 封面格组成。
  eye('C_eye');

  const IconConcept(this.fileName);

  /// 生成文件名用的前缀。
  final String fileName;
}

/// 图标外框的画法。各平台对「圆角、留白、投影、透明」的要求完全不同，所以显式列出
/// 来，而不是在渲染函数里塞一堆 if。
enum IconTarget {
  /// 满幅不透明方图：iOS、web 的非 maskable 图标、favicon。
  fullBleed,

  /// 圆角方图（四角透明）：设计预览、旧版 Android 的 `ic_launcher.png`。
  rounded,

  /// macOS：留白 8% + 圆角 + 投影，系统不裁。
  macOS,

  /// Android 自适应图标的**前景层**：只有图形，底色由背景层给。
  androidForeground,

  /// maskable web 图标：满幅底色 + 缩到 80% 安全圆的图形。
  maskable,
}

/// 调色板。只有主题里那两个 teal 加两个青白——图标不该引入主题之外的颜色。
const Color iconTeal = Color(0xFF009688);
const Color iconTealDark = Color(0xFF00796B);
const Color iconTealLight = Color(0xFF4DB6AC);
const Color iconPaperBright = Color(0xFFF3F8F7);

/// 设计坐标的边长；其余尺寸都由它缩放。
const double iconDesign = 1024;

/// 平台圆角遮罩的半径比例（iOS 约 22.4%）。
const double iconCornerRatio = 0.224;

/// macOS 图标四周的留白比例（Apple 的模板约 8%）。
const double _macosInsetRatio = 0.08;

/// 满幅方图里图形最长边占画布的比例。
const double _fullBleedFraction = 0.72;

/// macOS 里图形最长边占画布的比例（本体已占 84%，图形不必再大）。
const double _macosGlyphFraction = 0.62;

/// Android 自适应前景的安全圆直径（66/108）。
const double _adaptiveSafeCircle = 66 / 108;

/// maskable 的安全圆直径。
const double _maskableSafeCircle = 0.80;

/// 图形在设计坐标里的包围盒（用于按平台算缩放，不靠手写数字）。
Rect iconGlyphBounds(IconConcept concept) => switch (concept) {
      IconConcept.stacked => _stackedBounds,
      IconConcept.openBook => _openBookBounds,
      IconConcept.eye => _eyeBounds,
    };

/// 按目标平台渲染一张图标。
///
/// [size] 是输出像素边长。返回值已经是最终画面（底色、圆角、投影都在里面），调用方
/// 只负责编码与落盘。
Future<Image> renderIcon(
  IconConcept concept,
  IconTarget target,
  double size,
) async {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  final bounds = iconGlyphBounds(concept);

  switch (target) {
    case IconTarget.fullBleed:
    case IconTarget.rounded:
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size, size),
          Radius.circular(
            target == IconTarget.rounded ? size * iconCornerRatio : 0,
          ),
        ),
        Paint()..color = iconTeal,
      );
      _paintGlyphScaled(
        canvas,
        concept,
        size,
        _fitLongestSide(bounds, size * _fullBleedFraction),
      );

    case IconTarget.macOS:
      final inset = size * _macosInsetRatio;
      final body = Rect.fromLTWH(
        inset,
        inset,
        size - inset * 2,
        size - inset * 2,
      );
      final radius = Radius.circular(body.width * iconCornerRatio);
      // 投影得自己画：macOS 不裁也不加效果，少了它图标在 Dock 里像一张贴纸。
      canvas.drawRRect(
        RRect.fromRectAndRadius(body.shift(Offset(0, size * 0.012)), radius),
        Paint()
          ..color = const Color(0x33000000)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, size * 0.02),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(body, radius),
        Paint()..color = iconTeal,
      );
      _paintGlyphScaled(
        canvas,
        concept,
        size,
        _fitLongestSide(bounds, size * _macosGlyphFraction),
      );

    case IconTarget.androidForeground:
    case IconTarget.maskable:
      if (target == IconTarget.maskable) {
        // maskable 的底色必须铺满：遮罩会裁掉边角，留白会露出浏览器底色。
        canvas.drawRect(
          Rect.fromLTWH(0, 0, size, size),
          Paint()..color = iconTeal,
        );
      }
      final circle = target == IconTarget.androidForeground
          ? _adaptiveSafeCircle
          : _maskableSafeCircle;
      // 安全区是**圆**，所以约束的是包围盒的对角线，不是某一条边。
      final diagonal = Offset(bounds.width, bounds.height).distance;
      _paintGlyphScaled(canvas, concept, size, size * circle / diagonal);
  }

  return recorder.endRecording().toImage(size.round(), size.round());
}

/// 把 [bounds] 按最长边缩放到 [limit]。
double _fitLongestSide(Rect bounds, double limit) =>
    limit / math.max(bounds.width, bounds.height);

/// 缩放到 [scale] 并居中，然后在设计坐标里画图形。
void _paintGlyphScaled(
  Canvas canvas,
  IconConcept concept,
  double size,
  double scale,
) {
  canvas.save();
  canvas.translate(size / 2, size / 2);
  canvas.scale(scale * size / iconDesign);
  // 所有图形都画在设计坐标的中心，所以把设计中心对到画布中心即可。
  canvas.translate(-iconDesign / 2, -iconDesign / 2);
  _paintGlyph(canvas, concept);
  canvas.restore();
}

void _paintGlyph(Canvas canvas, IconConcept concept) {
  switch (concept) {
    case IconConcept.stacked:
      _paintStackedCards(canvas);
    case IconConcept.openBook:
      _paintOpenBook(canvas);
    case IconConcept.eye:
      _paintEye(canvas);
  }
}

// --- 图形 ------------------------------------------------------------------

const double _cardW = 380;
const double _cardH = _cardW / 0.7;

/// 层叠封面的包围盒：正面卡 + 两次左上错位。
final Rect _stackedBounds = () {
  final front = _stackedFront;
  return front.expandToInclude(front.shift(const Offset(-116, -88)));
}();

Rect get _stackedFront => Rect.fromLTWH(
      iconDesign / 2 - _cardW / 2 + 52,
      iconDesign / 2 - _cardH / 2 + 34,
      _cardW,
      _cardH,
    );

/// A：三张封面卡往左上错位叠放，正面那张是 2×2 的封面格。
///
/// 卡片比例用 **0.70**，与详情页封面的 `AspectRatio(0.7)` 一致——图标和界面里看到的
/// 封面是同一种形状。
void _paintStackedCards(Canvas canvas) {
  final front = _stackedFront;
  _card(canvas, front.shift(const Offset(-116, -88)), iconTealDark);
  _card(canvas, front.shift(const Offset(-58, -44)), iconTealLight);
  _card(canvas, front, iconPaperBright);
  _grid(
    canvas,
    front.deflate(_cardW * 0.15),
    color: iconTeal,
    gap: _cardW * 0.055,
    radius: _cardW * 0.048,
  );
}

const double _pageW = 292;
const double _pageH = 408;
const double _pageTilt = 0.10;

final Rect _openBookBounds = () {
  // 倾斜后的包围盒：宽 = 2*页宽*cos + 页高*sin，高 = 页高*cos + 页宽*sin。
  final cos = math.cos(_pageTilt);
  final sin = math.sin(_pageTilt);
  final width = _pageW * 2 * cos - 16 + _pageH * sin;
  final height = _pageH * cos + _pageW * sin;
  return Rect.fromCenter(
    center: const Offset(iconDesign / 2, iconDesign / 2),
    width: width,
    height: height,
  );
}();

/// B：两页微微张开，像一本摊开的书；每页放一格格封面。
void _paintOpenBook(Canvas canvas) {
  for (final side in const [-1.0, 1.0]) {
    canvas.save();
    canvas.translate(iconDesign / 2 + side * (_pageW / 2 - 8), iconDesign / 2);
    canvas.rotate(side * _pageTilt);
    final page = Rect.fromCenter(
      center: Offset.zero,
      width: _pageW,
      height: _pageH,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(page, const Radius.circular(26)),
      Paint()..color = iconPaperBright,
    );
    _grid(canvas, page.deflate(40), color: iconTeal, gap: 20, radius: 16);
    canvas.restore();
  }
}

const double _eyeHalfWidth = 356;
const double _eyeHalfHeight = 208;
const double _pupil = 198;

/// 三次贝塞尔「透镜」形的实际高度是控制点高度的 0.75 倍（B(0.5) = 3h/4）。
final Rect _eyeBounds = Rect.fromCenter(
  center: const Offset(iconDesign / 2, iconDesign / 2),
  width: _eyeHalfWidth * 2,
  height: _eyeHalfHeight * 2 * 0.75,
);

/// C：眼睛（viewer 的字面意义），瞳孔是 2×2 封面格（库的字面意义）。
void _paintEye(Canvas canvas) {
  const cx = iconDesign / 2;
  const cy = iconDesign / 2;
  final eye = Path()
    ..moveTo(cx - _eyeHalfWidth, cy)
    ..cubicTo(
      cx - _eyeHalfWidth * 0.42,
      cy - _eyeHalfHeight,
      cx + _eyeHalfWidth * 0.42,
      cy - _eyeHalfHeight,
      cx + _eyeHalfWidth,
      cy,
    )
    ..cubicTo(
      cx + _eyeHalfWidth * 0.42,
      cy + _eyeHalfHeight,
      cx - _eyeHalfWidth * 0.42,
      cy + _eyeHalfHeight,
      cx - _eyeHalfWidth,
      cy,
    )
    ..close();

  canvas.drawPath(eye, Paint()..color = iconPaperBright);
  _grid(
    canvas,
    Rect.fromCenter(
      center: const Offset(cx, cy),
      width: _pupil,
      height: _pupil,
    ),
    color: iconTeal,
    gap: 18,
    radius: 18,
  );
}

void _card(Canvas canvas, Rect rect, Color color) {
  canvas.drawRRect(
    RRect.fromRectAndRadius(rect, Radius.circular(rect.width * 0.12)),
    Paint()..color = color,
  );
}

/// 2×2 的封面格：远看是纹理，放大才看出是「一格格封面」。
void _grid(
  Canvas canvas,
  Rect area, {
  required Color color,
  required double gap,
  required double radius,
}) {
  const cols = 2;
  const rows = 2;
  final cellW = (area.width - gap * (cols - 1)) / cols;
  final cellH = (area.height - gap * (rows - 1)) / rows;
  final paint = Paint()..color = color;
  for (var row = 0; row < rows; row++) {
    for (var col = 0; col < cols; col++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            area.left + col * (cellW + gap),
            area.top + row * (cellH + gap),
            cellW,
            cellH,
          ),
          Radius.circular(radius),
        ),
        paint,
      );
    }
  }
}

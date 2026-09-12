/// 编译期配置与全局设计 token。
library;

/// 编译期配置。
///
/// 服务器地址在这里只是**默认值**：运行时可在设置页修改并持久化（见
/// `core/service/server_address.dart`）。默认指向回环地址而不是占位域名是有
/// 意的——忘了配 `--dart-define` 时会立刻可见地失败，而不是悄悄连到别人的
/// 服务器上。
abstract final class AppConfig {
  /// 服务器地址的编译期默认值，末尾不带 `/`。
  static const String defaultBaseUrl = String.fromEnvironment(
    'EHW_BASE_URL',
    defaultValue: 'http://127.0.0.1:8080',
  );

  /// 图库列表的分页大小。
  static const int pageSize = 60;

  /// 阅读器在当前页两侧各预热多少页。
  ///
  /// 两页足够让正常翻页感觉是瞬时的，又不会把十几张全尺寸图片握在内存里
  /// ——那正是阅读器在手机上被 OOM 杀掉的原因。
  static const int readerPreloadRadius = 2;

  /// 向服务端请求的封面缩略图宽度，逻辑像素。
  ///
  /// 只用于决定布局尺寸；真实像素大小由服务端 `thumb.max_dim` 决定。
  static const double coverExtent = 160;

  static bool get isWeb => const bool.fromEnvironment('dart.library.js_util');
}

/// 统一间距刻度。
///
/// forui 只提供组件高度（`context.theme.style.sizes`）与页面留白
/// （`context.theme.style.pagePadding`），没有通用间距刻度。规范禁止就地写
/// `SizedBox(height: 13)` 这类裸数字，所以间距一律走这里；组件自带的 padding
/// 优先，确实需要额外间距时才用它。
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// 统一圆角刻度。
///
/// 与 `context.theme.style.borderRadius` 一致，供没有 forui 组件包裹的容器
/// 使用（例如错误面板、空状态卡片）。
abstract final class AppRadius {
  static const double sm = 6;
  static const double md = 10;
  static const double lg = 14;
}

/// 统一图标尺寸刻度。
///
/// forui 的 `style.sizes` 是**组件高度**（field/item/tile），拿它当图标尺寸
/// 语义是错位的——48 像素高的按钮不等于 48 像素的图标。
abstract final class AppIcon {
  /// 按钮内联图标。
  static const double sm = 16;

  /// 列表项、工具条图标。
  static const double md = 24;

  /// 空状态、错误状态的主图标。
  static const double lg = 40;

  /// 首屏插画级图标。
  static const double xl = 56;
}

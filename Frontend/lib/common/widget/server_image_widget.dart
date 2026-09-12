import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../config/app_config.dart';
import '../../core/service/dio_provider.dart';
import '../../core/util/result_util.dart';

/// 需要会话才能取到的服务端图片。
///
/// `Image.network` 带不了 `Authorization`，虽然服务端也认会话 cookie（Web 上
/// 浏览器会自动带），但本端没有 cookie jar。把每张图都交给 Dio 走一遍，
/// 用一个实现把这个缺口补上。
class ServerImage extends ConsumerStatefulWidget {
  const ServerImage({
    super.key,
    required this.path,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorBuilder,
    this.width,
    this.height,
    this.semanticLabel,
  });

  /// 服务端相对路径（`/thumb/1234567?v=1`）或绝对 URL。
  ///
  /// 两者都接受，免得已经解析好 URL 的调用方还要反解析回来。
  final String path;

  final BoxFit fit;
  final Widget? placeholder;
  final Widget Function(BuildContext context, Object error)? errorBuilder;
  final double? width;
  final double? height;
  final String? semanticLabel;

  @override
  ConsumerState<ServerImage> createState() => _ServerImageState();
}

class _ServerImageState extends ConsumerState<ServerImage> {
  Future<Result<Uint8List>>? _future;
  String? _forUrl;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ServerImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _load();
  }

  void _load() {
    if (widget.path.isEmpty) {
      _future = null;
      _forUrl = null;
      return;
    }
    final api = ref.read(apiClientProvider);
    final url = api.resolve(widget.path);
    if (url == _forUrl) return;
    _forUrl = url;
    _future = api.getBytes(url);
  }

  @override
  Widget build(BuildContext context) {
    final future = _future;
    if (widget.path.isEmpty || future == null) {
      return _buildError(context, '没有可用的图片');
    }
    return FutureBuilder<Result<Uint8List>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return widget.placeholder ?? const _ImagePlaceholder();
        }
        final result = snapshot.data;
        if (result == null || result.isError) {
          return _buildError(context, result?.error ?? '图片加载失败');
        }
        final bytes = result.data;
        if (bytes == null || bytes.isEmpty) {
          return _buildError(context, '图片内容为空');
        }
        return Image.memory(
          bytes,
          fit: widget.fit,
          width: widget.width,
          height: widget.height,
          gaplessPlayback: true,
          semanticLabel: widget.semanticLabel,
          // 这里解码失败说明拿到的字节不是当前平台能渲染的图片，值得说出来而
          // 不是显示一个破图标。
          errorBuilder: (context, error, stack) => _buildError(context, error),
        );
      },
    );
  }

  Widget _buildError(BuildContext context, Object error) {
    final builder = widget.errorBuilder;
    if (builder != null) return builder(context, error);
    return const _ImagePlaceholder(icon: FLucideIcons.imageOff);
  }
}

class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({this.icon = FLucideIcons.image});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 占位图不能给网格单元强加无限尺寸；图标随格子缩放但夹在 token 区间内，
        // 免得小格子里挤成一团、大格子里夸张地占满。
        final size = constraints.biggest.shortestSide;
        return ColoredBox(
          color: theme.colors.muted,
          child: Center(
            child: Icon(
              icon,
              size: size.isFinite
                  ? (size * 0.35).clamp(AppIcon.sm, AppIcon.lg).toDouble()
                  : AppIcon.md,
              color: theme.colors.mutedForeground,
            ),
          ),
        );
      },
    );
  }
}

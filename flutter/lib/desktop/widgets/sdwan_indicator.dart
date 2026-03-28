/// SD-WAN 链路质量指示器 Widget
///
/// 在远程桌面会话的右上角（Quality Monitor 下方）显示当前 SD-WAN
/// 链路状态信息，包括链路类型、延迟和丢包率。
///
/// 依赖关系：
///   - RAWNE 后端 `sdwan_service.rs`（通过 FFI bridge，目前 TODO 占位）
///
/// 使用方式：
///   在 `remote_page.dart` 的 `getBodyForDesktop()` 中添加：
///   ```dart
///   Positioned(
///     top: 46, right: 10,
///     child: SdWanIndicator(ffi: _ffi),
///   )
///   ```

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../models/model.dart';

// ============================================================================
// 常量定义
// ============================================================================

/// SD-WAN 链路类型枚举
enum SdWanLinkType {
  /// 点对点直连 (P2P)
  direct,

  /// 中继服务器转发
  relay,

  /// SD-WAN 智能优选路由
  sdwan,

  /// 未知/未连接
  unknown,
}

/// 延迟阈值 — 用于颜色编码
const int kLatencyGoodMs = 50;
const int kLatencyWarningMs = 100;

/// 指示器轮询间隔（毫秒）
const int kSdWanPollIntervalMs = 3000;

// ============================================================================
// SD-WAN 链路数据模型
// ============================================================================

/// SD-WAN 链路状态数据
class SdWanLinkStatus {
  /// 链路类型
  final SdWanLinkType linkType;

  /// 端到端延迟（毫秒）
  final int latencyMs;

  /// 丢包率（0.0 ~ 1.0）
  final double packetLoss;

  /// 当前路由路径描述（例如 "直连" / "北京BGP → 上海CN2"）
  final String routePath;

  /// 可用备选链路数量
  final int availableRoutes;

  const SdWanLinkStatus({
    this.linkType = SdWanLinkType.unknown,
    this.latencyMs = 0,
    this.packetLoss = 0.0,
    this.routePath = '',
    this.availableRoutes = 0,
  });

  /// 根据延迟值返回状态颜色
  Color get latencyColor {
    if (latencyMs < kLatencyGoodMs) return Colors.green;
    if (latencyMs < kLatencyWarningMs) return Colors.orange;
    return Colors.red;
  }

  /// 链路类型的显示文本
  String get linkTypeLabel {
    switch (linkType) {
      case SdWanLinkType.direct:
        return translate('Direct P2P');
      case SdWanLinkType.relay:
        return translate('Relay');
      case SdWanLinkType.sdwan:
        return translate('SD-WAN Optimized');
      case SdWanLinkType.unknown:
        return translate('Unknown');
    }
  }

  /// 链路类型的图标
  IconData get linkTypeIcon {
    switch (linkType) {
      case SdWanLinkType.direct:
        return Icons.swap_horiz;
      case SdWanLinkType.relay:
        return Icons.cloud_outlined;
      case SdWanLinkType.sdwan:
        return Icons.hub;
      case SdWanLinkType.unknown:
        return Icons.help_outline;
    }
  }
}

// ============================================================================
// SD-WAN 链路质量指示器 Widget
// ============================================================================

/// SD-WAN 链路质量指示器
///
/// 在远程会话画面右上角显示一个小型浮窗，包含：
/// - 链路类型图标（直连/中继/SD-WAN）
/// - 延迟数值（带颜色编码）
/// - 丢包率
///
/// 点击可展开详细面板，显示路由路径和可选链路列表。
class SdWanIndicator extends StatefulWidget {
  final FFI ffi;

  const SdWanIndicator({Key? key, required this.ffi}) : super(key: key);

  @override
  State<SdWanIndicator> createState() => _SdWanIndicatorState();
}

class _SdWanIndicatorState extends State<SdWanIndicator>
    with SingleTickerProviderStateMixin {
  /// 当前链路状态（响应式）
  final Rx<SdWanLinkStatus> _linkStatus = const SdWanLinkStatus().obs;

  /// 是否已展开详情面板
  final RxBool _isExpanded = false.obs;

  /// 定时轮询 Timer
  Timer? _pollTimer;

  /// 展开/收起动画控制器
  late AnimationController _expandController;
  late Animation<double> _expandAnimation;

  @override
  void initState() {
    super.initState();

    // 展开动画控制器
    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _expandAnimation = CurvedAnimation(
      parent: _expandController,
      curve: Curves.easeOutCubic,
    );

    // 启动轮询
    _pollLinkStatus();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: kSdWanPollIntervalMs),
      (_) => _pollLinkStatus(),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _expandController.dispose();
    super.dispose();
  }

  /// 轮询链路状态
  void _pollLinkStatus() {
    // TODO(RAWNE): 通过 FFI bridge 从 sdwan_service 获取实时链路状态
    // 目前使用模拟数据展示 UI 效果
    // final status = bind.sessionGetSdWanStatus(sessionId: widget.ffi.sessionId);

    // 模拟数据 — 仅用于 UI 开发验证
    _linkStatus.value = const SdWanLinkStatus(
      linkType: SdWanLinkType.sdwan,
      latencyMs: 28,
      packetLoss: 0.001,
      routePath: 'SD-WAN Optimized Route',
      availableRoutes: 3,
    );
  }

  /// 切换展开/收起
  void _toggleExpanded() {
    _isExpanded.value = !_isExpanded.value;
    if (_isExpanded.value) {
      _expandController.forward();
    } else {
      _expandController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final status = _linkStatus.value;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ---- 紧凑指示器（始终可见）----
          _buildCompactIndicator(status),

          // ---- 展开的详情面板 ----
          SizeTransition(
            sizeFactor: _expandAnimation,
            axisAlignment: -1.0,
            child: _buildDetailPanel(status),
          ),
        ],
      );
    });
  }

  /// 紧凑指示器 — 一行显示核心信息
  Widget _buildCompactIndicator(SdWanLinkStatus status) {
    return GestureDetector(
      onTap: _toggleExpanded,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.6),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: status.latencyColor.withOpacity(0.5),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 链路类型图标
            Icon(
              status.linkTypeIcon,
              size: 12,
              color: status.latencyColor,
            ),
            const SizedBox(width: 4),

            // 延迟数值
            Text(
              '${status.latencyMs}ms',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: status.latencyColor,
                fontFamily: 'monospace',
              ),
            ),

            // 丢包率（仅当丢包 > 0 时显示）
            if (status.packetLoss > 0) ...[
              const SizedBox(width: 6),
              Text(
                '${(status.packetLoss * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 10,
                  color: status.packetLoss > 0.01
                      ? Colors.red[300]
                      : Colors.grey[400],
                  fontFamily: 'monospace',
                ),
              ),
            ],

            // 展开/收起箭头
            const SizedBox(width: 2),
            Obx(() => Icon(
                  _isExpanded.value
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 12,
                  color: Colors.grey[400],
                )),
          ],
        ),
      ),
    );
  }

  /// 详情面板 — 展开后显示完整路由信息
  Widget _buildDetailPanel(SdWanLinkStatus status) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(10),
      constraints: const BoxConstraints(maxWidth: 220),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.75),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.white.withOpacity(0.1),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏
          Row(
            children: [
              Icon(Icons.hub, size: 14, color: Colors.blue[300]),
              const SizedBox(width: 6),
              Text(
                'SD-WAN',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.blue[300],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // 链路类型
          _buildDetailRow(
            translate('Link Type'),
            status.linkTypeLabel,
            status.latencyColor,
          ),
          const SizedBox(height: 4),

          // 延迟
          _buildDetailRow(
            translate('Latency'),
            '${status.latencyMs} ms',
            status.latencyColor,
          ),
          const SizedBox(height: 4),

          // 丢包率
          _buildDetailRow(
            translate('Packet Loss'),
            '${(status.packetLoss * 100).toStringAsFixed(2)}%',
            status.packetLoss > 0.01 ? Colors.red : Colors.green,
          ),
          const SizedBox(height: 4),

          // 路由路径
          if (status.routePath.isNotEmpty) ...[
            _buildDetailRow(
              translate('Route'),
              status.routePath,
              Colors.grey[300]!,
            ),
            const SizedBox(height: 4),
          ],

          // 可用路由数
          _buildDetailRow(
            translate('Available Routes'),
            '${status.availableRoutes}',
            Colors.grey[300]!,
          ),
        ],
      ),
    );
  }

  /// 详情面板的单行信息
  Widget _buildDetailRow(String label, String value, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
        ),
        Flexible(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: valueColor,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// SVD (Smart Virtual Display) 超级屏菜单构建模块
///
/// 本模块为 RAWNE V2 引擎的 SVD 功能提供 Flutter UI 菜单入口，
/// 包括超级屏模式开关、分辨率增强、高刷支持和 HDR 模式控制。
///
/// 依赖关系：
///   - 现有的 `toolbar.dart` 菜单组件（CkbMenuButton, MenuButton 等）
///   - RAWNE 后端 `svd_service.rs`（通过 FFI bridge 调用，目前为 TODO 占位）
///
/// 使用方式：
///   在 `remote_toolbar.dart` 的 `_DisplayMenuState` 中调用
///   `showSvdMenu()` 判断可见性，`getSvdMenuChildren()` 获取菜单项列表。

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../models/model.dart';

// ============================================================================
// 常量定义 — SVD 超级屏模式参数
// ============================================================================

/// SVD 超级屏可选分辨率预设
const kSvdResolutionAuto = 'auto';
const kSvdResolution4K = '3840x2160';
const kSvdResolution2K = '2560x1440';
const kSvdResolution1080P = '1920x1080';

/// SVD 超级屏可选刷新率预设（单位：Hz）
const kSvdRefreshRate60 = 60;
const kSvdRefreshRate120 = 120;
const kSvdRefreshRate144 = 144;

/// SVD 超级屏选项键名（用于 session option 存取）
const kOptionSvdEnabled = 'svd-super-screen-enabled';
const kOptionSvdResolution = 'svd-resolution';
const kOptionSvdRefreshRate = 'svd-refresh-rate';
const kOptionSvdHdrEnabled = 'svd-hdr-enabled';
const kOptionSvdWatermarkEnabled = 'svd-watermark-enabled';
const kOptionSvdAntiScreenshot = 'svd-anti-screenshot';

// ============================================================================
// SVD 菜单可见性判断
// ============================================================================

/// 判断当前远程会话是否应该展示 SVD 超级屏菜单
///
/// 条件：
///   1. 远端为 Windows 平台（SVD 依赖 IddCx 驱动）
///   2. 远端已安装 RustDesk 服务
///   3. 连接类型为默认连接（非文件传输/端口转发）
///
/// 返回 true 时在 Display 菜单中渲染超级屏子菜单
bool showSvdMenu(FFI ffi) {
  final pi = ffi.ffiModel.pi;

  // SVD 超级屏仅支持 Windows 远端（IddCx 虚拟显示驱动）
  if (pi.platform != kPeerPlatformWindows) {
    return false;
  }

  // 远端必须已安装 RustDesk 服务（非临时连接）
  if (!pi.isInstalled) {
    return false;
  }

  // 必须为默认连接类型
  if (ffi.connType != ConnType.defaultConn) {
    return false;
  }

  return true;
}

// ============================================================================
// SVD 超级屏菜单项构建
// ============================================================================

/// 构建 SVD 超级屏菜单的所有子项
///
/// 参数：
///   [ffi] — 当前会话的 FFI 实例
///   [id] — 远端 Peer ID
///   [setState] — 用于触发父组件重建的回调（可为 null）
///
/// 返回菜单 Widget 列表，可直接嵌入 `_SubmenuButton.menuChildren`
List<Widget> getSvdMenuChildren(FFI ffi, String id, VoidCallback? setState) {
  final children = <Widget>[];

  // ------ 1. 超级屏模式总开关 ------
  children.add(_buildSvdToggle(ffi, id));
  children.add(const Divider());

  // ------ 2. 分辨率增强子菜单 ------
  children.add(_buildResolutionSubmenu(ffi));
  children.add(const Divider());

  // ------ 3. 高刷支持子菜单 ------
  children.add(_buildRefreshRateSubmenu(ffi));
  children.add(const Divider());

  // ------ 4. HDR 模式开关 ------
  children.add(_buildHdrToggle(ffi));

  return children;
}

// ============================================================================
// 隐私屏增强菜单项
// ============================================================================

/// 构建隐私屏增强选项列表（屏幕水印 + 防截屏）
///
/// 这些选项追加到现有 Privacy Mode 开关之后，
/// 提供更细粒度的隐私保护控制。
///
/// 返回值：Widget 列表，可通过 `menuChildren.addAll()` 插入
List<Widget> getSvdPrivacyEnhancedOptions(FFI ffi, String id) {
  final children = <Widget>[];

  // ------ 屏幕水印 ------
  children.add(_buildWatermarkToggle(ffi));

  // ------ 防截屏 ------
  children.add(_buildAntiScreenshotToggle(ffi));

  return children;
}

// ============================================================================
// 内部构建函数
// ============================================================================

/// 超级屏模式总开关
Widget _buildSvdToggle(FFI ffi, String id) {
  // 使用 Obx 实现响应式 UI
  final isEnabled = false.obs;

  // TODO(RAWNE): 从 FFI bridge 获取当前超级屏状态
  // isEnabled.value = bind.sessionGetToggleOptionSync(
  //     sessionId: ffi.sessionId, arg: kOptionSvdEnabled);

  return Obx(() => CheckboxListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Row(
          children: [
            const Icon(Icons.desktop_windows, size: 16),
            const SizedBox(width: 8),
            Text(
              translate('Super Screen Mode'),
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
        subtitle: Text(
          translate('Enhanced virtual display with high resolution and refresh rate'),
          style: TextStyle(fontSize: 11, color: Colors.grey[600]),
        ),
        value: isEnabled.value,
        onChanged: (value) {
          if (value == null) return;
          isEnabled.value = value;
          // TODO(RAWNE): 通过 FFI bridge 调用 svd_service 启用/禁用超级屏
          // bind.sessionToggleOption(
          //     sessionId: ffi.sessionId, value: kOptionSvdEnabled);
        },
      ));
}

/// 分辨率增强子菜单
Widget _buildResolutionSubmenu(FFI ffi) {
  final currentResolution = kSvdResolutionAuto.obs;

  // TODO(RAWNE): 从 FFI bridge 读取当前分辨率设定
  // currentResolution.value = bind.sessionGetOption(
  //     sessionId: ffi.sessionId, arg: kOptionSvdResolution) ?? kSvdResolutionAuto;

  final resolutions = [
    _SvdResolutionOption(kSvdResolutionAuto, translate('Auto Match'), Icons.auto_awesome),
    _SvdResolutionOption(kSvdResolution4K, '4K (3840×2160)', Icons.tv),
    _SvdResolutionOption(kSvdResolution2K, '2K (2560×1440)', Icons.monitor),
    _SvdResolutionOption(kSvdResolution1080P, '1080P (1920×1080)', Icons.laptop),
  ];

  return Obx(() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              translate('Resolution Enhancement'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey[500],
              ),
            ),
          ),
          ...resolutions.map((option) => RadioListTile<String>(
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                title: Row(
                  children: [
                    Icon(option.icon, size: 14),
                    const SizedBox(width: 6),
                    Text(option.label, style: const TextStyle(fontSize: 13)),
                  ],
                ),
                value: option.value,
                groupValue: currentResolution.value,
                onChanged: (value) {
                  if (value == null) return;
                  currentResolution.value = value;
                  // TODO(RAWNE): 通过 FFI bridge 设置分辨率
                  // bind.sessionSetOption(
                  //     sessionId: ffi.sessionId,
                  //     name: kOptionSvdResolution, value: value);
                },
              )),
        ],
      ));
}

/// 高刷支持子菜单
Widget _buildRefreshRateSubmenu(FFI ffi) {
  final currentRate = kSvdRefreshRate60.obs;

  // TODO(RAWNE): 从 FFI bridge 读取当前刷新率
  // final rateStr = bind.sessionGetOption(
  //     sessionId: ffi.sessionId, arg: kOptionSvdRefreshRate) ?? '60';
  // currentRate.value = int.tryParse(rateStr) ?? kSvdRefreshRate60;

  final rates = [
    _SvdRefreshRateOption(kSvdRefreshRate60, '60 Hz', '标准'),
    _SvdRefreshRateOption(kSvdRefreshRate120, '120 Hz', '高刷'),
    _SvdRefreshRateOption(kSvdRefreshRate144, '144 Hz', '电竞'),
  ];

  return Obx(() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              translate('Refresh Rate'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey[500],
              ),
            ),
          ),
          ...rates.map((option) => RadioListTile<int>(
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                title: Row(
                  children: [
                    Text(option.label, style: const TextStyle(fontSize: 13)),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: option.rate >= 120
                            ? Colors.green.withOpacity(0.15)
                            : Colors.grey.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        option.tag,
                        style: TextStyle(
                          fontSize: 10,
                          color:
                              option.rate >= 120 ? Colors.green : Colors.grey,
                        ),
                      ),
                    ),
                  ],
                ),
                value: option.rate,
                groupValue: currentRate.value,
                onChanged: (value) {
                  if (value == null) return;
                  currentRate.value = value;
                  // TODO(RAWNE): 通过 FFI bridge 设置刷新率
                  // bind.sessionSetOption(
                  //     sessionId: ffi.sessionId,
                  //     name: kOptionSvdRefreshRate, value: value.toString());
                },
              )),
        ],
      ));
}

/// HDR 模式开关
Widget _buildHdrToggle(FFI ffi) {
  final isHdrEnabled = false.obs;

  // TODO(RAWNE): 从 FFI bridge 获取 HDR 状态
  // isHdrEnabled.value = bind.sessionGetToggleOptionSync(
  //     sessionId: ffi.sessionId, arg: kOptionSvdHdrEnabled);

  return Obx(() => CheckboxListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Row(
          children: [
            Icon(Icons.hdr_on, size: 16, color: isHdrEnabled.value ? Colors.amber : null),
            const SizedBox(width: 8),
            Text(
              translate('HDR Mode'),
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
        value: isHdrEnabled.value,
        onChanged: (value) {
          if (value == null) return;
          isHdrEnabled.value = value;
          // TODO(RAWNE): 通过 FFI bridge 切换 HDR
          // bind.sessionToggleOption(
          //     sessionId: ffi.sessionId, value: kOptionSvdHdrEnabled);
        },
      ));
}

/// 屏幕水印开关
Widget _buildWatermarkToggle(FFI ffi) {
  final isEnabled = false.obs;

  return Obx(() => CheckboxListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Row(
          children: [
            const Icon(Icons.branding_watermark, size: 16),
            const SizedBox(width: 8),
            Text(
              translate('Screen Watermark'),
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
        subtitle: Text(
          translate('Overlay transparent watermark on remote display'),
          style: TextStyle(fontSize: 11, color: Colors.grey[600]),
        ),
        value: isEnabled.value,
        onChanged: (value) {
          if (value == null) return;
          isEnabled.value = value;
          // TODO(RAWNE): 通过 FFI bridge 启用水印
          // bind.sessionToggleOption(
          //     sessionId: ffi.sessionId, value: kOptionSvdWatermarkEnabled);
        },
      ));
}

/// 防截屏开关
Widget _buildAntiScreenshotToggle(FFI ffi) {
  final isEnabled = false.obs;

  return Obx(() => CheckboxListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Row(
          children: [
            const Icon(Icons.screen_lock_portrait, size: 16),
            const SizedBox(width: 8),
            Text(
              translate('Anti-Screenshot'),
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
        subtitle: Text(
          translate('Prevent remote screenshot capture'),
          style: TextStyle(fontSize: 11, color: Colors.grey[600]),
        ),
        value: isEnabled.value,
        onChanged: (value) {
          if (value == null) return;
          isEnabled.value = value;
          // TODO(RAWNE): 通过 FFI bridge 启用防截屏
          // bind.sessionToggleOption(
          //     sessionId: ffi.sessionId, value: kOptionSvdAntiScreenshot);
        },
      ));
}

// ============================================================================
// 辅助数据类
// ============================================================================

/// 分辨率选项数据类
class _SvdResolutionOption {
  final String value;
  final String label;
  final IconData icon;

  const _SvdResolutionOption(this.value, this.label, this.icon);
}

/// 刷新率选项数据类
class _SvdRefreshRateOption {
  final int rate;
  final String label;
  final String tag;

  const _SvdRefreshRateOption(this.rate, this.label, this.tag);
}

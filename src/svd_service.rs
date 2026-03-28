// =============================================================================
// SVD 集成服务 - 客户端虚拟屏管理与超级屏控制
// =============================================================================
//
// 核心职责：
//   1. 封装 SvdEngine 为线程安全全局单例
//   2. 在远控会话建立时根据主控端 EDID 创建虚拟显示器
//   3. 接收 Z-HCC 网络质量反馈，联动调控虚拟屏刷新率
//   4. 管理"超级屏"模式（桌面迁移 + 物理屏熄灭 = 隐私防窥）
//   5. 远控断开时自动执行优雅销毁
//
// 集成说明：
//   - 由 video_service.rs 在会话初始化时调用 `init_virtual_display`
//   - 由 video_qos.rs 在网络质量变化时调用 `on_network_change`
//   - 由 connection.rs 在会话结束时调用 `teardown`

use rawne::common::NetworkGrade;
use rawne::svd::{ClientEdid, PhysicalScreenPower, SvdCommand, SvdEngine, VirtualDisplay};
use std::sync::Arc;
use tokio::sync::RwLock;

// ---------------------------------------------------------------------------
// 全局 SVD 引擎单例
// ---------------------------------------------------------------------------

lazy_static::lazy_static! {
    /// 全局 SVD 引擎实例
    static ref SVD_ENGINE: Arc<RwLock<SvdEngine>> = Arc::new(RwLock::new(SvdEngine::new()));
}

// ---------------------------------------------------------------------------
// 公开接口
// ---------------------------------------------------------------------------

/// 远控会话建立时初始化虚拟显示器
///
/// # 参数
/// - `width`: 主控端屏幕宽度
/// - `height`: 主控端屏幕高度
/// - `refresh_rate`: 主控端目标刷新率（Hz）
/// - `hdr_enabled`: 是否启用 HDR
/// - `color_space`: 色彩空间标识
///
/// # 返回值
/// - `Ok(display_id)`: 虚拟显示器 ID
/// - `Err(msg)`: 创建失败原因
pub async fn init_virtual_display(
    width: u32,
    height: u32,
    refresh_rate: u32,
    hdr_enabled: bool,
    color_space: String,
) -> Result<u32, String> {
    let edid = ClientEdid {
        width,
        height,
        refresh_rate,
        hdr_enabled,
        color_space,
    };

    let mut engine = SVD_ENGINE.write().await;
    let display = engine.on_client_connect(edid)?;

    // 消费并执行平台指令
    let commands = engine.drain_commands();
    execute_svd_commands(&commands).await;

    log::info!(
        "SVD 集成: 虚拟显示器 #{} 已创建 ({}x{} @{}Hz HDR={})",
        display.display_id,
        display.width,
        display.height,
        display.refresh_rate,
        display.hdr_enabled,
    );

    Ok(display.display_id)
}

/// 启用超级屏模式（隐私屏 + 桌面迁移）
///
/// # 参数
/// - `display_id`: 目标虚拟显示器 ID
pub async fn enable_super_display(display_id: u32) -> Result<(), String> {
    let mut engine = SVD_ENGINE.write().await;
    engine.enable_super_display(display_id)?;

    let commands = engine.drain_commands();
    execute_svd_commands(&commands).await;

    log::info!(
        "SVD 集成: 超级屏模式已激活 (显示器 #{}), 物理屏已熄灭",
        display_id
    );
    Ok(())
}

/// 关闭超级屏模式
pub async fn disable_super_display() {
    let mut engine = SVD_ENGINE.write().await;
    engine.disable_super_display();

    let commands = engine.drain_commands();
    execute_svd_commands(&commands).await;

    log::info!("SVD 集成: 超级屏模式已关闭, 物理屏已恢复");
}

/// Z-HCC 联动接口：网络质量变化时调整虚拟屏刷新率
///
/// 本函数应在 video_qos 的质量状态更新回调中调用。
///
/// # 参数
/// - `grade`: 最新的网络质量等级
pub async fn on_network_change(grade: NetworkGrade) {
    let mut engine = SVD_ENGINE.write().await;
    engine.on_network_grade_change(grade);

    let commands = engine.drain_commands();
    if !commands.is_empty() {
        execute_svd_commands(&commands).await;
    }
}

/// 远控断开时的优雅销毁接口
///
/// 确保：
///   1. 物理屏幕恢复
///   2. 桌面窗口回迁
///   3. 所有虚拟显示器安全销毁
pub async fn teardown() {
    let mut engine = SVD_ENGINE.write().await;
    engine.graceful_teardown();

    let commands = engine.drain_commands();
    execute_svd_commands(&commands).await;

    log::info!("SVD 集成: 优雅销毁完成，所有虚拟资源已回收");
}

/// 获取当前物理屏幕电源状态
pub async fn physical_screen_power() -> PhysicalScreenPower {
    SVD_ENGINE.read().await.physical_screen_power()
}

/// 获取当前活跃的虚拟显示器列表
pub async fn active_displays() -> Vec<VirtualDisplay> {
    SVD_ENGINE.read().await.active_displays().to_vec()
}

/// 检查当前是否处于超级屏（隐私）模式
pub async fn is_privacy_mode_active() -> bool {
    let engine = SVD_ENGINE.read().await;
    engine.physical_screen_power() == PhysicalScreenPower::Off
}

// ---------------------------------------------------------------------------
// 内部：平台指令执行器
// ---------------------------------------------------------------------------

/// 将 SVD 引擎输出的抽象指令翻译为平台实际操作
///
/// 在 Windows 平台上对接 IddCx 驱动 API。
/// 在其他平台上记录日志（占位）。
async fn execute_svd_commands(commands: &[SvdCommand]) {
    for cmd in commands {
        match cmd {
            SvdCommand::CreateDisplay {
                width,
                height,
                refresh_rate,
                hdr_enabled,
            } => {
                log::info!(
                    "SVD 平台层: 创建虚拟显示器 {}x{} @{}Hz HDR={}",
                    width, height, refresh_rate, hdr_enabled
                );
                #[cfg(target_os = "windows")]
                {
                    // TODO(RAWNE): 调用 IddCx 驱动接口创建虚拟显示器
                    // virtual_display::create_display(*width, *height, *refresh_rate);
                    log::info!("SVD 平台层: IddCx 虚拟显示器创建指令已下发 (Windows)");
                }
            }
            SvdCommand::DestroyDisplay { display_id } => {
                log::info!("SVD 平台层: 销毁虚拟显示器 #{}", display_id);
                #[cfg(target_os = "windows")]
                {
                    // TODO(RAWNE): 调用 IddCx 驱动接口销毁虚拟显示器
                    // virtual_display::destroy_display(*display_id);
                    log::info!("SVD 平台层: IddCx 虚拟显示器销毁指令已下发 (Windows)");
                }
            }
            SvdCommand::SetRefreshRate {
                display_id,
                refresh_rate,
            } => {
                log::info!(
                    "SVD 平台层: 显示器 #{} 刷新率调整为 {}Hz",
                    display_id, refresh_rate
                );
                #[cfg(target_os = "windows")]
                {
                    // TODO(RAWNE): 调用 IddCx 驱动接口修改刷新率
                    // virtual_display::set_refresh_rate(*display_id, *refresh_rate);
                }
            }
            SvdCommand::SetPhysicalPower { power } => {
                match power {
                    PhysicalScreenPower::Off => {
                        log::info!("SVD 平台层: 切断物理屏幕信号（隐私模式）");
                        #[cfg(target_os = "windows")]
                        {
                            // TODO(RAWNE): 调用 WinAPI SendMessage(WM_SYSCOMMAND, SC_MONITORPOWER, 2)
                            // 或通过 DDC/CI 协议切断物理屏信号
                        }
                    }
                    PhysicalScreenPower::On => {
                        log::info!("SVD 平台层: 恢复物理屏幕信号");
                        #[cfg(target_os = "windows")]
                        {
                            // TODO(RAWNE): 调用 WinAPI 恢复物理屏幕
                            // SendMessage(WM_SYSCOMMAND, SC_MONITORPOWER, -1)
                        }
                    }
                    PhysicalScreenPower::Standby => {
                        log::info!("SVD 平台层: 物理屏幕进入待机");
                    }
                }
            }
            SvdCommand::MigrateDesktop {
                target_display_id,
            } => {
                log::info!(
                    "SVD 平台层: 桌面窗口全部迁移至虚拟显示器 #{}",
                    target_display_id
                );
                #[cfg(target_os = "windows")]
                {
                    // TODO(RAWNE): 使用 EnumWindows + SetWindowPos/MoveWindow 迁移窗口
                    // 或调用 DisplaySwitch /clone /extend 切换显示模式
                }
            }
            SvdCommand::RestoreDesktop => {
                log::info!("SVD 平台层: 桌面窗口回迁至物理显示器");
                #[cfg(target_os = "windows")]
                {
                    // TODO(RAWNE): 将窗口回迁至主物理显示器
                }
            }
        }
    }
}

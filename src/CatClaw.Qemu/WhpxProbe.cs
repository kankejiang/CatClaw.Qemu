using System.Runtime.InteropServices;

namespace CatClaw.Qemu;

/// <summary>
/// WHPX（Windows Hypervisor Platform）可用性探测。
///
/// <para><b>为什么不用别的判据</b>：WHPX 用户态 API 由可选功能「Windows 虚拟机监控程序平台」
/// （HypervisorPlatform）提供——<c>WinHvPlatform.dll</c> + <c>winhvr.sys</c> 驱动。它与 Hyper-V
/// 完整功能、任务管理器的「虚拟化已启用」都不是一回事：本机 2026-09-29 实测 Hyper-V 全开、
/// HypervisorPresent=True，但 HypervisorPlatform 没开 → API DLL 整个不存在。最直接的判据就是
/// 调 <c>WHvGetCapability(WHvCapabilityCodeHypervisorPresent)</c>：API 在就返回 S_OK 且值=1；
/// DLL 缺失（功能没开）→ DllNotFoundException。与 QEMU <c>-accel whpx</c> 的运行时判定一致，
/// 且进程内一次探测零开销。</para>
/// <para>⚠ DLL 名是 <b>WinHvPlatform.dll</b>——系统里根本没有叫 whpx.dll 的文件；初版误写导致
/// 探测恒 false（2026-09-29 本机实锤后修正）。</para>
///
/// <para><b>结果进程内缓存</b>：平台功能开关注销才生效，运行中不会变；构造期调用一次即可。</para>
/// </summary>
public static class WhpxProbe
{
    private const uint WHvCapabilityCodeHypervisorPresent = 0x0;
    private static WhpxStatus? _cached;   // 进程内缓存：平台功能开关注销才生效

    [DllImport("WinHvPlatform.dll", SetLastError = false)]
    private static extern int WHvGetCapability(uint capabilityCode, out uint capabilityValue,
        uint capabilityValueSize, out uint writtenSize);

    /// <summary>WHPX 是否可用（进程内缓存）。</summary>
    public static bool IsAvailable() => Probe() == WhpxStatus.Available;

    /// <summary>
    /// 探测并给出**不可用的根因**——三种情况的处置办法完全不同：
    /// <list type="bullet">
    /// <item><see cref="WhpxStatus.FeatureMissing"/>：可选功能没开 → 开功能（DISM/optionalfeatures）即可。</item>
    /// <item><see cref="WhpxStatus.HypervisorNotRunning"/>：DLL 在但 hypervisor 没跑 → BIOS 里 VT-x/AMD-V
    /// 可能被关，或 hypervisorlaunchtype 被设成 off，开功能没用。</item>
    /// <item><see cref="WhpxStatus.Available"/>：可直接 <c>-accel whpx</c>。</item>
    /// </list>
    /// </summary>
    public static WhpxStatus Probe()
    {
        // 开发/排障钩子：环境变量 CATCLAW_WHPX=on|missing|norun 强制探测结果。
        // 用途：本机 WHPX 正常时，仍能预览「未启用」的界面与处置流程（含一键启用/详细步骤）。
        // 正常用户环境不会设置它，判定逻辑不受影响。
        if (Environment.GetEnvironmentVariable("CATCLAW_WHPX") is { Length: > 0 } forced)
        {
            _cached = forced.ToLowerInvariant() switch
            {
                "on" => WhpxStatus.Available,
                "missing" => WhpxStatus.FeatureMissing,
                _ => WhpxStatus.HypervisorNotRunning,
            };
            return _cached.Value;
        }

        if (_cached is { } v) return v;
        try
        {
            var hr = WHvGetCapability(WHvCapabilityCodeHypervisorPresent, out uint value,
                sizeof(uint), out uint written);
            _cached = hr == 0 && value == 1 && written == sizeof(uint)
                ? WhpxStatus.Available
                : WhpxStatus.HypervisorNotRunning;
        }
        catch (DllNotFoundException)
        {
            // 功能没开：WinHvPlatform.dll 整个不存在（系统里没有 whpx.dll 这个文件）
            _cached = WhpxStatus.FeatureMissing;
        }
        catch (EntryPointNotFoundException) { _cached = WhpxStatus.FeatureMissing; }
        catch (Exception) { _cached = WhpxStatus.HypervisorNotRunning; }
        return _cached.Value;
    }
}

/// <summary>WHPX 探测结果（决定给用户哪一套处置办法）。</summary>
public enum WhpxStatus
{
    /// <summary>功能在且 hypervisor 在跑，QEMU 可用 -accel whpx。</summary>
    Available,
    /// <summary>可选功能「虚拟机监控程序平台」没开（WinHvPlatform.dll 缺失）。</summary>
    FeatureMissing,
    /// <summary>功能已开但 hypervisor 未运行（BIOS 里虚拟化被关 / hypervisorlaunchtype=off 等）。</summary>
    HypervisorNotRunning,
}

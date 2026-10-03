namespace CatClaw.Qemu;

/// <summary>环境检测结果的严重级别。</summary>
public enum QemuEnvLevel
{
    /// <summary>通过。</summary>
    Ok,
    /// <summary>能跑但明显退化（例如只能回落 TCG 软件模拟）。</summary>
    Warn,
    /// <summary>缺失/不可用，相关能力整条失效。</summary>
    Fail,
    /// <summary>仅信息展示。</summary>
    Info,
}

/// <summary>一条环境检测结果（<paramref name="Hint"/> 非空时供 UI 直接展示处置建议）。</summary>
public sealed record QemuEnvItem(string Id, string Title, QemuEnvLevel Level, string Detail, string? Hint = null);

/// <summary>
/// 虚拟机套件运行环境探测：WHPX 加速、QEMU 引擎与 guest 镜像是否到位。
///
/// <para>套件不认识宿主 UI，只给出结构化结果；宿主（猫爪影视）在启动画面上渲染。
/// 全部为本地文件/进程内探测，无网络、无外部进程，毫秒级。</para>
/// </summary>
public static class QemuEnvCheck
{
    /// <summary>guest 运行时三件套（与 QemuArtGuest / JavaSpiderRuntime 的约定一致）。</summary>
    public const string QemuExeName = "qemu-system-x86_64.exe";
    public const string X86KernelName = "vmlinuz-6.1.0-50-amd64";
    public const string X86InitrdName = "art_initrd_x64.gz";

    /// <summary>
    /// 探测 <paramref name="runtimeDir"/>（= 宿主输出目录下的 QemuGuest/）与虚拟化能力。
    /// </summary>
    public static IReadOnlyList<QemuEnvItem> Probe(string runtimeDir)
    {
        var items = new List<QemuEnvItem>(3);

        // ① WHPX：有它才有硬件虚拟化，否则 QEMU 回落 TCG（指令级软件模拟，慢 10~20 倍）
        var whpx = WhpxProbe.IsAvailable();
        items.Add(whpx
            ? new QemuEnvItem("whpx", "虚拟化加速", QemuEnvLevel.Ok, "WHPX 可用（硬件虚拟化）")
            : new QemuEnvItem("whpx", "虚拟化加速", QemuEnvLevel.Warn,
                "未启用，引擎回落 TCG 软件模拟（慢 10~20 倍）",
                "启用 Windows 功能「虚拟机监控程序平台」(HypervisorPlatform) 后重启；" +
                "注意它与「任务管理器显示虚拟化已启用」「Hyper-V 全开」不是一回事"));

        // ② QEMU 引擎
        var exe = Path.Combine(runtimeDir, QemuExeName);
        var share = Path.Combine(runtimeDir, "share");
        items.Add(File.Exists(exe) && Directory.Exists(share)
            ? new QemuEnvItem("qemu", "QEMU 引擎", QemuEnvLevel.Ok, "qemu-system-x86_64 + BIOS 就绪")
            : new QemuEnvItem("qemu", "QEMU 引擎", QemuEnvLevel.Fail,
                "缺少 qemu-system-x86_64.exe 或 share/",
                "运行 tools/fetch-assets.ps1 取件（Release vm-assets-v1 的 qemu-guest-win64.zip），" +
                "或把该 zip 解到 输出目录\\QemuGuest\\"));

        // ③ ART guest 镜像（内核 + initrd）
        var kernel = Path.Combine(runtimeDir, "x86guest", X86KernelName);
        var initrd = Path.Combine(runtimeDir, "x86guest", X86InitrdName);
        var missing = new List<string>();
        if (!File.Exists(kernel)) missing.Add(X86KernelName);
        if (!File.Exists(initrd)) missing.Add(X86InitrdName);
        items.Add(missing.Count == 0
            ? new QemuEnvItem("guest", "ART 运行时镜像", QemuEnvLevel.Ok, "Debian 内核 + Android 13 initrd 就绪")
            : new QemuEnvItem("guest", "ART 运行时镜像", QemuEnvLevel.Fail,
                "x86guest 下缺少 " + string.Join("、", missing),
                "同样走 tools/fetch-assets.ps1；缺失时 jar 爬虫与磁力引擎判未就绪（磁力回落内置 BT）"));

        return items;
    }
}

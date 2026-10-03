namespace CatClaw.Qemu;

/// <summary>
/// 虚拟机套件的**路径注入点**。
///
/// <para>套件是独立仓库，不认识宿主应用（猫爪影视 / 猫爪音乐）的 <c>AppPaths</c>，
/// 因此由宿主在启动时把「持久数据根」和「本机数据根」注入进来；
/// 未注入时退回与猫爪影视一致的默认命名（%APPDATA%\{名} / %LOCALAPPDATA%\{名}）。</para>
///
/// <para>宿主示例：<c>QemuPaths.Configure(AppPaths.DataRoot, AppPaths.LocalRoot);</c>
/// —— Debug/Release 隔离由宿主的 AppPaths 决定，套件只照用。</para>
/// </summary>
public static class QemuPaths
{
    /// <summary>默认目录名（宿主未注入时使用）。</summary>
    public static string FolderName { get; set; } = "CatClawVideo";

    /// <summary>持久数据根（%APPDATA%\{名} 语义）：DB/缓存/块设备镜像等。</summary>
    public static string? DataRootOverride { get; set; }

    /// <summary>本机数据根（%LOCALAPPDATA%\{名} 语义）：QEMU 控制台日志等本机临时物。</summary>
    public static string? LocalRootOverride { get; set; }

    /// <summary>宿主注入两个根目录（幂等，可在启动时调用一次）。</summary>
    public static void Configure(string dataRoot, string localRoot)
    {
        DataRootOverride = dataRoot;
        LocalRootOverride = localRoot;
    }

    public static string DataRoot => DataRootOverride ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), FolderName);

    public static string LocalRoot => LocalRootOverride ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), FolderName);

    /// <summary>持久根下的文件路径（目录按需创建）。</summary>
    public static string Of(string fileName) => Path.Combine(Ensure(DataRoot), fileName);

    /// <summary>持久根下的子目录（或子目录里的文件）路径（目录按需创建）。</summary>
    public static string Sub(string subDir, string? fileName = null)
    {
        var dir = Ensure(Path.Combine(DataRoot, subDir));
        return fileName is null ? dir : Path.Combine(dir, fileName);
    }

    /// <summary>本机根下的文件路径（目录按需创建）。</summary>
    public static string LocalOf(string fileName) => Path.Combine(Ensure(LocalRoot), fileName);

    /// <summary>本机根下的子目录（或子目录里的文件）路径（目录按需创建）。</summary>
    public static string LocalSub(string subDir, string? fileName = null)
    {
        var dir = Ensure(Path.Combine(LocalRoot, subDir));
        return fileName is null ? dir : Path.Combine(dir, fileName);
    }

    private static string Ensure(string dir)
    {
        try { Directory.CreateDirectory(dir); } catch { /* 只读环境/权限不足时由调用方兜底 */ }
        return dir;
    }
}

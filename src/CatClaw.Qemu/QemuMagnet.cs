namespace CatClaw.Qemu;

/// <summary>
/// 磁力文件条目（种子内单个文件）。
///
/// <para><b>为什么库内另建 DTO</b>：宿主应用的 <c>IPreferredMagnetEngine</c> 用的是
/// <c>MagnetFile</c>/<c>MagnetPlayback</c>（应用自有类型）。库不能反向依赖应用，否则
/// 依赖方向颠倒（应用 → 库 → 应用）。故套件用自己的 DTO 对外，宿主侧用一个薄适配器
/// 映射到应用接口。</para>
/// </summary>
public sealed record QemuMagnetFile(int Index, long Size, string Name);

/// <summary>磁力播放结果：宿主拿它去起播本地流地址。</summary>
public sealed record QemuPlayback(string InfoHashHex, int FileIndex, long FileLength, string FileName, string Url);

# CatClaw.Qemu（猫爪影视·虚拟机套件）

猫爪影视（[CatClawVideo](https://github.com/kankejiang/CatClawVideo)）的**虚拟机套件**：把 TVBox 生态里"必须跑在真 Android + ARM native"的爬虫/壳/下载引擎，装进 QEMU 里的 ART guest。

三个仓库共同维护一个项目：

| 仓库 | 职责 |
|---|---|
| [CatClaw.Shared](https://github.com/kankejiang/CatClaw.Shared) | 猫爪家族共用基础库（与猫爪音乐共用） |
| [CatClawVideo](https://github.com/kankejiang/CatClawVideo) | 主程序（.NET MAUI 应用、播放器、片源聚合） |
| **CatClaw.Qemu**（本仓库） | 虚拟机套件：QEMU/ART guest 运行时 + 宿主侧引擎 + Java 桥与构建工具链 |

## 目录

| 路径 | 说明 |
|---|---|
| `src/CatClaw.Qemu/` | **宿主侧引擎类库**（C#，`net11.0`）：QEMU 进程管理、ART guest 桥、迅雷引擎控制、流代理、稀疏块设备、WHPX 探测、守卫解壳 VM |
| `guest/java/` | Java 桥源码（android stub + bridge server）与构建脚本（`build.cmd`） |
| `guest/qemu-src/` | guest 侧构建工具链：aarch64 迅雷 harness、x86 mini guest（`tools/x86guest`）、blobs |
| `tools/` | 打包/取件脚本（Release 附件）、b1 构建脚本、waydroid 推流 |
| `docs/` | 架构与联调文档（x86 mini guest、QEMU 调优、调试报告、N4 验收等） |

## 与主仓库的边界

- 主程序通过 `ProjectReference` 引用 `src/CatClaw.Qemu/CatClaw.Qemu.csproj`（同级目录，与 `CatClaw.Shared` 同一模式）。
- 套件**不认识**宿主应用类型：路径经 `QemuPaths.Configure(dataRoot, localRoot)` 注入；磁力结果用库内 DTO（`QemuMagnetFile`/`QemuPlayback`），由主仓库的 `QemuMagnetEngine` 适配成 `IPreferredMagnetEngine`。
- **大二进制不进 git**：initrd、QEMU 运行时、随包 JRE 等由本仓库的 Release 附件分发，主仓库构建时用 `tools/fetch-assets.ps1` 按版本 + SHA256 拉取。

## 构建

```powershell
dotnet build src/CatClaw.Qemu/CatClaw.Qemu.csproj
```

## 许可与合规

- 套件内含/依赖的第三方件（QEMU、Android/LineageOS 抽取件、OpenJDK 精简运行时、mpv、JRE 等）**只随 Release 分发**，不入 git。
- 迅雷 SDK 相关二进制与 appKey 属商业闭源 SDK 的未授权使用，用户已知情并选择打包，见主仓库 `THIRD-PARTY-NOTICES.md`。

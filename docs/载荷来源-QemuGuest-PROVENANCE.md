> **2026-10-05 更新（当前）**：运行时载荷 `qemu-guest-win64.zip` 已重打并覆盖上传到
> Release `vm-assets-v1` —— 465,031,310B，sha256 `18e2e8552ff0cc3c…`。本版起 **guest initrd
> 含崩溃现场常开**（信号哨兵默认开，现场写 `/data/catclaw/sig-crash.log`，`/data` 为持久
> ext4 数据盘），详见主仓库 `docs/调试报告-崩溃现场常开-20261005.md`。
> 此前所有「只在部署目录里生效」的新 `artlaunch` / `/init` 从此在**别人机器上**也生效。
>
> **2026-10-03 更新**：aarch64/TCG 旧线（qemu-system-aarch64.exe、pkg_kernel、pkg_initrd.gz、
> art_initrd.gz、art_initrd_merged.gz）与 x86 构建中间件已从本地与主仓库删除 —— 运行时只用
> qemu-system-x86_64.exe + share/ + x86guest/{vmlinuz-6.1.0-50-amd64, art_initrd_x64.gz}
> （共 524.1MB / 155 个文件）。下表保留旧线记录，便于追溯与回滚参考；回滚所需的 aarch64
> 组件可按 guest/qemu-src 里的构建脚本在 108 主机重建。

# QemuGuest（QEMU ART guest 运行时）

Windows 上承载 **x86_64 Android 13 ART guest**（爬虫桥 / TVBox jar 壳解壳 / 直播源）的 QEMU 运行时，
随应用分发到 `<app>/QemuGuest/`。载荷从 `AppContext.BaseDirectory/QemuGuest` 加载，宿主侧实现见
`src/CatClaw.Qemu/` 的 QemuGuest 服务，guest 侧构建工具链见 `guest/qemu-src/`。
（随包副本 `CatClawVideo.Maui/QemuGuest/PROVENANCE.md` 是同内容的精简版。）

⚠️ **必须有硬件虚拟化（WHPX）**：x86 线只认 WHPX，不可用直接判引擎不可用，**无软件模拟兜底**
（见 `QemuHostRuntime.StartLocked`；排障可用 `CATCLAW_QEMU_ACCEL=tcg` 强制）。

| 文件 | 说明 | sha256（前 16 位） |
|---|---|---|
| `qemu-system-x86_64.exe` | QEMU win64（x86_64 系统模拟） | `47d57a6072e0bb3b` |
| `share/` | 43 个 QEMU 运行时件（PC BIOS 等；x86 直启必需，aarch64 不需要） | — |
| 其余 110 个 DLL | QEMU 依赖（**图形栈已裁剪**：libGLESv2×3 / libEGL×2 / libvk_swiftshader 共 6 个 DLL 已移除，`-nographic` 无头运行不需要；其余硬依赖经存活探测确认保留） | — |
| `x86guest/vmlinuz-6.1.0-50-amd64` | Debian 6.1 内核（含 binder_linux.ko，init 负责 insmod） | `653421d9774c0de2` |
| `x86guest/art_initrd_x64.gz` | guest initrd = busybox 基座 + Android 13 子集 + ART 13 + ndk_translation + 桥（`gb.dex`/`ui_stub.dex`）+ `artlaunch`；由 `guest/qemu-src/tools/x86guest/mk_x86_initrd.sh` 组装，条目级注入用主仓库 `tools/initrd/replace_initrd_entries.py` | `06132dbdf686d09d` |

### 改 initrd 时的两条硬规矩（都踩过）

1. **`artlaunch` 与 `system/bin/artlaunch` 是两条独立条目**，init 起的是**后者**。
   只换一条 = 换了个寂寞（2026-10-05 现场）。必须用 `replace_initrd_entries.py` 一次换多条。
2. **部署包里的 `/init` 曾比仓库脚本多 crc16 修复**（持久盘挂载前提）。照仓库脚本重新生成
   `/init` 就等于把别人的修复倒回去 ⇒ 注入前一律先 `dump_initrd_entry.py --check` 比对。

### 其它约定

- **端口**：桥监听 `18600`（TCP 行协议），guest 以 `10.0.2.2` 回连宿主控制/媒体口。
  改端口需重新组装 initrd，并同步宿主 `QemuArtGuest` 的对应常量。
- **进程生命周期**：QEMU 只由应用按需启动（懒启动），空闲自动回收；子进程挂在 KillOnClose 的
  Job Object 上，应用退出/崩溃不会留下孤儿 VM。桥进程 139 死由 **guest 内 init 监督器**
  原地重启（VM 与 `/data` 不动），宿主无需重启 VM。

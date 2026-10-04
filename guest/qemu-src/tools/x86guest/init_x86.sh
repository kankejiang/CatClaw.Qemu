#!/bin/busybox sh
# x86 mini guest 的 /init —— QEMU(WHPX/KVM) 里跑「Android 13 ART + 桥」。
# 蓝本：aarch64 版 init.tmpl.sh；差异：APEX 布局、CATCLAW_BCP 环境变量、dalvik-cache/x86_64。
BB=/bin/busybox
export PATH=/system/bin:/bin
getarg() { $BB sed -n 's/.*'"$1"'=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null | $BB head -1; }

$BB mkdir -p /proc /sys /dev /tmp /data/catclaw
$BB mount -t proc proc /proc 2>/dev/null
$BB mount -t sysfs sys /sys 2>/dev/null
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null || $BB mount -t tmpfs tmpfs /dev -o mode=0755 2>/dev/null
# insmod 顺序即依赖顺序：ring → virtio 核心 → modern_dev/legacy → pci → blk → failover 系 → net
for m in virtio_ring virtio virtio_pci_modern_dev virtio_pci_legacy_dev virtio_pci virtio_blk failover net_failover virtio_net binder_linux; do
    echo "[init] insmod $m: $($BB insmod /modules/$m.ko 2>&1)" || true
done
# ext4 持久数据盘要用的模块（2026-10-04 补回）：缺它们时下面的 mount -t ext4 会失败，
# 于是 /data 退回 tmpfs ⇒ **网盘登录态每次重启都丢**（用户 2026-10-04 反馈）。
# crc32c_generic 是 metadata_csum 的必需项；jbd2 是日志回放（QEMU 硬杀安全）所需。
for m in crc32c_generic jbd2 mbcache ext4 binfmt_misc; do
    [ -f /modules/$m.ko ] || continue
    echo "[init] insmod $m: $($BB insmod /modules/$m.ko 2>&1)" || true
done

# ── 持久化数据盘（datadev=）：/data 落宿主本地 ext4——模拟器 userdata 同款（2026-10-02）──
# 首启 mke2fs 建文件系统；之后每次挂载（ext4 日志自动重放，QEMU 硬杀安全）。
# 盘上即最新状态：宿主的偏好回灌在 datadev 存在时由桥侧跳过（JavaSpiderRuntime）。
PDD=$(getarg datadev)
if [ -n "$PDD" ] && [ -b "$PDD" ]; then
    echo "[persist] 盘节点: $PDD; 内核 ext4 支持: $(grep -c ext4 /proc/filesystems 2>/dev/null)（0=无!）; partitions:"; grep vdc /proc/partitions 2>/dev/null
    export LD_LIBRARY_PATH=/system/lib64
    export MKE2FS_CONFIG=/system/etc/mke2fs.conf
    # ★ 预挂载强制 fsck（2026-10-03）：QEMU 硬杀可能留下脏 dentry（EUCLEAN，
    #   "Structure needs cleaning"，rm/stat 都救不了），只有离线 e2fsck 能自愈。
    #   幂等：干净盘上它秒过。不跑这步，jar 的"删旧→下载新"更新流程会卡死在脏目录上。
    #   ⚠ 用 PATH 上的独立 e2fsck（e2fsprogs），busybox 无此 applet（"applet not found"）。
    e2fsck -y "$PDD" > /tmp/fsck.log 2>&1
    echo "[persist] 预挂载 fsck rc=$? 尾行: $($BB tail -1 /tmp/fsck.log 2>/dev/null)"
    $BB mount -t ext4 "$PDD" /data
    echo "[persist] mount RC=$?"
    if ! $BB mount | $BB grep -q "on /data "; then
        e2fsck -y "$PDD" >/dev/null 2>&1
        $BB mount -t ext4 "$PDD" /data
        echo "[persist] fsck 后 mount RC=$?"
    fi
else
    echo "[persist] 无 datadev 或设备节点缺失（$PDD），/data 留在 tmpfs ⇒ **网盘登录态重启即丢**"
fi

PORT=$(getarg guardport); [ -n "$PORT" ] || PORT=18600
# 多桥（2026-10-04）：bridges=N（默认 1）。同一个 VM 内并排起 N 个桥进程，端口 PORT+1..PORT+N-1，
# 每个桥各自持有独立的 ART 虚拟机与 jar 缓存 ⇒ 不同站点的 load/search **真正并行**
# （单桥时 Server.call 按 synchronized(SITE_LOCKS[…]) 逐站串行，96 个站的 load 只能一个个排队）。
# 宿主侧按轮转把站点分给各桥（见 CatClawVideo 的 MultiBridge 调度）。
NBRIDGE=$(getarg bridges); [ -n "$NBRIDGE" ] || NBRIDGE=1
[ "$NBRIDGE" -ge 1 ] 2>/dev/null || NBRIDGE=1
[ "$NBRIDGE" -le 8 ] 2>/dev/null || NBRIDGE=8
DP=$(getarg ctrl)
if [ -n "$DP" ]; then export CATCLAW_DNS=10.0.2.2:$DP; echo "[dns] 走宿主转发 $CATCLAW_DNS"; fi
echo "=== CatClaw x86 ART guest begin (bridgeport=$PORT) ==="

$BB ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>&1
$BB ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>&1
$BB route add default gw 10.0.2.2 2>&1
$BB mkdir -p /etc
echo "nameserver 10.0.2.3" > /etc/resolv.conf
echo "search lan" >> /etc/resolv.conf

/fakelogd &
$BB sleep 1

export ANDROID_ROOT=/system ANDROID_DATA=/data ANDROID_STORAGE=/storage
export ANDROID_ART_ROOT=/apex/com.android.art
export ANDROID_I18N_ROOT=/apex/com.android.i18n
export ANDROID_TZDATA_ROOT=/apex/com.android.tzdata
export TMPDIR=/data/local/tmp
export LD_LIBRARY_PATH=/apex/com.android.art/lib64:/apex/com.android.os.statsd/lib64:/system/lib64
# 13 的 boot classpath：core 五件在 ART apex，framework 件在 /system/framework
# BCP 全部走 /system 路径（core jar 已从 apex 拷出）——避免触发 apex linker namespace
export CATCLAW_JVM_EXTRA="-Xnoimage-dex2oat -Xnodex2oat"
export CATCLAW_BCP="/system/javalib/core-oj.jar:/system/javalib/core-libart.jar:/system/javalib/core-icu4j.jar:/system/javalib/okhttp.jar:/system/javalib/bouncycastle.jar:/system/javalib/apache-xml.jar:/system/javalib/conscrypt.jar:/system/framework/framework.jar:/system/framework/ext.jar:/system/framework/telephony-common.jar:/system/framework/voip-common.jar:/system/framework/ims-common.jar:/system/framework/android.hidl.base-V1.0-java.jar:/system/framework/android.hidl.manager-V1.0-java.jar:/system/framework/android.test.base.jar"

# ── ARM 转译内核层注册（binfmt_misc）──
# ndk_translation 的 arm64 runner 走 execve 注册：arm64 ELF（e_machine 低字节 b7=183）由
# /system/bin/ndk_translation_program_runner_binfmt_misc_arm64 接管。
# PreInitializeNativeBridge 会 exec arm64 wrapper，不注册则 ENOEXEC/x86 linker 报架构错。
mkdir -p /binfmt_misc
mount -t binfmt_misc none /binfmt_misc 2>/dev/null
echo ':arm64_exe:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7::/system/bin/ndk_translation_program_runner_binfmt_misc_arm64:P' > /binfmt_misc/register 2>/dev/null && echo "[init] binfmt arm64 已注册" || echo "[init] binfmt 注册跳过"
# ── 开机清理上次残留的 Go 代理进程（pvideo / moyu_go）──
# 2026-10-03：网盘爬虫拉起 GoProxy 前会检查「是否已有实例」，残留进程会让它反复失败
# 并经 ui-toast 弹「Go代理 N 进程仍在退出」（用户观感：老弹窗）；而它自己可能清不掉
# （日志 detail=stale process cleanup incomplete）。开机先扫一遍，爬虫就能正常拉起。
for _p in pvideo moyu_go goproxy; do
    for _pid in $($BB pidof "$_p" 2>/dev/null); do
        echo "[init] 清理残留 $_p pid=$_pid"
        kill -9 "$_pid" 2>/dev/null
    done
done
$BB rm -f /data/files/moyu_go/*.pid /data/local/tmp/*.pid 2>/dev/null
# ── 桥进程监督器（2026-10-04 重写）──
#
# 旧实现：桥一死就 break 出去 sleep 3600 空转，等宿主杀 VM 重来（~20s，期间所有 jar 源全灭）。
# 新实现：**桥死就在本机原地重启**，VM 与 /data（持久盘上的网盘 Cookie / 登录态）都不动。
#   实测崩因是 ART JIT 代码里的空指针（[sig] s=11 a=0 … /memfd:jit-cache），进程级
#   SIGSEGV，try/catch 拦不住；重启桥是唯一能在本机自救的手段。
#
# 重启策略：指数退避 2s→4s→… 封顶 30s；连续失败超过 RESTART_MAX 次后拉长到 60s，
#   避免「桥一启动就崩」时忙等（那属于环境问题，重启无用，退避让 CPU 留给别的进程）。
#   日志一律打 [init]，宿主侧 slirp 日志转发会收走（见 QemuHostRuntime）。
# ── 桥进程监督器（2026-10-04 重写；同日扩展为多桥）──
#
# 旧实现：桥一死就 break 出去 sleep 3600 空转，等宿主杀 VM 重来（~20s，期间所有 jar 源全灭）。
# 新实现：**桥死就在本机原地重启**，VM 与 /data（持久盘上的网盘 Cookie / 登录态）都不动。
#   实测崩因是 ART JIT 代码里的空指针（[sig] s=11 a=0 … /memfd:jit-cache），进程级
#   SIGSEGV，try/catch 拦不住；重启桥是唯一能在本机自救的手段。
#
# 多桥（bridges=N）：并排起 N 个桥，端口 PORT..PORT+N-1，各持独立 ART 虚拟机与 jar 缓存。
#   单桥时桥内 Server.call 按 synchronized(SITE_LOCKS[…]) **逐站串行**，
#   96 个站的 load（实测 0.7~3s/站）只能排队 ⇒ 搜索跑不完；多桥让不同站点真正并行。
#   每个桥是独立监督循环：一个崩了只重启它自己，其余照常服务。
#
# 重启策略：指数退避 2s→4s→… 封顶 30s；连续失败超过 RESTART_MAX 次后拉长到 60s。
#   日志一律打 [init]，宿主侧 slirp 日志转发会收走（见 QemuHostRuntime）。
RESTART_MAX=5
SELFTEST=$(getarg selftest)

i=0
while [ $i -lt $NBRIDGE ]; do
    BP=$((PORT + i))
    (
        try_n=0
        while true; do
            LD_PRELOAD=/proppreload.so /system/bin/artlaunch bridge.GuestMain /gb.dex:/tvbox.apk $BP &
            LP=$!
            if [ -n "$SELFTEST" ] && [ "$i" -eq 0 ] && [ $try_n -eq 0 ]; then
                (
                    $BB sleep "$SELFTEST"
                    echo "[init] 自检：主动杀掉桥 pid=$LP（验证监督器重启）"
                    kill -9 $LP 2>/dev/null
                ) &
            fi
            # 等桥退出：轮询 kill -0（比 wait 稳），再 wait 取退出码
            while $BB kill -0 $LP 2>/dev/null; do
                $BB sleep 5
            done
            wait $LP 2>/dev/null
            RC=$?
            try_n=$((try_n + 1))
            if [ $try_n -ge $RESTART_MAX ]; then
                DELAY=60
            else
                DELAY=$((2 << (try_n - 1)))
                if [ $DELAY -gt 30 ]; then DELAY=30; fi
            fi
            echo "[init] 桥($BP) 进程已退出，退出码=$RC（139=SIGSEGV 132=SIGILL 134=SIGABRT 137=SIGKILL 0/1=主动退出）"
            echo "[init] ${DELAY}s 后重启桥($BP)（连续第 $try_n 次）—— VM 与 /data 不动，网盘登录态保留"
            $BB sleep $DELAY
        done
    ) &
    # 错开启动：各桥的 ART 初始化很吃 CPU/内存，同时起会互相拖慢
    $BB sleep 8
    i=$((i + 1))
done
echo "[init] 已拉起 $NBRIDGE 个桥：端口 $PORT..$((PORT + NBRIDGE - 1))"
while true; do $BB sleep 3600; done
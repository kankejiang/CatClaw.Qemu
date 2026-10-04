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

PORT=$(getarg guardport); [ -n "$PORT" ] || PORT=18600
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
RESTART_MAX=5
try_n=0
while true; do
    LD_PRELOAD=/proppreload.so /system/bin/artlaunch bridge.GuestMain /gb.dex:/tvbox.apk $PORT &
    LP=$!
    # 等桥退出：轮询 kill -0（更稳），再 wait 取退出码
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
    echo "[init] 桥进程已退出，退出码=$RC（139=SIGSEGV 132=SIGILL 134=SIGABRT 137=SIGKILL 0/1=主动退出）"
    echo "[init] ${DELAY}s 后重启桥（连续第 $try_n 次）—— VM 与 /data 不动，网盘登录态保留"
    $BB sleep $DELAY
done
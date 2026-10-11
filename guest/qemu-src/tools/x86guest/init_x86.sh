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
# ⚠ crc16 曾被漏掉：`modinfo -F depends ext4.ko` = jbd2,mbcache,**crc16**，
#   少它则 insmod ext4 报 "unknown symbol in module" → /proc/filesystems 里没有 ext4
#   → mount 报 "No such device"(ENODEV) → 持久盘形同不存在（盘本身是好的，fsck 能读到 338 个文件）。
for m in crc16 crc32c_generic mbcache jbd2 ext4 binfmt_misc; do
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
# ★ Round57 结论：-Xint 验证还崩（PC 同为 fb17）→ 凶手不是 JIT，已回滚。
# 性能 3-5 倍损失不能留生产。转 B 方案（壳 so 预加载，见 Art.java）。
export CATCLAW_JVM_EXTRA="-Xnoimage-dex2oat -Xnodex2oat"
export CATCLAW_BCP="/system/javalib/core-oj.jar:/system/javalib/core-libart.jar:/system/javalib/core-icu4j.jar:/system/javalib/okhttp.jar:/system/javalib/bouncycastle.jar:/system/javalib/apache-xml.jar:/system/javalib/conscrypt.jar:/system/framework/framework.jar:/system/framework/ext.jar:/system/framework/telephony-common.jar:/system/framework/voip-common.jar:/system/framework/ims-common.jar:/system/framework/android.hidl.base-V1.0-java.jar:/system/framework/android.hidl.manager-V1.0-java.jar:/system/framework/android.test.base.jar"

# ── ARM 转译内核层注册（binfmt_misc）──
# ndk_translation 的 arm64 runner 走 execve 注册：arm64 ELF（e_machine 低字节 b7=183）由
# /system/bin/ndk_translation_program_runner_binfmt_misc_arm64 接管。
# PreInitializeNativeBridge 会 exec arm64 wrapper，不注册则 ENOEXEC/x86 linker 报架构错。
mkdir -p /binfmt_misc
mount -t binfmt_misc none /binfmt_misc 2>/dev/null
echo ':arm64_exe:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7::/system/bin/ndk_translation_program_runner_binfmt_misc_arm64:P' > /binfmt_misc/register 2>/dev/null && echo "[init] binfmt arm64 已注册" || echo "[init] binfmt 注册跳过"
# ── arm64 linker namespace 白名单：/thunder 必须在内（2026-10-10）──
# 与 mk_x86_initrd.sh 生成的 ld.config.arm64.txt 保持一致；这里在运行时再覆写一遍，
# 好处是不必为改一行白名单重打 413MB initrd（initrd 是打包产物，改它要走另一台构建机）。
#
# 起因（实锤）：Guard 壳（类名 *Guard，jar ef8178b9…）运行期把 arm64 so 解到
#   /thunder/data/cache/.ftyfn… 再 System.load。旧白名单 permitted.paths 只有
#   /system/…:/data:/data/catclaw —— 没有 /thunder，于是 arm64 linker 的 namespace
#   判定该路径不受支持 → ndk 不接管 → System.load 退回宿主 bionic dlopen 按 x86_64
#   解析 arm64 ELF，抛「is for EM_AARCH64 (183) instead of EM_X86_64 (62)」。
#   同一批站因此全部加载失败（2026-10-10：探测 97 站失败 97）。
#   /thunder/data/fishso/libFishGuard-v8-*.so 是同一根因的另一落点。
cat > /system/etc/ld.config.arm64.txt <<'ARM64CFG'
dir.system = /system/bin
dir.system = /system/xbin

[system]
namespace.default.isolated = false
namespace.default.search.paths = /system/lib64/arm64
namespace.default.permitted.paths = /system/lib64/arm64:/system/lib64:/system/bin:/data:/data/catclaw:/thunder:/thunder/data:/thunder/data/cache:/thunder/data/fishso:/thunder/data/files

namespace.sphal.isolated = false
namespace.sphal.visible = true
namespace.sphal.search.paths = /system/lib64/arm64
namespace.sphal.permitted.paths = /system/lib64/arm64:/data:/data/catclaw:/thunder:/thunder/data:/thunder/data/cache:/thunder/data/fishso:/thunder/data/files
ARM64CFG
echo "[init] arm64 linker 白名单已含 /thunder（Guard 壳 arm64 so 落点）"

# ── x86 侧 ld.config.txt：com_android_art namespace 同样要放行 /thunder ──
# 桥进程（x86_64）经 ART 的 classloader 加载壳 so 时，判定走的是这份配置里的
# namespace.com_android_art.permitted.paths。它同样缺 /thunder（2026-10-10 实测：
# artlaunch 探针 IsPathSupported 对全部候选返回 0，含 /data/catclaw/art/lib）。
# 只改 arm64 那份不够——两份都要放行。
if [ -f /linkerconfig/ld.config.txt ]; then
    if grep -q "^namespace.com_android_art.permitted.paths" /linkerconfig/ld.config.txt; then
        $BB sed -i "s|^namespace.com_android_art.permitted.paths = \(.*\)|namespace.com_android_art.permitted.paths = \1:/thunder:/thunder/data:/thunder/data/cache:/thunder/data/fishso:/thunder/data/files|" /linkerconfig/ld.config.txt \
            && echo "[init] x86 linker 白名单已含 /thunder" || echo "[init] WARN x86 白名单改写失败"
    else
        echo "additional.namespaces = com_android_art" >> /linkerconfig/ld.config.txt
        echo "namespace.com_android_art.isolated = false" >> /linkerconfig/ld.config.txt
        echo "namespace.com_android_art.visible = true" >> /linkerconfig/ld.config.txt
        echo "namespace.com_android_art.search.paths = /apex/com.android.art/lib64" >> /linkerconfig/ld.config.txt
        echo "namespace.com_android_art.permitted.paths = /apex/com.android.art/lib64:/system/lib64:/data:/data/catclaw:/thunder:/thunder/data:/thunder/data/cache:/thunder/data/fishso:/thunder/data/files" >> /linkerconfig/ld.config.txt
        echo "[init] x86 linker 补建 com_android_art namespace（含 /thunder）"
    fi
fi
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
# ── 迅雷段（单VM合并：TVBox原样，默认关闭零副作用）──
# thunderport=0/缺省即整段跳过；资产缺失（/thunder/harness无）也跳过。
# 启用后：/thunder-data tmpfs + harness监督循环（EXIT可重启，每秒轮询宿主10.0.2.2:$THUNDERPORT/task）。
THUNDERPORT=$(getarg thunderport); [ -n "$THUNDERPORT" ] || THUNDERPORT=0
TBDATA=$(getarg blkdev); TSWAP=$(getarg swapdev); TDATA_T=$(getarg tdata); [ -n "$TDATA_T" ] || TDATA_T=3500m
if [ "$THUNDERPORT" = "0" ] || [ -z "$THUNDERPORT" ]; then
    echo "[thunder] 未启用（thunderport=0/缺省），跳过迅雷段"
else
    echo "[thunder] 启用：thunderport=$THUNDERPORT blkdev=${TBDATA:-（无）} swapdev=${TSWAP:-（无）} tdata=$TDATA_T"
    $BB mkdir -p /thunder-data
    $BB mount -t tmpfs -o size=$TDATA_T tmpfs /thunder-data 2>&1 || echo "[thunder] /thunder-data挂载失败（不致命，harness回退）"
    if [ -n "$TSWAP" ] && [ -b "$TSWAP" ]; then
        $BB mkswap "$TSWAP" 2>&1 | $BB tail -2
        $BB swapon "$TSWAP" 2>&1 || echo "[thunder] swapon失败，退化纯内存"
    fi
    export CTRL_HOST="10.0.2.2"
    export CTRL_PORT="$THUNDERPORT"
    export PROXY_PORT="20080"
    export MAGNET="none"
    export QCO="${QCO:-1}"
    export BLK_DEV="$TBDATA"
    TH_HARNESS="/thunder/harness"
    TH_QEMU="/thunder/qemu-aarch64-static"
    if [ ! -x "$TH_HARNESS" ]; then
        echo "[thunder] 缺 $TH_HARNESS，跳过拉起（等initrd注入迅雷资产）"
    else
        # ★ 转译执行必须 -L /thunder/sysroot（2026-10-05 Round11）：-L / 会让 ARM linker
        # 读到 /system/bin/linker64（x86 的）→ Invalid ELF 秒退 255，且 ARM 的 liblog 会毒化
        # x86 linker 命名空间（组装侧已把 ARM 树隔离进 sysroot，/system 零污染）。
        # sysroot 内含 ARM 的 linker64 + libc/log/m + 引擎库；缺失即跳过拉起。
        # ★ LD_LIBRARY_PATH 绝不能 export（2026-10-06 Round12 实测血的教训）：
        # ARM 的 libdl 会毒化 x86 artlaunch 的 linker 命名空间 → 桥 CANNOT LINK 全崩。
        # 只给 harness 单次调用加前缀（VAR=value cmd 仅作用于该命令），桥不受影响。
        if [ -x "$TH_QEMU" ] && [ -f "/thunder/sysroot/system/bin/linker64" ]; then
            TH_RUN="$TH_QEMU -L /thunder/sysroot /thunder/harness"
        elif [ -x "$TH_HARNESS" ]; then
            echo "[thunder] 缺 sysroot linker（/thunder/sysroot/system/bin/linker64），跳过拉起"
            TH_RUN=""
        else
            TH_RUN="$TH_HARNESS"
        fi
        if [ -z "$TH_RUN" ]; then
            echo "[thunder] harness 不可执行，跳过（等initrd注入迅雷资产）"
        else
        cd /thunder 2>/dev/null || true
        (
            while true; do
                echo "[thunder] 拉起harness：$TH_RUN（回连10.0.2.2:$THUNDERPORT）"
                LD_LIBRARY_PATH="/thunder/sysroot/system/lib64" $TH_RUN &
                THP=$!
                while $BB kill -0 $THP 2>/dev/null; do $BB sleep 5; done
                wait $THP 2>/dev/null
                THRC=$?
                echo "[thunder] harness已退出，退出码=$THRC，2s后拉起（VM/桥/data不动）"
                $BB sleep 2
            done
        ) &
        echo "[thunder] harness监督循环已起"
        fi
    fi
fi
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
            # 崩溃现场常开（2026-10-05）：artlaunch 把 [sig] 现场写进**持久盘上的文件**，
            # stderr 只留 6 行指路牌 —— 2026-09-27 那次「console 管道写满 → 信号处理内阻塞 →
            # 全线程冻住」的死穴是 stderr 独有的，换成文件就没有了。每进程预算 400 行封顶。
            # 之所以常开：#42/#46 一直查不动的直接原因就是崩溃不留现场（[sig] 0 行 / 退出码 139 五次）。
            CATCLAW_SIGLOG=1 CATCLAW_SIGFILE=/data/catclaw/sig-crash.log LD_PRELOAD=/proppreload.so /system/bin/artlaunch bridge.GuestMain /gb.dex:/tvbox.apk $BP &
            LP=$!
            if [ -n "$SELFTEST" ] && [ "$i" -eq 0 ] && [ $try_n -eq 0 ]; then
                (
                    $BB sleep "$SELFTEST"
                    # ⚠ 必须走 busybox 完整 applet 路径：本 init 是 ash 直跑，裸 kill 不是
                    # applet 会静默不做事（2026-10-10 实测 selftest=70 传到了 QEMU、
                    # guest 里却一条自检日志都没有 —— kill 从未执行）。
                    echo "[init] 自检：主动杀掉桥 pid=$LP（验证监督器重启）"
                    $BB kill -9 "$LP" 2>/dev/null || kill -9 "$LP" 2>/dev/null
                    echo "[init] 自检：kill 已发出，pid=$LP"
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
package bridge;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.URL;
import java.net.URLClassLoader;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;

/**
 * spider jar 的类加载器：类加载期做三件事。
 *
 * <ol>
 *   <li>经 {@link SleepPatcher} 把 {@code Thread.sleep} 等节拍调用改道到可伸缩的桩
 *       （扫码登录窗口拉长，见两者注释）。</li>
 *   <li>经 {@link LegacyVerifierPatcher} 把 dex2jar 产物降到 class version 49 并剥掉
 *       {@code StackMapTable}，让 JVM 用旧式推断校验器（支持 jsr/ret）。
 *       这是解决 {@code VerifyError: Expecting a stackmap frame} 的<b>正解</b>。</li>
 *   <li>兜底：万一上面还不够，再用 {@link StackMapPatcher} 重算一次 frame。</li>
 * </ol>
 *
 * <p><b>为什么降版本而不是重算 frame</b>：爬虫 jar 全部 1152 个类都是 class version 50，
 * 方法体保留 dex 的 {@code jsr}/{@code ret}（{@code merge/Rc} 有 11 jsr + 18 ret）。
 * 分裂校验器（version ≥50 且有 StackMapTable 时启用）<b>完全不支持</b> jsr/ret，
 * ASM 的 COMPUTE_FRAMES 同样建立在分裂模型上、算不对（实测：无条件重算 200+ 类后
 * 23 个真爬虫仍报同一个 {@code merge/Rc.B @4: ifeq}）。降到 49 则回退到旧式推断校验器，
 * 它原生处理 jsr/ret。</p>
 *
 * <p>父优先委派不变：android.* 桩、桥自身类与 JDK 类不受影响。</p>
 */
public class SleepPatchingLoader extends URLClassLoader {

    /** 降版本开关：-Dbridge.legacyver=0 可关掉，回到只重算 frame。 */
    private static final boolean LEGACY =
            Integer.getInteger("bridge.legacyver", 49) > 0;

    private static volatile int patchedCount = 0;

    public SleepPatchingLoader(URL[] urls, ClassLoader parent) {
        super(urls, parent);
    }

    /** 已做降版本处理的类数（诊断用）。 */
    public static int patchedCount() { return patchedCount; }

    @Override
    protected Class<?> findClass(String name) throws ClassNotFoundException {
        String path = name.replace('.', '/') + ".class";
        for (URL url : getURLs()) {
            File f = new File(url.getFile());
            if (!f.isFile()) continue;
            try (JarFile jar = new JarFile(f)) {
                JarEntry entry = jar.getJarEntry(path);
                if (entry == null) continue;
                byte[] raw;
                try (InputStream in = jar.getInputStream(entry)) {
                    raw = in.readAllBytes();
                }
                byte[] patched = SleepPatcher.patch(raw);
                if (LEGACY) {
                    // 正解：降到 version 49 + 剥 StackMapTable → 旧式推断校验器（支持 jsr/ret）。
                    byte[] legacy = LegacyVerifierPatcher.patch(patched);
                    patchedCount++;
                    if (patchedCount <= 3 || patchedCount % 300 == 0) {
                        System.err.println("[loader] legacy-ver #" + patchedCount + ": " + name);
                    }
                    return defineClass(name, legacy, 0, legacy.length);
                }
                // 关掉降级时：只重算 frame（对无 jsr 的类有效）。
                byte[] fixed = StackMapPatcher.patch(patched, getParent());
                return defineClass(name, fixed, 0, fixed.length);
            } catch (IOException ignored) {
                // 换下一个 URL 再找
            }
        }
        throw new ClassNotFoundException(name);
    }
}

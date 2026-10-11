package bridge;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;

import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * dex2jar 产物的 {@code StackMapTable} 修复器。
 *
 * <p><b>问题</b>：爬虫 jar 是 dex2jar 从 {@code classes.dex} 转出来的。转换器不重建
 * {@code StackMapTable}（dex 里没有这个结构），而 JDK 7+ 的分裂校验器要求所有跳转目标
 * 都有 stackmap frame。结果是 {@code VerifyError: Expecting a stackmap frame at branch
 * target N}。实测（2026-10-07）62 个真爬虫里 23 个栽在这一处，且<b>全部指向同一个方法</b>
 * {@code com.github.catvod.spider.merge.Rc.B}。</p>
 *
 * <p><b>为什么不能靠 catch 兜底</b>：JVM 的字节码校验是<b>延迟</b>的——{@code defineClass}
 * 只做格式检查，方法体的 frame 校验要等该方法第一次被解析/执行时才发生。把重算包在
 * {@code catch (VerifyError)} 里，日志里「修复」出现 0 次而错误照旧。故必须在加载期一律重算。</p>
 *
 * <p><b>为什么不用 {@code -noverify}</b>：JDK 18+ 已移除该选项（JDK 27 实测
 * {@code Unrecognized option: -noverify}）；{@code -Xverify:none} 同样移除。且关校验是全局的，
 * 会掩盖真实字节码错误。重算只补缺失的 frame，不改语义。</p>
 *
 * <p><b>在途保护</b>：{@code COMPUTE_FRAMES} 需要解析被引用类型来求公共超类，而解析又可能
 * 触发本加载器 {@code findClass} 去定义那个类——若正好是在定义中的类，会撞
 * {@code LinkageError: attempted duplicate class definition}。故用 {@link #IN_PROGRESS}
 * 记录正在重算的类名，遇到在途类型直接退到 {@code java/lang/Object}（最保守的公共超类）。</p>
 */
public final class StackMapPatcher {

    private StackMapPatcher() { }

    /** 正在重算 frame 的类（内部名，'/' 分隔）——防止求公共超类时递归定义自己。 */
    private static final Set<String> IN_PROGRESS = ConcurrentHashMap.newKeySet();

    /** 重算全部 stackmap frame。失败时返回原字节码（交由调用方的异常路径处理）。 */
    public static byte[] patch(byte[] bytes, final ClassLoader loader) {
        final String[] selfName = {null};
        try {
            ClassReader cr = new ClassReader(bytes);
            selfName[0] = cr.getClassName();
            IN_PROGRESS.add(selfName[0]);
            ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_FRAMES) {
                @Override
                protected String getCommonSuperClass(String type1, String type2) {
                    if (IN_PROGRESS.contains(type1) || IN_PROGRESS.contains(type2)) {
                        return "java/lang/Object";
                    }
                    try {
                        Class<?> c1 = Class.forName(type1.replace('/', '.'), false, loader);
                        Class<?> c2 = Class.forName(type2.replace('/', '.'), false, loader);
                        if (c1.isAssignableFrom(c2)) return type1;
                        if (c2.isAssignableFrom(c1)) return type2;
                        if (c1.isInterface() || c2.isInterface()) return "java/lang/Object";
                        Class<?> c = c1;
                        do {
                            c = c.getSuperclass();
                            if (c == null) return "java/lang/Object";
                        } while (!c.isAssignableFrom(c2));
                        return c.getName().replace('.', '/');
                    } catch (Throwable t) {
                        // 依赖类缺失（如未随包分发的第三方库）或加载失败：退到最保守的公共超类。
                        // 校验器接受 Object 作为合并类型，只是后续对该值的具体方法调用会更严格——
                        // 那种情形本就说明该依赖缺失，迟早会以 NoClassDefFoundError 暴露。
                        return "java/lang/Object";
                    }
                }
            };
            cr.accept(cw, ClassReader.SKIP_FRAMES);
            return cw.toByteArray();
        } catch (Throwable t) {
            System.err.println("[stackmap] 重算失败，按原字节码返回: " + t);
            return bytes;
        } finally {
            if (selfName[0] != null) IN_PROGRESS.remove(selfName[0]);
        }
    }
}

package bridge;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;

/**
 * dex2jar 产物的「旧式校验器」适配器。
 *
 * <p><b>问题</b>：爬虫 jar 是 dex2jar 转出来的，<b>全部类都是 class version 50（Java 6）</b>
 * （实测 1152/1152）。dex2jar 会写一个<b>不完整</b>的 {@code StackMapTable}，而方法体里保留
 * dex 特有的 {@code jsr}/{@code ret} 子程序指令（实测 {@code merge/Rc} 有 11 个 jsr、18 个 ret）。</p>
 *
 * <p>JDK 7+ 的规则是：class version ≥ 50 <b>且存在</b> {@code StackMapTable} 时走<b>分裂校验器</b>；
 * 而分裂校验器<b>完全不支持</b> jsr/ret，且要求每个跳转目标都有 frame —— 于是
 * {@code VerifyError: Expecting a stackmap frame at branch target 12}。</p>
 *
 * <p><b>为什么 COMPUTE_FRAMES 救不了</b>：ASM 的 {@code COMPUTE_FRAMES} 同样建立在分裂校验
 * 模型上，遇到 jsr/ret 会算出错误结果（实测：无条件重算 200+ 个类后，23 个真爬虫仍报同一个
 * {@code merge/Rc.B @4: ifeq}）。</p>
 *
 * <p><b>正确修法</b>：把 class version 降到 <b>49（Java 5）</b>并<b>剥掉</b> StackMapTable。
 * 按 JVMS 规则，version ≤ 49 的类由<b>旧式类型推断校验器</b>处理——它原生支持 jsr/ret，
 * 不需要任何 frame。dex2jar 的产物本就是 Java 6 语义，降到 49 不损失能力
 * （这些爬虫不用 invokedynamic/默认方法等 Java 7+ 特性）。</p>
 *
 * <p><b>安全性</b>：只改类文件版本号与删一个可选属性，指令序列一字不动。
 * 若某类确实用了 Java 7+ 特性，旧校验器会以清晰的 {@code Unsupported class file major
 * version} 或方法级错误暴露，不会静默错判。</p>
 */
public final class LegacyVerifierPatcher {

    private LegacyVerifierPatcher() { }

    /** Java 5 class 版本号：低于 50 即触发旧式推断校验器。 */
    private static final int V1_5 = Opcodes.V1_5;

    /** 目标版本（49）。可 -Dbridge.legacyver=51 关掉降级，回到只重算 frame 的老路。 */
    private static final int TARGET = Integer.getInteger("bridge.legacyver", V1_5);

    public static byte[] patch(byte[] bytes) {
        try {
            ClassReader cr = new ClassReader(bytes);
            // 关键：flags=0 —— 不重算 frame（COMPUTE_FRAMES 处理不了 jsr/ret）。
            ClassWriter cw = new ClassWriter(cr, 0);
            ClassVisitor cv = new ClassVisitor(Opcodes.ASM9, cw) {
                @Override
                public void visit(int version, int access, String name, String signature,
                                  String superName, String[] interfaces) {
                    // 降到 49：让 JVM 走旧式推断校验器（支持 jsr/ret，不需要 StackMapTable）。
                    int v = version & 0xFFFF;
                    int newVersion = (TARGET > 0 && v > TARGET) ? TARGET : version;
                    super.visit(newVersion, access, name, signature, superName, interfaces);
                }
            };
            // SKIP_FRAMES：读时丢弃原有（不完整的）frame，写出时自然不带 StackMapTable。
            cr.accept(cv, ClassReader.SKIP_FRAMES);
            return cw.toByteArray();
        } catch (Throwable t) {
            System.err.println("[legacyver] 变换失败，按原字节码返回: " + t);
            return bytes;
        }
    }
}

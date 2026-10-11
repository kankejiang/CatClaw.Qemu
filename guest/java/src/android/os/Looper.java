package android.os;
public class Looper {
    private static final Looper MAIN = new Looper();
    public static Looper getMainLooper() { return MAIN; }
    public static Looper myLooper() { return MAIN; }

    /** 真机上由 Zygote 调用；桌面是空操作，ART 里由 {@code bridge.GuestMain} 显式调一次。 */
    public static void prepareMainLooper() { }

    /** 为<b>当前线程</b>准备 Looper。壳建 Handler/Dialog 需要它（真机由框架备好）。 */
    public static void prepare() { }
}
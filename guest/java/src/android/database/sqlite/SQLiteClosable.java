package android.database.sqlite;

/**
 * <code>android.database.sqlite.SQLiteClosable</code> 桩。
 *
 * <p><b>为什么需要它</b>：大量 spider jar（dex2jar 转换的纯 .class 版本）在类初始化时
 * 直接 {@code extends SQLiteClosable} 或引用它，例如
 * {@code com.github.catvod.spider.merge.V.<init>}。缺这个类时加载期即
 * {@code NoClassDefFoundError} / {@code ClassNotFoundException}，
 * 表现为「站点 jar 里找不到爬虫类」——实测 724 个爬虫里 500+ 个栽在这一处。</p>
 *
 * <p><b>历史</b>：2026-10-03 commit 3a9d637 摘掉了本桩（理由是「让 ART 真框架接管」），
 * 那只对 ART guest 成立；<b>纯 JVM 桥（路线 A）没有真框架</b>，必须补回。
 * 桌面无真库，一律空实现。</p>
 */
public abstract class SQLiteClosable {

    protected void onAllReferencesReleased() { }

    public void close() { }

    public void acquireReference() { }

    public void releaseReference() { }

    public void releaseReferenceFromContainer() { }
}

package android.webkit;

/**
 * <code>android.webkit.CookieManager</code> 桩：spider 常做 setCookie/getCookie。
 *
 * <p>纯 JVM 桥无 cookie 存储：{@code getCookie} 返回 null 可观测降级，
 * 让调用方走自己的无 cookie 分支（而不是在类加载期就 CNFE 崩掉）。</p>
 *
 * <p>见 {@link android.database.sqlite.SQLiteClosable} 的历史说明。</p>
 */
public class CookieManager {

    private static final CookieManager INSTANCE = new CookieManager();

    public static CookieManager getInstance() { return INSTANCE; }

    public void setAcceptCookie(boolean accept) { }

    public boolean acceptCookie() { return true; }

    public void setAcceptThirdPartyCookies(WebView webview, boolean accept) { }

    public void setCookie(String url, String value) { }

    public void setCookie(String url, String value, ValueCallback<Boolean> callback) { }

    public String getCookie(String url) { return null; }

    public boolean hasCookies() { return false; }

    public void removeAllCookie() { }

    public void removeSessionCookie() { }

    public void removeExpiredCookie() { }

    public void flush() { }

    public interface ValueCallback<T> { void onReceiveValue(T value); }
}

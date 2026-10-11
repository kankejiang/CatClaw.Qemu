package android.database.sqlite;

import android.database.Cursor;

/**
 * <code>android.database.sqlite.SQLiteDatabase</code> 桩。
 *
 * <p>spider 常做 {@code openOrCreateDatabase(...)} 后 {@code execSQL} 建表、
 * {@code rawQuery} 读 cookie/配置。桌面桥无真库：写操作空转，读操作返回 null，
 * 由调用方的 try/catch 走降级路径（与 {@link android.database.Cursor} 桩同一策略）。</p>
 *
 * <p>见 {@link SQLiteClosable} 的历史说明：本桩 2026-10-03 被摘、现为纯 JVM 桥补回。</p>
 */
public class SQLiteDatabase {

    /** {@code CursorFactory}：spider 的 {@code rawQuery(sql, args, factory)} 会用。 */
    public interface CursorFactory {
        Cursor newCursor(SQLiteDatabase db, SQLiteCursorDriver masterQuery,
                         String editTable, SQLiteQuery query);
    }

    /** {@code SQLiteCursorDriver}：仅为 {@link CursorFactory} 签名齐全。 */
    public interface SQLiteCursorDriver { }

    /** {@code SQLiteQuery}：仅为 {@link CursorFactory} 签名齐全。 */
    public static class SQLiteQuery { }

    public static SQLiteDatabase openOrCreateDatabase(String path, CursorFactory factory) {
        return new SQLiteDatabase();
    }

    public static SQLiteDatabase openDatabase(String path, CursorFactory factory, int flags) {
        return new SQLiteDatabase();
    }

    public void execSQL(String sql) { }

    public void execSQL(String sql, Object[] bindArgs) { }

    public Cursor rawQuery(String sql, String[] selectionArgs) { return null; }

    public Cursor rawQuery(String sql, String[] selectionArgs, CursorFactory factory) { return null; }

    public Cursor query(String table, String[] columns, String selection,
                        String[] selectionArgs, String groupBy, String having,
                        String orderBy) { return null; }

    public void close() { }

    public boolean isOpen() { return false; }

    public void beginTransaction() { }

    public void setTransactionSuccessful() { }

    public void endTransaction() { }
}

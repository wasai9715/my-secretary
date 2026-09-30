import Foundation
import CSQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class ItemStore {
    private var db: OpaquePointer?

    public init(path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let error = storageError()
            sqlite3_close(db)
            db = nil
            throw error
        }
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, payload BLOB NOT NULL)", nil, nil, nil) == SQLITE_OK else {
            let error = storageError()
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    public func upsert(_ item: ReminderItem) throws {
        let data = try JSONEncoder().encode(item)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO items(id,payload) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", -1, &statement, nil) == SQLITE_OK else { throw storageError() }
        defer { sqlite3_finalize(statement) }
        let id = item.id.uuidString
        guard sqlite3_bind_text(statement, 1, id, -1, sqliteTransient) == SQLITE_OK else { throw storageError() }
        let bind = data.withUnsafeBytes { bytes in sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(data.count), sqliteTransient) }
        guard bind == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw storageError() }
    }

    public func all() throws -> [ReminderItem] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, payload FROM items", -1, &statement, nil) == SQLITE_OK else { throw storageError() }
        defer { sqlite3_finalize(statement) }
        var result: [ReminderItem] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw storageError() }
            guard let idBytes = sqlite3_column_text(statement, 0),
                  let bytes = sqlite3_column_blob(statement, 1) else {
                throw RecognitionError.connection("本机事项数据损坏：无法读取记录")
            }
            let id = String(cString: idBytes)
            let size = Int(sqlite3_column_bytes(statement, 1))
            do {
                let item = try JSONDecoder().decode(ReminderItem.self, from: Data(bytes: bytes, count: size))
                guard item.id.uuidString == id else {
                    throw RecognitionError.connection("本机事项数据损坏：记录标识不一致（\(id)）")
                }
                result.append(item)
            } catch let error as RecognitionError { throw error }
            catch { throw RecognitionError.connection("本机事项数据损坏：无法解码记录（\(id)），请保留数据库以便恢复") }
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ id: UUID) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM items WHERE id=?", -1, &statement, nil) == SQLITE_OK else { throw storageError() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, id.uuidString, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw storageError() }
    }

    private func storageError() -> RecognitionError {
        .connection("本机事项保存失败：\(String(cString: sqlite3_errmsg(db)))")
    }
}

public struct LocalFiles {
    public let directory: URL
    public init(directory: URL? = nil) throws {
        if let directory { self.directory = directory }
        else {
            self.directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("MySecretary", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
    }
    public var databasePath: String { directory.appendingPathComponent("items.sqlite3").path }

    public func loadConfiguration() throws -> AIConfiguration {
        let path = directory.appendingPathComponent("model.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return AIConfiguration() }
        return try JSONDecoder().decode(AIConfiguration.self, from: Data(contentsOf: path))
    }
    public func saveConfiguration(_ config: AIConfiguration) throws {
        let path = directory.appendingPathComponent("model.json")
        let data = try JSONEncoder().encode(config)
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    public func loadSettings() throws -> ReminderSettings {
        let path = directory.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return ReminderSettings() }
        var settings = try JSONDecoder().decode(ReminderSettings.self, from: Data(contentsOf: path))
        // Early builds used a system-search shortcut; migrate only that exact default.
        if settings.shortcutKey == 49 && settings.shortcutModifiers == 3 {
            settings.shortcutKey = 25
            settings.shortcutModifiers = 0x1200
            try saveSettings(settings)
        }
        return settings
    }
    public func saveSettings(_ settings: ReminderSettings) throws {
        let path = directory.appendingPathComponent("settings.json")
        try JSONEncoder().encode(settings).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}

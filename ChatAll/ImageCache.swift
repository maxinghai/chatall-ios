//
//  ImageCache.swift
//  ChatAll
//
//  图片缓存：内存 NSCache + 磁盘（Caches/chat-images），同一 URL 只从网络加载一次。
//  CachedImage 视图替代 AsyncImage，全 app 的网络图片统一走这里。
//

import SwiftUI
import CryptoKit

enum ImageCache {

    static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    /// 磁盘缓存目录
    static let diskDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 取图：内存 → 磁盘 → 网络（成功后写入两级缓存）
    static func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let hit = memory.object(forKey: key) { return hit }

        let file = diskURL(for: url)
        if let data = try? Data(contentsOf: file),
           let img = UIImage(data: data) {
            memory.setObject(img, forKey: key)
            return img
        }

        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let img = UIImage(data: data) else { return nil }
            memory.setObject(img, forKey: key)
            try? data.write(to: file, options: .atomic)
            return img
        } catch {
            return nil
        }
    }

    /// 磁盘缓存文件路径（对 URL 做 SHA256 作为文件名）
    static func diskURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(name)
    }

    /// 磁盘缓存占用字节数
    static func diskUsage() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: diskDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// 清空缓存，返回释放的磁盘字节数
    @discardableResult
    static func clear() -> Int64 {
        let freed = diskUsage()
        memory.removeAllObjects()
        let files = (try? FileManager.default.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? FileManager.default.removeItem(at: f) }
        return freed
    }
}

/// 带两级缓存的图片视图（替代 AsyncImage）
struct CachedImage<Placeholder: View, Failure: View>: View {
    let url: URL
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var failure: () -> Failure

    @State private var image: UIImage? = nil
    @State private var failed = false

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                failure()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            failed = false
            image = nil
            if let img = await ImageCache.image(for: url) {
                image = img
            } else {
                failed = true
            }
        }
    }
}

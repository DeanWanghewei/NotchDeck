import Combine
import Foundation

typealias PluginScriptCompletion = (Result<Data, PluginScriptError>) -> Void
typealias PluginScriptFetch = (URL, @escaping PluginScriptCompletion) -> AnyCancellable

enum PluginScriptError: Error, Equatable {
    case network, http(Int), tooLarge, checksumMismatch, storage, unavailable

    var message: String {
        switch self {
        case .network: return "无法下载脚本，请检查网络后重试"
        case .http(let status): return "脚本暂不可用（HTTP \(status)），已保留当前脚本"
        case .tooLarge: return "脚本超过 256 KiB 上限，已保留当前脚本"
        case .checksumMismatch: return "脚本校验不符，已保留当前脚本"
        case .storage: return "无法写入脚本文件，请检查应用 Data 目录权限"
        case .unavailable: return "脚本不存在或已损坏，请重新安装"
        }
    }
}

/// 仅在用户显式点击“更新/安装脚本”时下载；传输策略与目录刷新一致：
/// 固定来源、拒绝重定向（防把请求带去任意主机）、256 KiB 上限、无 Cookie 与缓存。
final class PluginScriptClient: NSObject, URLSessionDataDelegate {
    static let maximumBytes = 256 * 1024
    private var completion: PluginScriptCompletion?
    private var session: URLSession?
    private var buffer = Data()

    static func fetch(url: URL, configuration: URLSessionConfiguration = .ephemeral,
                      completion: @escaping PluginScriptCompletion) -> AnyCancellable {
        let client = PluginScriptClient()
        client.completion = completion
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: client, delegateQueue: nil)
        client.session = session
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("text/plain, application/javascript", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        task.resume()
        return AnyCancellable { task.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            finish(.failure(.http((response as? HTTPURLResponse)?.statusCode ?? 0)))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Self.maximumBytes else {
            finish(.failure(.tooLarge))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard buffer.count + data.count <= Self.maximumBytes else { finish(.failure(.tooLarge)); return }
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError, error.code == .cancelled { return }
        if error != nil { finish(.failure(.network)) }
        else { finish(.success(buffer)) }
    }

    private func finish(_ result: Result<Data, PluginScriptError>) {
        let completion = completion
        self.completion = nil
        session?.invalidateAndCancel()
        session = nil
        completion?(result)
    }
}

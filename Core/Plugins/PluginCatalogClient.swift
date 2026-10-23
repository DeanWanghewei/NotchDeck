import Combine
import Foundation

typealias PluginCatalogCompletion = (Result<Data, PluginCatalogError>) -> Void
typealias PluginCatalogFetch = (@escaping PluginCatalogCompletion) -> AnyCancellable

/// 仅显式刷新时访问固定 GitHub 目录，无 Cookie、凭据或可执行下载。
final class PluginCatalogClient: NSObject, URLSessionDataDelegate {
    private var completion: PluginCatalogCompletion?
    private var session: URLSession?
    private var buffer = Data()

    static func fetch(configuration: URLSessionConfiguration = .ephemeral,
                      completion: @escaping PluginCatalogCompletion) -> AnyCancellable {
        let client = PluginCatalogClient()
        client.completion = completion
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: client, delegateQueue: nil)
        client.session = session
        var request = URLRequest(url: PluginCatalog.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
        guard response.expectedContentLength <= PluginCatalog.maximumBytes else {
            finish(.failure(.invalidCatalog))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard buffer.count + data.count <= PluginCatalog.maximumBytes else {
            finish(.failure(.invalidCatalog)); return
        }
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(.failure(.network)) }
        else { finish(.success(buffer)) }
    }

    private func finish(_ result: Result<Data, PluginCatalogError>) {
        let completion = completion
        self.completion = nil
        session?.invalidateAndCancel()
        session = nil
        completion?(result)
    }
}

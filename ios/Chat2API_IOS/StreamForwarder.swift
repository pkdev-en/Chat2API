// --- ios/Chat2API_iOS/StreamForwarder.swift ---
import Foundation

class StreamForwarder: NSObject, URLSessionDataDelegate {
    private var onData: (Data) -> Void
    private var onComplete: (Error?) -> Void
    private var task: URLSessionDataTask?
    private var session: URLSession!

    init(onData: @escaping (Data) -> Void, onComplete: @escaping (Error?) -> Void) {
        self.onData = onData
        self.onComplete = onComplete
        super.init()
        self.session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: nil
        )
    }

    func forward(request: URLRequest) {
        task = session.dataTask(with: request)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        onData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        onComplete(error)
    }
}

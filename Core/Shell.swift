import Foundation

/// 外部命令执行（绝对路径；支持超时，见风险对策）
enum Shell {
    @discardableResult
    static func run(_ path: String, arguments: [String], timeout: TimeInterval? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
                if process?.isRunning == true {
                    process?.terminate()
                }
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // lsof 输出可能含进程改名产生的非法 UTF-8 字节（如企业微信的 process.title），
        // 严格解码会整体返回 nil；用 lossy 解码（非法字节替换为 U+FFFD）
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return nil }
        return text
    }
}

import Foundation

public extension Error {
    /// 给人看的一句话。`ShellCommandError` 优先用子进程的 stderr——那才是 git 真正想说的话。
    var userFacingDescription: String {
        if let failure = self as? ShellCommandError {
            return failure.message.isEmpty ? "\(failure.command) 退出码 \(failure.status)" : failure.message
        }
        return localizedDescription
    }
}

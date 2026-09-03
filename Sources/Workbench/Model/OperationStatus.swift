import Foundation

/// 一次 git 操作（提交、推送、回滚……）的结果，显示在工具窗口底部，用户点 × 关掉。
enum OperationStatus: Equatable {
    case success(String)
    case failure(String)
}

import Foundation

/// 提交时间的显示：一周内说「几分钟前 / 昨天」这种相对说法，更早的给日期。
public enum DateText {
    public static func relative(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) 小时前" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "昨天" }
        if seconds < 7 * 86400 { return "\(Int(seconds / 86400)) 天前" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: date)
    }

    public static func full(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

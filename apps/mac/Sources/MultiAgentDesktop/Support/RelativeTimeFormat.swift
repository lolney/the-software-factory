import Foundation

func compactRelativeTimeLabel(from date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 {
        return "\(max(1, seconds))s ago"
    }

    let minutes = seconds / 60
    if minutes < 60 {
        return "\(minutes) min ago"
    }

    let hours = minutes / 60
    if hours < 24 {
        return "\(hours)h ago"
    }

    let days = hours / 24
    if days == 1 {
        return "Yesterday"
    }
    return "\(days)d ago"
}

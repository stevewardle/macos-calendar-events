import Foundation
import EventKit

#if os(macOS)
import Darwin

func getExecutablePath() -> URL? {
    var bufsize = UInt32(PATH_MAX)
    let buf = UnsafeMutablePointer<Int8>.allocate(capacity: Int(bufsize))
    defer { buf.deallocate() }
    let result = _NSGetExecutablePath(buf, &bufsize)
    if result != 0 {
        // Buffer was too small or error
        return nil
    }
    let path = String(cString: buf)
    // Resolve symlinks, .., etc
    return URL(fileURLWithPath: path).standardized.deletingLastPathComponent()
}
#else
func getExecutablePath() -> URL? {
    // Fallback for other OSes if needed
    return nil
}
#endif

let store = EKEventStore()
let semaphore = DispatchSemaphore(value: 0)

// How much time ahead to look (default is 1 day)
// Parse command-line argument for time window (e.g. 1d, 2h, 30m, 1)
let defaultTimeInterval: TimeInterval = 24 * 60 * 60 // 1 day in seconds

let verbose: Bool = CommandLine.arguments.contains("-v") || CommandLine.arguments.contains("--verbose")
let timeIntervalToFetch: TimeInterval = {
    let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
    return parseTimeArgument(arg)
}()

func parseTimeArgument(_ arg: String?) -> TimeInterval {
    guard let arg = arg else { return defaultTimeInterval }
    let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let intVal = Int(trimmed) {
        return TimeInterval(intVal) * 24 * 60 * 60 // treat as days
    }
    let regex = try! NSRegularExpression(pattern: #"^(\d+)([smhd])$"#)
    if let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
       let valueRange = Range(match.range(at: 1), in: trimmed),
       let unitRange = Range(match.range(at: 2), in: trimmed) {
        let value = Double(trimmed[valueRange]) ?? 0
        let unit = trimmed[unitRange]
        switch unit {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 60 * 60
        case "d": return value * 24 * 60 * 60
        default: return defaultTimeInterval
        }
    }
    return defaultTimeInterval
}

func loadAllowedCalendars(from allCalendars: [EKCalendar]) -> [EKCalendar] {
    guard let binaryDir = getExecutablePath() else {
        print("Could not resolve binary path. Using all calendars.")
        return allCalendars
    }

    let fileURL = binaryDir.appendingPathComponent("calendars.txt")
    if verbose {
        print("Looking for calendars.txt at: \(fileURL.path)")
    }

    do {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let allowed = Set(lines)
        let selected = allCalendars.filter { allowed.contains($0.title) }

        if selected.isEmpty {
            print("No matching calendars found in calendars.txt. Using all calendars instead.")
            return allCalendars
        }

        return selected
    } catch {
        print("No calendars.txt found or failed to read it. Using all calendars.")
        return allCalendars
    }
}

func fetchEvents() {
    // Fetch all event calendars
    let allCalendars = store.calendars(for: .event)

    // Filter calendars by name
    let selectedCalendars = loadAllowedCalendars(from: allCalendars)

    if verbose {
        print("Selected calendars:")
        for cal in selectedCalendars {
            print("- \(cal.title)")
        }
        print("-----")
    }

    if selectedCalendars.isEmpty {
        print("No matching calendars found.")
        return
    }

    let now = Date()
    var calendar = Calendar.current
    calendar.locale = Locale(identifier: "en_US_POSIX")

    let endOfWindow = now.addingTimeInterval(timeIntervalToFetch)

    let predicate = store.predicateForEvents(withStart: now, end: endOfWindow, calendars: selectedCalendars)
    let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HH:mm"
    timeFormatter.locale = Locale(identifier: "en_US_POSIX")

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")

    for event in events where event.endDate > now {
        let startTime = timeFormatter.string(from: event.startDate)
        let endTime = timeFormatter.string(from: event.endDate)
        let dateString = dateFormatter.string(from: event.startDate)
        let title = (event.title ?? "(No Title)")
            .replacingOccurrences(of: "\u{00A0}", with: " ")    // Replace non-breaking space
            .replacingOccurrences(of: "\u{2013}", with: "-")    // Replace en dash

        if CommandLine.arguments.contains("--relative") {
            let interval = event.startDate.timeIntervalSince(now)
            let minutes = Int(interval / 60)
            let hours = minutes / 60
            let mins = minutes % 60
            let relativeString: String
            if interval < 0 {
                relativeString = "started \(-minutes) min ago"
            } else if hours > 0 {
                relativeString = "in \(hours)h \(mins)m"
            } else {
                relativeString = "in \(mins)m"
            }
            print("\(title) | \(relativeString)")
        } else {
            print("\(dateString) \(startTime)-\(endTime) | \(title)")
        }
    }
}

if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { granted, error in
        if granted {
            fetchEvents()
        } else {
            print("Access denied or error: \(error?.localizedDescription ?? "unknown error")")
        }
        semaphore.signal()
    }
} else {
    store.requestAccess(to: .event) { granted, error in
        if granted {
            fetchEvents()
        } else {
            print("Access denied or error: \(error?.localizedDescription ?? "unknown error")")
        }
        semaphore.signal()
    }
}

_ = semaphore.wait(timeout: .distantFuture)


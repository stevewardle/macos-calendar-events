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

struct CalendarEventOutput: Codable {
    let title: String
    let calendar: String
    let start: Int
    let end: Int
    let active: Bool
}

struct CLIConfig {
    let timeInterval: TimeInterval
    let verbose: Bool
    let relative: Bool
    let json: Bool
    let activeOnly: Bool
}

let store = EKEventStore()
let semaphore = DispatchSemaphore(value: 0)

let defaultTimeInterval: TimeInterval = 24 * 60 * 60 // 1 day in seconds

func parseTimeArgument(_ arg: String) -> TimeInterval? {
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
        default: return nil
        }
    }
    return nil
}

func parseCLIConfig() -> CLIConfig {
    var timeInterval = defaultTimeInterval
    var verbose = false
    var relative = false
    var json = false
    var activeOnly = false

    for arg in CommandLine.arguments.dropFirst() {
        switch arg {
        case "-v", "--verbose":
            verbose = true
        case "--relative":
            relative = true
        case "--json":
            json = true
        case "--active-only":
            activeOnly = true
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            if arg.hasPrefix("-") {
                fputs("Unknown option: \(arg)\n", stderr)
                printUsage()
                exit(1)
            } else if let parsed = parseTimeArgument(arg) {
                timeInterval = parsed
            } else {
                fputs("Invalid time window: \(arg)\n", stderr)
                printUsage()
                exit(1)
            }
        }
    }

    return CLIConfig(
        timeInterval: timeInterval,
        verbose: verbose,
        relative: relative,
        json: json,
        activeOnly: activeOnly
    )
}

func printUsage() {
    let usage = """
    Usage: calendar_events [time_window] [options]

    Time window examples: 1d, 2h, 30m, 3

    Options:
      --relative      Show time until/since each event starts
      --json          Output events as a JSON array
      --active-only   Only show events happening right now
      -v, --verbose   Print calendar selection details to stderr
      -h, --help      Show this help message
    """
    print(usage)
}

func log(_ message: String, config: CLIConfig) {
    if config.verbose {
        fputs("\(message)\n", stderr)
    }
}

func normalizeTitle(_ title: String?) -> String {
    (title ?? "(No Title)")
        .replacingOccurrences(of: "\u{00A0}", with: " ") // non-breaking space
        .replacingOccurrences(of: "\u{2013}", with: "-") // en dash
}

func isEventActive(_ event: EKEvent, now: Date) -> Bool {
    event.startDate <= now && event.endDate > now
}

func loadAllowedCalendars(from allCalendars: [EKCalendar], config: CLIConfig) -> [EKCalendar] {
    guard let binaryDir = getExecutablePath() else {
        log("Could not resolve binary path. Using all calendars.", config: config)
        return allCalendars
    }

    let fileURL = binaryDir.appendingPathComponent("calendars.txt")
    log("Looking for calendars.txt at: \(fileURL.path)", config: config)

    do {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let allowed = Set(lines)
        let selected = allCalendars.filter { allowed.contains($0.title) }

        if selected.isEmpty {
            log("No matching calendars found in calendars.txt. Using all calendars instead.", config: config)
            return allCalendars
        }

        return selected
    } catch {
        log("No calendars.txt found or failed to read it. Using all calendars.", config: config)
        return allCalendars
    }
}

func printJSON(_ events: [CalendarEventOutput]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(events),
          let json = String(data: data, encoding: .utf8) else {
        fputs("Failed to encode events as JSON\n", stderr)
        exit(1)
    }
    print(json)
}

func fetchEvents(config: CLIConfig) {
    let allCalendars = store.calendars(for: .event)
    let selectedCalendars = loadAllowedCalendars(from: allCalendars, config: config)

    if config.verbose {
        fputs("Selected calendars:\n", stderr)
        for cal in selectedCalendars {
            fputs("- \(cal.title)\n", stderr)
        }
        fputs("-----\n", stderr)
    }

    if selectedCalendars.isEmpty {
        if config.json {
            printJSON([])
        } else {
            print("No matching calendars found.")
        }
        return
    }

    let now = Date()
    let endOfWindow = now.addingTimeInterval(config.timeInterval)
    let predicate = store.predicateForEvents(withStart: now, end: endOfWindow, calendars: selectedCalendars)
    let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HH:mm"
    timeFormatter.locale = Locale(identifier: "en_US_POSIX")

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")

    var jsonOutput: [CalendarEventOutput] = []

    for event in events where event.endDate > now {
        if event.isAllDay {
            continue
        }

        let active = isEventActive(event, now: now)
        if config.activeOnly && !active {
            continue
        }

        let title = normalizeTitle(event.title)

        if config.json {
            jsonOutput.append(
                CalendarEventOutput(
                    title: title,
                    calendar: event.calendar.title,
                    start: Int(event.startDate.timeIntervalSince1970),
                    end: Int(event.endDate.timeIntervalSince1970),
                    active: active
                )
            )
            continue
        }

        if config.relative {
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
            let startTime = timeFormatter.string(from: event.startDate)
            let endTime = timeFormatter.string(from: event.endDate)
            let dateString = dateFormatter.string(from: event.startDate)
            print("\(dateString) \(startTime)-\(endTime) | \(title)")
        }
    }

    if config.json {
        printJSON(jsonOutput)
    }
}

let config = parseCLIConfig()

if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { granted, error in
        if granted {
            fetchEvents(config: config)
        } else {
            fputs("Access denied or error: \(error?.localizedDescription ?? "unknown error")\n", stderr)
            exit(1)
        }
        semaphore.signal()
    }
} else {
    store.requestAccess(to: .event) { granted, error in
        if granted {
            fetchEvents(config: config)
        } else {
            fputs("Access denied or error: \(error?.localizedDescription ?? "unknown error")\n", stderr)
            exit(1)
        }
        semaphore.signal()
    }
}

_ = semaphore.wait(timeout: .distantFuture)

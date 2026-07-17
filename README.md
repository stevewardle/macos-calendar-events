# MacOS Calendar Events

This is a small Swift script that compiles into a binary to display upcoming events from the macOS Calendar app. It's designed for integration with [SketchyBar](https://github.com/FelixKratz/SketchyBar) but can be used anywhere.

Unlike tools like iCalBuddy, this script avoids common macOS TCC (Transparency, Consent, and Control) permission issues by using the native EventKit framework.

## 🛠️ Compilation

You only need to compile the Swift script once:

```bash
swiftc CalendarEvents.swift -o ~/.config/bin/utils/calendar_events
```

You can change the output path or binary name as needed.

## 🔖 Selecting Calendars

Create a `calendars.txt` file in the same directory as the compiled script, listing the names of the calendars you want to include — one per line:

```text
calendar A
calendar B
```

Only events from calendars listed in this file will be shown. If this file is not present, all calendars will be used.

## Usage of compiled binary

You can pass a time window as a command-line argument when running the compiled binary.
For example, to fetch events for the next 2 hours:

```bash
~/.config/bin/utils/calendar_events 2h
```

You can also pass the number of days to fetch. For example, to fetch events for today and the next 2 days (3 days total):

```bash
~/.config/bin/utils/calendar_events 3
```

If no argument is provided, the default is 1 day. See [my sketchybar config](https://github.com/zigotica/tilde/tree/master/.config/sketchybar/items/ical) for an example of this.

### Options

```bash
calendar_events [time_window] [options]
```

- `--relative` — show time until/since each event starts
- `--json` — output events as a JSON array
- `--active-only` — only show events happening right now
- `-v`, `--verbose` — print calendar selection details to stderr
- `-h`, `--help` — show usage

Examples:

```bash
# Events currently in progress, as JSON
calendar_events 1h --active-only --json

# Upcoming events with relative times (SketchyBar)
calendar_events 1h --relative
```

## Output

By default, the binary prints upcoming events to stdout in this format:

```text
2026-07-17 09:00-10:00 | Daily Standup
2026-07-17 14:30-15:00 | Design Review
```

With `--json`, output looks like:

```json
[
  {
    "active": true,
    "calendar": "Calendar",
    "end": 1721238300,
    "start": 1721234567,
    "title": "Daily Standup"
  }
]
```

Use the output as input for your SketchyBar plugin or other automation scripts. Enjoy a TCC-free, native way to display calendar events on your Mac!

## 🧪 Debugging

To list all available calendar names (to help you build calendars.txt), uncomment the debug print section in the script:

```swift
for cal in store.calendars(for: .event) {
    print("- \(cal.title)")
}
```

Then recompile and run the binary to see the output.

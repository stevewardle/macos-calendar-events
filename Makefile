calendar_events: CalendarEvents.swift
	swiftc $< -o $@

clean:
	rm -f calendar_events

.PHONY: clean

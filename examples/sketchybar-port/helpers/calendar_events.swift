import EventKit
import Foundation

let store = EKEventStore()
let semaphore = DispatchSemaphore(value: 0)

func fetchAndPrintEvents() {
    let now = Date()
    guard let endDate = Calendar.current.date(byAdding: .day, value: 7, to: now) else {
        semaphore.signal()
        return
    }
    let predicate = store.predicateForEvents(withStart: now, end: endDate, calendars: nil)
    let events = store.events(matching: predicate)

    let dateFmt = DateFormatter()
    dateFmt.dateFormat = "yyyy-MM-dd"
    let timeFmt = DateFormatter()
    timeFmt.dateFormat = "HH:mm"

    for event in events {
        let title = (event.title ?? "").replacingOccurrences(of: "|", with: "-")
        let date = dateFmt.string(from: event.startDate)
        let time = event.isAllDay ? "All day" : timeFmt.string(from: event.startDate)
        let location = (event.location ?? "").replacingOccurrences(of: "|", with: "-")
        print("\(title)|\(date)|\(time)|\(location)")
    }
    semaphore.signal()
}

func requestAndFetch() {
    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents { granted, _ in
            if granted { fetchAndPrintEvents() }
            else { semaphore.signal() }
        }
    } else {
        store.requestAccess(to: .event) { granted, _ in
            if granted { fetchAndPrintEvents() }
            else { semaphore.signal() }
        }
    }
}

// Check authorization status first to avoid unnecessary prompts
let status: EKAuthorizationStatus
if #available(macOS 14.0, *) {
    status = EKEventStore.authorizationStatus(for: .event)
} else {
    status = EKEventStore.authorizationStatus(for: .event)
}

switch status {
case .authorized:
    fetchAndPrintEvents()
    semaphore.wait()
case .fullAccess:
    fetchAndPrintEvents()
    semaphore.wait()
case .notDetermined:
    requestAndFetch()
    semaphore.wait()
default:
    // Denied or restricted - exit silently
    break
}

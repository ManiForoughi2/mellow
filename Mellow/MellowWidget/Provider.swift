import WidgetKit
import SwiftUI

struct MellowEntry: TimelineEntry {
    let date: Date
    let snapshot: MellowSnapshot
}

struct MellowProvider: TimelineProvider {
    func placeholder(in context: Context) -> MellowEntry {
        MellowEntry(date: Date(), snapshot: .demo)
    }

    func getSnapshot(in context: Context, completion: @escaping (MellowEntry) -> Void) {
        let snapshot = context.isPreview ? .demo : MellowSharedStore.load()
        completion(MellowEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MellowEntry>) -> Void) {
        let now = Date()
        let entry = MellowEntry(date: now, snapshot: MellowSharedStore.load())
        // re-read shared store every 15 min; app can also force reload via WidgetCenter
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

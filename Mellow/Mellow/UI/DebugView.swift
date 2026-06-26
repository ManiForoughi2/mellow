import SwiftUI

// packet inspector + decoded-record feed: raw TX/RX hex + structured decode per inner record
struct DebugView: View {
    @EnvironmentObject var store: RingStore
    @State private var mode = Mode.records

    enum Mode: String, CaseIterable { case records = "Records", packets = "Packets" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                switch mode {
                case .records: recordsList
                case .packets: packetsList
                }
            }
            .navigationTitle("Debug")
        }
    }

    private var recordsList: some View {
        List(store.recentRecords) { rec in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(rec.tagHex).font(.system(.caption, design: .monospaced)).bold()
                    Text(rec.typeName).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("rt \(rec.ringTime)").font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(rec.fields.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text(rec.fields[i].0).font(.caption2).foregroundStyle(.secondary)
                        Text(rec.fields[i].1).font(.system(.caption2, design: .monospaced)).lineLimit(2)
                    }
                }
                if let ev = rec.eventTimeMs {
                    Text("event \(Date(timeIntervalSince1970: Double(ev)/1000).formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.plain)
    }

    private var packetsList: some View {
        List(store.packetLog) { p in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: p.direction == .tx ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(p.direction == .tx ? .blue : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.hex).font(.system(.caption2, design: .monospaced)).lineLimit(3)
                    HStack {
                        if !p.note.isEmpty { Text(p.note).font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Text(p.date.formatted(date: .omitted, time: .standard))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .listStyle(.plain)
    }
}

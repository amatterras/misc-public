// THEapp home-screen widgets: today's and tomorrow's tasks and calendar
// entries. They only READ widget_snapshot.json, which THEapp writes into
// the App Group folder whenever tasks or the calendar change (see
// lib/features/widgets/widget_snapshot.dart). The snapshot is derived,
// display-only data; nothing here can change THEapp's records.
//
// Tapping an item opens it (theapp://open?task=… or ?day=…).
//
// STATUS: compiled in the cloud build only; not yet seen on a device.
import SwiftUI
import WidgetKit

// MARK: snapshot

struct SnapshotItem: Decodable, Hashable {
  let kind: String
  let title: String
  let time: String?
  let done: Bool
  let color: UInt32
  let link: String
}

struct SnapshotDay: Decodable, Hashable {
  let date: String
  let title: String
  let link: String
  let total: Int
  let items: [SnapshotItem]
  /// Handwriting on that day (base64 PNG), if any.
  let ink: String?
}

struct Snapshot: Decodable {
  let version: Int
  let days: [SnapshotDay]

  static func load() -> Snapshot? {
    guard
      let folder = AppGroup.container,
      let data = try? Data(contentsOf: folder.appendingPathComponent("widget_snapshot.json")),
      let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
      snapshot.version == 1
    else { return nil }
    return snapshot
  }

  /// Days as of [now]: a snapshot written yesterday still shows the right
  /// "Today" (its "Tomorrow"), and never shows a day that has passed.
  func days(at now: Date) -> [SnapshotDay] {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    let today = formatter.string(from: now)
    let kept = days.filter { $0.date >= today }
    return kept.enumerated().map { index, day in
      SnapshotDay(
        date: day.date, title: index == 0 && day.date == today ? "Today" : day.title,
        link: day.link, total: day.total, items: day.items, ink: day.ink)
    }
  }
}

// MARK: timeline

struct DaysEntry: TimelineEntry {
  let date: Date
  let days: [SnapshotDay]
  let missing: Bool
}

struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> DaysEntry {
    DaysEntry(date: Date(), days: Self.sample, missing: false)
  }

  func getSnapshot(in context: Context, completion: @escaping (DaysEntry) -> Void) {
    completion(entry(at: Date(), preview: context.isPreview))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<DaysEntry>) -> Void) {
    let now = Date()
    // THEapp asks for a reload on every change; the extra entry at
    // midnight moves "Tomorrow" to "Today" even if the app is not opened.
    let calendar = Calendar.autoupdatingCurrent
    let startOfToday = calendar.startOfDay(for: now)
    let midnight = (calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now)
      .addingTimeInterval(5)
    completion(
      Timeline(
        entries: [entry(at: now, preview: false), entry(at: midnight, preview: false)],
        policy: .after(midnight)))
  }

  private func entry(at date: Date, preview: Bool) -> DaysEntry {
    if let snapshot = Snapshot.load() {
      return DaysEntry(date: date, days: snapshot.days(at: date), missing: false)
    }
    return DaysEntry(date: date, days: preview ? Self.sample : [], missing: !preview)
  }

  static let sample: [SnapshotDay] = [
    SnapshotDay(
      date: "", title: "Today", link: "theapp://open", total: 3,
      items: [
        SnapshotItem(
          kind: "event", title: "Team meeting", time: "09:30", done: false,
          color: 0xFF4D_8FD6, link: "theapp://open"),
        SnapshotItem(
          kind: "task", title: "Buy groceries", time: nil, done: false,
          color: 0xFF79_B85A, link: "theapp://open"),
      ], ink: nil),
    SnapshotDay(date: "", title: "Tomorrow", link: "theapp://open", total: 0, items: [], ink: nil),
  ]
}

// MARK: views

extension Color {
  init(argb: UInt32) {
    self.init(
      .sRGB,
      red: Double((argb >> 16) & 0xFF) / 255,
      green: Double((argb >> 8) & 0xFF) / 255,
      blue: Double(argb & 0xFF) / 255,
      opacity: Double((argb >> 24) & 0xFF) / 255)
  }
}

struct ItemRow: View {
  let item: SnapshotItem

  var body: some View {
    Link(destination: URL(string: item.link) ?? URL(string: "theapp://open")!) {
      HStack(spacing: 6) {
        if item.kind == "task" {
          Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 11))
            .foregroundColor(item.done ? .green : Color(argb: item.color))
        } else {
          RoundedRectangle(cornerRadius: 1.5)
            .fill(Color(argb: item.color))
            .frame(width: 3, height: 12)
        }
        if let time = item.time {
          Text(time)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundColor(.secondary)
        }
        Text(item.title)
          .font(.system(size: 12))
          .strikethrough(item.done)
          .foregroundColor(item.done ? .secondary : .primary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
    }
  }
}

struct DayColumn: View {
  let day: SnapshotDay
  let rows: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Link(destination: URL(string: day.link) ?? URL(string: "theapp://open")!) {
        Text(day.title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(.accentColor)
      }
      if day.items.isEmpty {
        Text("Nothing planned")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      }
      ForEach(Array(day.items.prefix(shown).enumerated()), id: \.offset) { _, item in
        ItemRow(item: item)
      }
      if more > 0 {
        Text("+\(more) more")
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(.secondary)
      }
      if let ink = day.ink, let data = Data(base64Encoded: ink), let image = UIImage(data: data) {
        // The handwriting drawn on this day in the Calendar.
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Rows for items; one is given up for "+N more" when not all fit.
  private var shown: Int {
    day.total > rows ? max(rows - 1, 0) : min(rows, day.items.count)
  }

  private var more: Int { max(day.total - shown, 0) }
}

struct TheAppWidgetView: View {
  @Environment(\.widgetFamily) var family
  let entry: DaysEntry

  var body: some View {
    content
      .widgetBackground(Color(UIColor.systemBackground))
  }

  @ViewBuilder private var content: some View {
    if entry.missing {
      VStack(alignment: .leading, spacing: 4) {
        Text("misc.").font(.system(size: 13, weight: .semibold))
        Text("Open misc. once to show today and tomorrow here.")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      switch family {
      case .systemSmall:
        if let today = entry.days.first {
          // Small widgets open one link for the whole widget.
          DayColumn(day: today, rows: 5).widgetURL(URL(string: today.link))
        }
      case .systemLarge:
        VStack(alignment: .leading, spacing: 10) {
          ForEach(entry.days.prefix(2), id: \.self) { DayColumn(day: $0, rows: 8) }
        }
      default:
        HStack(alignment: .top, spacing: 12) {
          ForEach(entry.days.prefix(2), id: \.self) { DayColumn(day: $0, rows: 5) }
        }
      }
    }
  }
}

extension View {
  /// iOS 17 wants widget backgrounds declared; older versions just draw it.
  @ViewBuilder func widgetBackground(_ color: Color) -> some View {
    if #available(iOS 17.0, *) {
      containerBackground(for: .widget) { color }
    } else {
      padding().background(color)
    }
  }
}

// MARK: widget

@main
struct TheAppWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "TheAppDays", provider: Provider()) { entry in
      TheAppWidgetView(entry: entry)
    }
    .configurationDisplayName("Today & Tomorrow")
    .description("Your tasks and calendar for today and tomorrow.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

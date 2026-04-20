import WidgetKit
import SwiftUI

/// Watch-face complication bundle for PawMesh.
///
/// Shows the closest assigned dog's distance + fix-age tier directly on
/// the watch face. Tapping launches into the compass page for that dog
/// via the `pawmesh://dog/<nodeNum>` URL scheme.
@main
struct DogTrackerWatchComplicationBundle: WidgetBundle {
    var body: some Widget {
        DogTrackerClosestWidget()
    }
}

struct DogTrackerClosestWidget: Widget {
    let kind = "DogTrackerClosestWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ComplicationProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Closest Dog")
        .description("Shows distance and fix age of your nearest tracker.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

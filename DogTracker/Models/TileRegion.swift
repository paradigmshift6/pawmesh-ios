import Foundation
import SwiftData

/// A pre-downloaded offline map region (one MBTiles file in Documents).
@Model
final class TileRegion {
    var name: String

    /// Filename (not full path) of the .mbtiles file inside the app's
    /// Documents/TileRegions directory. Resolved at use time so the path
    /// stays valid across iOS container moves.
    var filename: String

    var minLatitude: Double
    var maxLatitude: Double
    var minLongitude: Double
    var maxLongitude: Double

    var minZoom: Int
    var maxZoom: Int

    var sizeBytes: Int64
    var downloadedAt: Date

    /// `MapSource.id` the tiles were downloaded from. Optional so SwiftData can
    /// lightweight-migrate existing regions; `nil` means a pre-1.3 region, which
    /// was always USGS US Topo (see `MapSource.with(id:)`).
    var sourceID: String?

    init(
        name: String,
        filename: String,
        minLatitude: Double,
        maxLatitude: Double,
        minLongitude: Double,
        maxLongitude: Double,
        minZoom: Int,
        maxZoom: Int,
        sizeBytes: Int64,
        sourceID: String? = nil,
        downloadedAt: Date = .now
    ) {
        self.name = name
        self.filename = filename
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.sizeBytes = sizeBytes
        self.sourceID = sourceID
        self.downloadedAt = downloadedAt
    }

    /// The `MapSource` these tiles came from.
    var source: MapSource { MapSource.with(id: sourceID) }
}

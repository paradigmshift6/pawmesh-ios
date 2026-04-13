import Foundation
import OSLog

/// Downloads USGS US Topo raster tiles for a bounding box + zoom range and
/// writes them into an MBTiles file. Runs as a Swift concurrency `Task`, so
/// callers can cancel or observe progress.
///
/// USGS tile endpoint (ArcGIS REST, XYZ convention):
///   https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}
///
/// MBTiles stores tiles in TMS convention (Y origin at the bottom), so we
/// flip Y when writing:  tmsY = (1 << z) - 1 - xyzY
actor TileDownloader {

    private let log = Logger(subsystem: "com.example.DogTracker", category: "TileDownloader")
    private let session: URLSession
    private let baseURL = "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile"

    /// Download progress: number of tiles completed / total.
    var completed: Int = 0
    var total: Int = 0
    var isCancelled: Bool = false

    init() {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    /// Download tiles and write them to an MBTiles file at `outputURL`.
    /// Returns the file size in bytes.
    func download(
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double,
        minZoom: Int, maxZoom: Int,
        outputURL: URL,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> Int64 {
        // Calculate all tile coordinates
        var tiles: [(z: Int, x: Int, y: Int)] = []
        for z in minZoom...maxZoom {
            let (minX, minY) = tileXY(lat: maxLat, lon: minLon, zoom: z) // NW corner
            let (maxX, maxY) = tileXY(lat: minLat, lon: maxLon, zoom: z) // SE corner
            for x in minX...maxX {
                for y in minY...maxY {
                    tiles.append((z, x, y))
                }
            }
        }

        total = tiles.count
        completed = 0
        isCancelled = false

        log.info("downloading \(tiles.count) tiles, z\(minZoom)–\(maxZoom)")

        let writer = try MBTilesWriter(fileURL: outputURL)
        try writer.writeMetadata([
            ("name", "USGS Topo"),
            ("format", "png"),
            ("type", "overlay"),
            ("description", "USGS US Topo tiles"),
            ("bounds", "\(minLon),\(minLat),\(maxLon),\(maxLat)"),
            ("minzoom", "\(minZoom)"),
            ("maxzoom", "\(maxZoom)"),
        ])

        try writer.beginTransaction()

        // Download in batches to limit concurrency
        let batchSize = 8
        for batch in stride(from: 0, to: tiles.count, by: batchSize) {
            if isCancelled { break }

            let end = min(batch + batchSize, tiles.count)
            let slice = tiles[batch..<end]

            try await withThrowingTaskGroup(of: (Int, Int, Int, Data).self) { group in
                for (z, x, y) in slice {
                    group.addTask { [self] in
                        let data = try await self.fetchTile(z: z, x: x, y: y)
                        return (z, x, y, data)
                    }
                }
                for try await (z, x, y, data) in group {
                    // Convert XYZ Y to TMS Y
                    let tmsY = (1 << z) - 1 - y
                    try writer.insertTile(zoom: z, column: x, row: tmsY, data: data)
                    completed += 1
                    progress(completed, total)
                }
            }
        }

        try writer.commitTransaction()

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        return (attrs[.size] as? Int64) ?? 0
    }

    func cancel() {
        isCancelled = true
    }

    // MARK: - Private

    private func fetchTile(z: Int, x: Int, y: Int) async throws -> Data {
        let url = URL(string: "\(baseURL)/\(z)/\(y)/\(x)")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TileDownloadError.httpError(z: z, x: x, y: y)
        }
        return data
    }

    /// Convert lat/lon to tile X,Y at the given zoom (XYZ / "slippy map" convention).
    private func tileXY(lat: Double, lon: Double, zoom: Int) -> (x: Int, y: Int) {
        let n: Double = Double(1 << zoom)
        let xVal: Int = Int(floor((lon + 180.0) / 360.0 * n))
        let latRad: Double = lat * .pi / 180.0
        let tanPart: Double = tan(latRad) + 1.0 / cos(latRad)
        let yRaw: Double = (1.0 - Darwin.log(tanPart) / .pi) / 2.0 * n
        let yVal: Int = Int(floor(yRaw))
        let maxTile: Int = Int(n) - 1
        return (x: max(0, min(maxTile, xVal)),
                y: max(0, min(maxTile, yVal)))
    }
}

enum TileDownloadError: Error, LocalizedError {
    case httpError(z: Int, x: Int, y: Int)
    case noDocumentsDirectory

    var errorDescription: String? {
        switch self {
        case .httpError(let z, let x, let y): "Failed to download tile z=\(z) x=\(x) y=\(y)"
        case .noDocumentsDirectory: "Unable to access Documents directory"
        }
    }
}

import Foundation
import CoreLocation

/// A simple geographic bounding box, used to pick a tile source by location.
struct GeoBoundingBox: Equatable, Sendable {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    func contains(_ coord: CLLocationCoordinate2D) -> Bool {
        coord.latitude >= minLat && coord.latitude <= maxLat &&
        coord.longitude >= minLon && coord.longitude <= maxLon
    }
}

/// A topographic raster tile provider.
///
/// The app ships three. All serve 256px tiles in the XYZ / "slippy map"
/// convention (top-left origin), so the same `TileDownloader` Y-flip-to-TMS
/// logic works for every source — only the URL template and zoom range differ:
///
///   - **USGS US Topo** — United States, public domain.
///   - **basemap.at** — Austria, CC-BY 4.0. Best Alpine detail (z19).
///   - **BKG TopPlusOpen** — worldwide (detailed for Germany / Central Europe),
///     Datenlizenz Deutschland 2.0. Doubles as the global fallback.
///
/// All three permit offline / bulk tile export, so the app's region-download
/// feature is on solid licensing footing.
struct MapSource: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    /// XYZ tile URL template with `{z}`/`{x}`/`{y}` placeholders. MapLibre
    /// substitutes these directly; the downloader substitutes them itself.
    let tileURLTemplate: String
    let minZoom: Int
    let maxZoom: Int
    /// Short attribution shown on the map and in Settings. Required by the
    /// CC-BY / dl-de licenses (USGS is public domain but we credit it too).
    let attribution: String
    /// Tappable attribution / license link.
    let attributionURL: URL?
    /// Bounding boxes used for automatic selection — a coarse polygon expressed
    /// as a union of rectangles. Empty = worldwide (the fallback source).
    let coverage: [GeoBoundingBox]

    /// `true` for the worldwide fallback source (no bounded coverage).
    var isWorldwide: Bool { coverage.isEmpty }

    /// Whether this source's coverage includes `coord`.
    func covers(_ coord: CLLocationCoordinate2D) -> Bool {
        coverage.contains { $0.contains(coord) }
    }
}

extension MapSource {
    static let usgs = MapSource(
        id: "usgs",
        displayName: "USGS US Topo",
        tileURLTemplate: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}",
        minZoom: 1,
        maxZoom: 16,
        attribution: "USGS The National Map",
        attributionURL: URL(string: "https://www.usgs.gov/programs/national-geospatial-program/national-map"),
        // Continental US + Alaska + Hawaii (rough bounding box).
        coverage: [GeoBoundingBox(minLat: 15.0, maxLat: 72.0, minLon: -179.5, maxLon: -64.0)]
    )

    static let basemapAT = MapSource(
        id: "basemap_at",
        displayName: "basemap.at (Austria)",
        tileURLTemplate: "https://maps.wien.gv.at/basemap/geolandbasemap/normal/google3857/{z}/{y}/{x}.png",
        minZoom: 1,
        maxZoom: 19,
        attribution: "© basemap.at",
        attributionURL: URL(string: "https://www.basemap.at"),
        // Austria, approximated as two rectangles. A single box spanning Vienna
        // (48.2°N) would also swallow Munich (48.1°N) and Bavaria, where
        // basemap.at serves only blank tiles. Split by longitude so the
        // northern bound can stay low in the west (Tyrol) and rise in the east
        // (Vienna/Linz). Tuned to exclude every major German city; a few tiny
        // Bavarian Alpine border towns may still fall inside — those users can
        // switch to TopPlusOpen in Settings.
        coverage: [
            GeoBoundingBox(minLat: 46.37, maxLat: 47.75, minLon: 9.53, maxLon: 13.05),  // Vorarlberg, Tyrol, Carinthia
            GeoBoundingBox(minLat: 46.37, maxLat: 48.5,  minLon: 12.9, maxLon: 17.16),  // Salzburg, Styria, Linz, Vienna
        ]
    )

    static let bkgTopPlus = MapSource(
        id: "bkg_topplus",
        displayName: "TopPlusOpen (Germany)",
        tileURLTemplate: "https://sgx.geodatenzentrum.de/wmts_topplus_open/tile/1.0.0/web/default/WEBMERCATOR/{z}/{y}/{x}.png",
        minZoom: 1,
        maxZoom: 18,
        attribution: "© BKG dl-de/by-2-0",
        attributionURL: URL(string: "https://www.bkg.bund.de"),
        // Worldwide — also the fallback for anywhere not covered above.
        coverage: []
    )

    /// Every selectable source, in display order.
    static let all: [MapSource] = [.usgs, .basemapAT, .bkgTopPlus]

    /// Stored value of the "automatic selection" mode for the Settings picker.
    static let autoModeID = "auto"

    /// Look up a source by id. A nil id is a pre-1.3 offline region (those were
    /// always USGS); an unknown id also falls back to USGS conservatively.
    static func with(id: String?) -> MapSource {
        all.first { $0.id == id } ?? .usgs
    }

    /// Resolve the best source for a coordinate:
    ///   Austria → basemap.at, US → USGS, everywhere else → BKG (worldwide).
    /// When the coordinate is unknown, fall back to the worldwide source so the
    /// map is never blank.
    static func automatic(for coord: CLLocationCoordinate2D?) -> MapSource {
        guard let coord, CLLocationCoordinate2DIsValid(coord),
              !(coord.latitude == 0 && coord.longitude == 0) else {
            return .bkgTopPlus
        }
        if basemapAT.covers(coord) { return .basemapAT }
        if usgs.covers(coord) { return .usgs }
        return .bkgTopPlus
    }

    /// Resolve the effective online source from the persisted Settings mode
    /// (`autoModeID` or a specific source id) plus the best-known coordinate.
    ///
    /// When the mode is automatic but no coordinate is known yet (no GPS fix and
    /// no markers), fall back to `fallbackID` rather than the worldwide source —
    /// otherwise a US user would briefly see low-detail worldwide tiles instead
    /// of USGS on cold launch / with location denied. Callers pass the last
    /// source that auto-resolved by location so the default tracks where you are.
    static func resolve(mode: String, coordinate: CLLocationCoordinate2D?,
                        fallbackID: String = MapSource.usgs.id) -> MapSource {
        if mode != autoModeID { return all.first { $0.id == mode } ?? .bkgTopPlus }
        if coordinate != nil { return automatic(for: coordinate) }
        return all.first { $0.id == fallbackID } ?? .usgs
    }
}

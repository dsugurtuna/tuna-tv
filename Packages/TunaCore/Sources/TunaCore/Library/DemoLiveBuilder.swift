import Foundation

enum DemoLiveBuilder {
    /// One provider record per variant code; "+1" feeds carry their own EPG id.
    static func items() -> [RawItem] {
        var items: [RawItem] = []
        var number = 100
        for spec in DemoSpecs.channels {
            var rng = DemoRNG("live/\(spec.epgID)")
            let separator = spec.prefix.isEmpty ? "" : rng.pick([": ", ": ", ": ", " | ", "| "])
            let head = spec.prefix.isEmpty ? spec.name : spec.prefix + separator + spec.name
            for (offset, code) in spec.codes.enumerated() {
                let name: String
                var epg = spec.epgID
                var catchup: Int? = spec.catchupDays > 0 ? spec.catchupDays : nil
                var seed = spec.seed
                switch code {
                case "U": name = head + rng.pick([" 4K", " UHD"])
                case "F": name = head + " FHD"
                case "H": name = head + " HD"
                case "S": name = head + " SD"
                case "B": name = head + rng.pick([" HD (Backup)", " (Backup)", " FHD (Backup)"])
                case "P":
                    name = head + " +1"
                    epg = spec.timeshiftEPGID
                    catchup = nil
                    seed = DemoText.slug(spec.name + " +1")
                default: name = head
                }
                number += 1
                items.append(RawItem(
                    ref: StreamRef(providerID: DemoContent.providerID, kind: .live,
                                   streamID: DemoCatalogBuilder.liveStreamID(spec.index, variant: offset)),
                    name: name, categoryID: spec.categoryID,
                    categoryName: DemoTables.liveCategories.first { $0.id == spec.categoryID }?.name,
                    iconURL: "demo://channel/\(seed)", channelNumber: number, epgChannelID: epg, catchupDays: catchup))
            }
        }
        return items
    }

    /// Every EPG key the demo provider exposes, with the channel spec it belongs to and the timeshift in hours.
    static var guideKeys: [(key: String, spec: DemoChannelSpec, shiftHours: Int)] {
        var keys: [(key: String, spec: DemoChannelSpec, shiftHours: Int)] = []
        for spec in DemoSpecs.channels {
            keys.append((spec.epgID, spec, 0))
            if spec.codes.contains("P") { keys.append((spec.timeshiftEPGID, spec, 1)) }
        }
        return keys
    }
}

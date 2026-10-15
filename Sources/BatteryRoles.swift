// Which half a Battery Level belongs to, from its User Description and its siblings'.
//
// Two layouts are in use on ZMK splits with the battery level proxy:
//   upstream ZMK:  plain level = central (left), described "Peripheral 0" = right
//   Totem fork:    plain level = right,          described "Left"         = central (left)
// (the fork swaps them so Mighty Mitts, which fills its slots in callback order, shows them in
// the right places). A plain level is therefore the other half from its described sibling.
enum BatteryRoles {
    /// The half named by a description, or nil if it names neither.
    static func named(_ description: String) -> Half? {
        let text = description.lowercased()
        if text.contains("left") || text.contains("central") { return .left }
        if text.contains("right") || text.contains("peripheral") { return .right }
        return nil
    }

    /// The half for a level with `description` (nil = no User Description), given every level's
    /// description on the same device. Nil when it can't be decided, e.g. a device whose levels
    /// have no description at all, which is not a split keyboard.
    static func half(description: String?, siblings: [String?]) -> Half? {
        if let description { return named(description) }
        let namedHalves = siblings.compactMap { $0 }.compactMap(named)
        if namedHalves.contains(.left) && !namedHalves.contains(.right) { return .right }
        if namedHalves.contains(.right) && !namedHalves.contains(.left) { return .left }
        return nil
    }
}

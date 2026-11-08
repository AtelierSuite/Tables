import Foundation

/// The hidden rows and columns of a Numbers table. Numbers knows them not by
/// index but by the UUID each row and column keeps as it moves, listing the
/// state of each one hidden — by hand, by a filter, by a pivot table — on the
/// table model's `TST.HiddenStatesOwnerArchive`, sorted by UUID.
public enum NumbersHiddenStates {
    public typealias UUID = MergeOwners.UUID

    public struct Hidden: Equatable, Sendable {
        /// Hidden by hand, which can be undone.
        public var rows: Set<Int> = []
        public var columns: Set<Int> = []
        /// Hidden by a filter or a pivot table, which Numbers would only hide
        /// again.
        public var lockedRows: Set<Int> = []
        public var lockedColumns: Set<Int> = []
    }

    /// Each row's and column's UUID by its index, from the table's
    /// `TST.ColumnRowUIDMapArchive`; empty where it can't be told.
    public static func identifiers(_ map: ProtobufMessage?) -> (rows: [UUID], columns: [UUID]) {
        func list(sorted: Int, uidForIndex: Int) -> [UUID] {
            guard let map else { return [] }
            let uids = map.messages(sorted).compactMap { UUID($0) }
            let forIndex = map.uints(uidForIndex).map(Int.init)
            guard uids.count == map.messages(sorted).count, forIndex.allSatisfy({ $0 < uids.count }) else { return [] }
            return forIndex.map { uids[$0] }
        }
        return (list(sorted: 4, uidForIndex: 6), list(sorted: 1, uidForIndex: 3))
    }

    public static func hidden(in model: ProtobufMessage, rows: [UUID], columns: [UUID]) -> Hidden {
        var hidden = Hidden()
        guard let states = model.message(70)?.messages(2).first else { return hidden }
        func read(_ extent: ProtobufMessage?, identifiers: [UUID], into user: inout Set<Int>, locked: inout Set<Int>) {
            let indices = Dictionary(identifiers.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { $1 })
            for state in extent?.messages(2) ?? [] {
                guard let uid = UUID(state.message(1)), let index = indices[uid] else { continue }
                if state.bool(3) || state.bool(4) {
                    locked.insert(index)
                } else if state.bool(2) {
                    user.insert(index)
                }
            }
        }
        read(states.message(3), identifiers: rows, into: &hidden.rows, locked: &hidden.lockedRows)
        read(states.message(2), identifiers: columns, into: &hidden.columns, locked: &hidden.lockedColumns)
        return hidden
    }

    /// The table model with these rows and columns hidden by hand and no
    /// others, or nil if it keeps no hidden states to set.
    public static func model(
        _ model: ProtobufMessage, hidingRows rows: Set<Int>, columns: Set<Int>,
        rowIdentifiers: [UUID], columnIdentifiers: [UUID]
    ) -> ProtobufMessage? {
        guard var owner = model.message(70), var states = owner.messages(2).first,
              var columnExtent = states.message(2), var rowExtent = states.message(3) else { return nil }
        setHidden(rows, identifiers: rowIdentifiers, in: &rowExtent)
        setHidden(columns, identifiers: columnIdentifiers, in: &columnExtent)
        states.set(2, message: columnExtent)
        states.set(3, message: rowExtent)
        var allStates = owner.messages(2)
        allStates[0] = states
        owner.set(2, messages: allStates)
        var model = model
        model.set(70, message: owner)
        return model
    }

    private static func setHidden(_ indices: Set<Int>, identifiers: [UUID], in extent: inout ProtobufMessage) {
        let wanted = Set(indices.compactMap { $0 < identifiers.count ? identifiers[$0] : nil })
        var states: [UUID: ProtobufMessage] = [:]
        for state in extent.messages(2) {
            if let uid = UUID(state.message(1)) { states[uid] = state }
        }
        for uid in Set(states.keys).union(wanted) {
            var state = states[uid] ?? {
                var identifier = ProtobufMessage()
                identifier.set(1, uint: uid.lower)
                identifier.set(2, uint: uid.upper)
                var state = ProtobufMessage()
                state.set(1, message: identifier)
                return state
            }()
            if wanted.contains(uid) {
                state.set(2, bool: true)
            } else {
                state.set(2, [])
            }
            // A row or column shown again is dropped from the list, as
            // Numbers drops it, unless it is hidden some other way too.
            states[uid] = state.bool(3) || state.bool(4) || state.bool(2) ? state : nil
        }
        let sorted = states.keys.sorted { ($0.upper, $0.lower) < ($1.upper, $1.lower) }
        extent.set(2, messages: sorted.map { states[$0]! })
    }
}

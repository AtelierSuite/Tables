import AppKit
import Observation
import SwiftUI
import TablesEngine

/// The workbook as SwiftUI views hosted in the Mac app see it: kept up to
/// date as the document changes, with every write going through the
/// document so it is one undo step like any other edit.
@MainActor
@Observable
final class HostedWorkbook {
    private(set) var workbook: Workbook
    @ObservationIgnored private weak var document: WorkbookDocument?

    init(document: WorkbookDocument) {
        self.document = document
        workbook = document.workbook
    }

    func refresh() {
        guard let document, document.workbook != workbook else { return }
        workbook = document.workbook
    }

    var binding: Binding<Workbook> {
        Binding(
            get: { self.workbook },
            set: { [weak self] new in
                guard let document = self?.document else { return }
                document.edit { $0 = new }
                self?.refresh()
            }
        )
    }
}

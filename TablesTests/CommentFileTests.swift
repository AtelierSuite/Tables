import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

@Suite("Comments in files")
struct CommentFileTests {
    private func commentedWorkbook() -> Workbook {
        var sheet = Worksheet(name: "Sheet1")
        sheet[CellAddress(a1: "A1")!] = Cell(value: .number(1))
        var note = CellComment.note(author: "Ann", text: "Check this <total> & that")
        note.isAlwaysVisible = true
        sheet.comments[CellAddress(a1: "B2")!] = note
        var thread = CellComment.thread(author: "Bo", text: "Why is this high?")
        thread.entries.append(CellComment.Entry(author: "Ann", text: "Seasonal.", date: Date()))
        thread.isResolved = true
        sheet.comments[CellAddress(a1: "C3")!] = thread
        return Workbook(sheets: [sheet])
    }

    private func text(_ entries: [String: Data], _ path: String) -> String {
        String(decoding: entries[path] ?? Data(), as: UTF8.self)
    }

    @Test("Notes and threads are written as Excel writes them")
    func writing() throws {
        let entries = try ZipArchive.entries(in: XLSXWriter.data(from: commentedWorkbook()))
        let sheet = text(entries, "xl/worksheets/sheet1.xml")
        #expect(sheet.contains("<legacyDrawing r:id="))
        let relationships = text(entries, "xl/worksheets/_rels/sheet1.xml.rels")
        #expect(relationships.contains(CommentParts.commentsType))
        #expect(relationships.contains(CommentParts.vmlType))
        #expect(relationships.contains(CommentParts.threadType))
        let notes = text(entries, "xl/comments1.xml")
        #expect(notes.contains("<author>Ann</author>"))
        #expect(notes.contains("Check this &lt;total&gt; &amp; that"))
        #expect(notes.contains("[Threaded comment]"))
        let threads = text(entries, "xl/threadedComments/threadedComment1.xml")
        #expect(threads.contains("ref=\"C3\""))
        #expect(threads.contains("done=\"1\""))
        #expect(threads.contains("parentId="))
        #expect(text(entries, "xl/persons/person.xml").contains("displayName=\"Bo\""))
        #expect(text(entries, "xl/_rels/workbook.xml.rels").contains(CommentParts.personType))
        let vml = text(entries, "xl/drawings/vmlDrawing1.vml")
        #expect(vml.contains("<x:Row>1</x:Row><x:Column>1</x:Column><x:Visible/>"))
        #expect(vml.contains("<x:Row>2</x:Row><x:Column>2</x:Column></x:ClientData>"))
        let types = text(entries, "[Content_Types].xml")
        for type in [CommentParts.commentsContentType, CommentParts.vmlContentType, CommentParts.threadContentType,
                     CommentParts.personContentType] {
            #expect(types.contains(type))
        }
    }

    @Test("Notes and threads come back from a saved file intact")
    func roundTrip() throws {
        let original = commentedWorkbook()
        let reloaded = try XLSXReader.workbook(from: XLSXWriter.data(from: original))
        let comments = reloaded.sheets[0].comments
        #expect(comments.count == 2)
        let note = try #require(comments[CellAddress(a1: "B2")!])
        #expect(note.kind == .note)
        #expect(note.author == "Ann")
        #expect(note.text == "Check this <total> & that")
        #expect(note.isAlwaysVisible)
        let thread = try #require(comments[CellAddress(a1: "C3")!])
        #expect(thread.kind == .thread)
        #expect(thread.isResolved)
        #expect(thread.entries.map(\.author) == ["Bo", "Ann"])
        #expect(thread.entries.map(\.text) == ["Why is this high?", "Seasonal."])
        #expect(thread.entries[0].id == original.sheets[0].comments[CellAddress(a1: "C3")!]?.entries[0].id)
        #expect(reloaded.unsupportedFeatures.isEmpty)

        // A second save produces the same parts rather than piling up copies.
        let again = try ZipArchive.entries(in: XLSXWriter.data(from: reloaded))
        #expect(again.keys.filter { $0.hasPrefix("xl/comments") }.count == 1)
        #expect(again.keys.filter { $0.hasSuffix(".vml") }.count == 1)
    }

    @Test("Other shapes in the comment drawing, such as buttons, are kept")
    func keepsOtherShapes() throws {
        var entries = try ZipArchive.entries(in: XLSXWriter.data(from: commentedWorkbook()))
        var vml = text(entries, "xl/drawings/vmlDrawing1.vml")
        let button = "<v:shape id=\"_x0000_s5121\" type=\"#_x0000_t201\" style=\"position:absolute\">"
            + "<x:ClientData ObjectType=\"Button\"><x:FmlaMacro>[0]!Go</x:FmlaMacro></x:ClientData></v:shape>"
        vml = vml.replacingOccurrences(of: "</xml>", with: button + "</xml>")
        entries["xl/drawings/vmlDrawing1.vml"] = Data(vml.utf8)
        let repacked = try ZipArchive.archive(entries: entries.map { ($0.key, $0.value) })
        let workbook = try XLSXReader.workbook(from: repacked)
        #expect(workbook.sheets[0].preservedVMLShapes?.contains("ObjectType=\"Button\"") == true)
        #expect(workbook.sheets[0].comments.count == 2)
        let saved = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        let written = text(saved, "xl/drawings/vmlDrawing1.vml")
        #expect(written.contains("ObjectType=\"Button\""))
        #expect(written.components(separatedBy: "ObjectType=\"Note\"").count == 3)
        #expect(written.contains("data=\"1,5\""))
    }
}

@Suite("Comment editing")
@MainActor
struct CommentEditingTests {
    private func setUp() -> (EditorState, Workbook) {
        let workbook = Workbook(sheets: [Worksheet(name: "Sheet1")])
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id
        UserDefaults.standard.set("Kim", forKey: EditorState.commentAuthorKey)
        return (state, workbook)
    }

    @Test("Starting, answering, resolving and deleting a conversation")
    func thread() {
        var (state, workbook) = setUp()
        defer { UserDefaults.standard.removeObject(forKey: EditorState.commentAuthorKey) }
        let b2 = CellAddress(a1: "B2")!
        state.addComment("  Is this right?  ", kind: .thread, at: b2, in: &workbook)
        state.reply("Yes.", at: b2, in: &workbook)
        state.reply("   ", at: b2, in: &workbook)
        var thread = workbook.sheets[0].comments[b2]
        #expect(thread?.entries.map(\.text) == ["Is this right?", "Yes."])
        #expect(thread?.entries.first?.author == "Kim")
        state.setResolved(true, at: b2, in: &workbook)
        thread = workbook.sheets[0].comments[b2]
        #expect(thread?.isResolved == true)
        state.deleteComment(at: b2, in: &workbook)
        #expect(workbook.sheets[0].comments.isEmpty)
    }

    @Test("Notes are edited in place and cleared with the selection")
    func note() {
        var (state, workbook) = setUp()
        defer { UserDefaults.standard.removeObject(forKey: EditorState.commentAuthorKey) }
        let a1 = CellAddress(a1: "A1")!
        state.addComment("Draft", kind: .note, at: a1, in: &workbook)
        state.updateNote("Final", at: a1, in: &workbook)
        state.setNoteAlwaysVisible(true, at: a1, in: &workbook)
        #expect(workbook.sheets[0].comments[a1]?.text == "Final")
        #expect(workbook.sheets[0].comments[a1]?.isAlwaysVisible == true)
        state.reply("Not for notes", at: a1, in: &workbook)
        #expect(workbook.sheets[0].comments[a1]?.entries.count == 1)
        state.select(a1)
        state.deleteComments(in: &workbook)
        #expect(workbook.sheets[0].comments.isEmpty)
    }
}

@Suite("Copying and pasting")
@MainActor
struct ClipboardTests {
    @Test("Comments travel with copied cells, and cutting moves them")
    func comments() {
        var sheet = Worksheet(name: "Sheet1")
        sheet[CellAddress(a1: "A1")!] = Cell(value: .number(1))
        sheet.comments[CellAddress(a1: "A1")!] = .note(author: "Ann", text: "Source")
        var workbook = Workbook(sheets: [sheet])
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id

        state.select(CellAddress(a1: "A1")!)
        state.copySelection(in: workbook)
        state.select(CellAddress(a1: "C3")!)
        state.paste(in: &workbook)
        #expect(workbook.sheets[0].comments[CellAddress(a1: "C3")!]?.text == "Source")
        #expect(workbook.sheets[0].comments[CellAddress(a1: "A1")!] != nil)

        state.select(CellAddress(a1: "A1")!)
        state.cutSelection(in: &workbook)
        #expect(workbook.sheets[0].comments[CellAddress(a1: "A1")!] == nil)
        state.select(CellAddress(a1: "D4")!)
        state.paste(in: &workbook)
        #expect(workbook.sheets[0].comments[CellAddress(a1: "D4")!]?.text == "Source")
    }

    @Test("Pasted formulas move their relative references, and spilled values stay put")
    func formulas() {
        var sheet = Worksheet(name: "Sheet1")
        for (reference, input) in [("A1", "1"), ("A2", "2"), ("B1", "=A1*10"), ("C1", "=$A$1+A2"), ("E1", "={5;6}")] {
            sheet[CellAddress(a1: reference)!] = CellInputParser.cell(from: input, inheriting: .default)
        }
        var workbook = Workbook(sheets: [sheet])
        workbook.recalculate()
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id

        state.select(CellAddress(a1: "B1")!)
        state.select(CellAddress(a1: "C1")!, extending: true)
        state.copySelection(in: workbook)
        state.select(CellAddress(a1: "B2")!)
        state.paste(in: &workbook)
        #expect(workbook.sheets[0][CellAddress(a1: "B2")!].formula == "A2*10")
        #expect(workbook.sheets[0][CellAddress(a1: "B2")!].value == .number(20))
        #expect(workbook.sheets[0][CellAddress(a1: "C2")!].formula == "$A$1+A3")

        state.select(CellAddress(a1: "E2")!)
        state.copySelection(in: workbook)
        state.select(CellAddress(a1: "D3")!)
        state.paste(in: &workbook)
        #expect(workbook.sheets[0][CellAddress(a1: "D3")!].value == .number(6))
        #expect(!workbook.sheets[0][CellAddress(a1: "D3")!].isSpilled)
    }
}

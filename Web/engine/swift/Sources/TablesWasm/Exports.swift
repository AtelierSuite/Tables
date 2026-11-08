import Foundation

// The engine's whole interface to JavaScript: a C ABI with no dependencies.
//
// The host copies a UTF-8 JSON request (and optionally a byte payload, such as
// a file being opened) into memory it allocated with `tables_alloc`, then calls
// `tables_call`. The response is JSON, plus an optional byte payload (such as a
// file being saved), which the host reads through the `tables_response_*` and
// `tables_payload_*` accessors before making its next call.

private nonisolated(unsafe) var response = Buffer()
private nonisolated(unsafe) var payload = Buffer()

/// Memory owned by the engine that the host reads between calls.
private struct Buffer {
    var pointer: UnsafeMutableRawPointer?
    var count = 0

    mutating func replace(with bytes: some Collection<UInt8>) {
        pointer?.deallocate()
        count = bytes.count
        pointer = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 8)
        UnsafeMutableRawBufferPointer(start: pointer, count: count).copyBytes(from: bytes)
    }
}

@_expose(wasm, "tables_alloc")
@_cdecl("tables_alloc")
public func tablesAlloc(_ size: Int32) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), 1), alignment: 8)
}

@_expose(wasm, "tables_free")
@_cdecl("tables_free")
public func tablesFree(_ pointer: UnsafeMutableRawPointer?) {
    pointer?.deallocate()
}

/// Handles one request. Returns 0; failures are reported inside the response.
@_expose(wasm, "tables_call")
@_cdecl("tables_call")
public func tablesCall(
    _ request: UnsafeRawPointer, _ requestLength: Int32, _ input: UnsafeRawPointer?, _ inputLength: Int32
) -> Int32 {
    let requestData = Data(bytes: request, count: Int(requestLength))
    let inputData = input.map { Data(bytes: $0, count: Int(inputLength)) }
    let (json, output) = Bridge.shared.handle(requestData, payload: inputData)
    response.replace(with: json)
    payload.replace(with: output ?? Data())
    return 0
}

@_expose(wasm, "tables_response_pointer")
@_cdecl("tables_response_pointer")
public func tablesResponsePointer() -> UnsafeMutableRawPointer? { response.pointer }

@_expose(wasm, "tables_response_length")
@_cdecl("tables_response_length")
public func tablesResponseLength() -> Int32 { Int32(response.count) }

@_expose(wasm, "tables_payload_pointer")
@_cdecl("tables_payload_pointer")
public func tablesPayloadPointer() -> UnsafeMutableRawPointer? { payload.pointer }

@_expose(wasm, "tables_payload_length")
@_cdecl("tables_payload_length")
public func tablesPayloadLength() -> Int32 { Int32(payload.count) }

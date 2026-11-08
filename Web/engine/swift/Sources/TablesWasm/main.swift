// Tables engine for the web.
//
// This module is linked as a WebAssembly reactor: it has no main entry point.
// The host instantiates it, calls `_initialize`, then drives it through the
// functions in Exports.swift. See Web/engine/engine.js for the other side.

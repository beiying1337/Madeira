import SwiftUI
import Foundation

@main
struct MadeiraApp: App {
    init() {
        /* Builds through run 36 wrote the complete JIT pool to Documents after
         * the first Wine exception.  The pool is now 896 MB, so that persistent
         * file can leave subsequent launches with no usable container space and
         * only the iOS launch snapshot visible.  Reinstalling appeared to fix it
         * solely because reinstall removed the app container.
         *
         * Unlink it before ContentView/LogStore/Metal are constructed.  Also
         * discard runaway logs left by an interrupted Wine session; normal logs
         * remain available for diagnosis. */
        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: docs.appendingPathComponent("fex-jit-dump.bin"))
            try? fm.removeItem(at: docs.appendingPathComponent("fex-jit-dump.bin.tmp"))

            let maxLogBytes: UInt64 = 64 * 1024 * 1024
            for name in ["madeira-log.txt", "madeira-log.prev.txt"] {
                let url = docs.appendingPathComponent(name)
                if let attrs = try? fm.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? NSNumber,
                   size.uint64Value > maxLogBytes {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

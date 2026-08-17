import Foundation

actor WorkspaceManager {
    struct Entry: Identifiable, Hashable, Sendable {
        let id: String
        let relativePath: String
        let isDirectory: Bool
        let size: Int64
        var name: String { URL(fileURLWithPath: relativePath).lastPathComponent }
    }

    struct SearchHit: Identifiable, Hashable, Sendable {
        let id = UUID()
        let path: String
        let line: Int
        let text: String
    }

    private struct UndoRecord: Codable {
        enum Kind: String, Codable { case write, delete, move, mkdir }
        var kind: Kind
        var path: String
        var destination: String?
        var previousBase64: String?
        var wasDirectory: Bool
        var timestamp: Date
    }

    enum WorkspaceError: LocalizedError {
        case invalidPath, missingFile(String), notText(String), outsideWorkspace, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidPath: "Invalid project path."
            case .missingFile(let path): "Missing file: \(path)"
            case .notText(let path): "Not a UTF-8 text file: \(path)"
            case .outsideWorkspace: "The requested path escapes the workspace sandbox."
            case .tooLarge: "The requested file is too large for the agent hot context."
            }
        }
    }

    private let fm = FileManager.default
    private var root: URL!
    private var journalURL: URL!
    private var undoStack: [UndoRecord] = []

    func bootstrap() throws {
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let workspaces = support.appendingPathComponent("Workspaces", isDirectory: true)
        try fm.createDirectory(at: workspaces, withIntermediateDirectories: true)
        root = workspaces.appendingPathComponent("NebulaRunner", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        journalURL = root.appendingPathComponent(".triinfer-undo.json")
        if let data = try? Data(contentsOf: journalURL), let saved = try? JSONDecoder().decode([UndoRecord].self, from: data) {
            undoStack = saved
        }
        if (try? fm.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".triinfer") }.isEmpty) != false {
            try createBrowserTemplate(overwrite: false)
        }
    }

    func rootURL() -> URL { root }

    func createBrowserTemplate(overwrite: Bool) throws {
        guard root != nil else { throw WorkspaceError.invalidPath }
        let files: [String: String] = [
            "index.html": """
            <!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Nebula Runner</title><link rel=\"stylesheet\" href=\"styles/main.css\"></head><body><main id=\"app\"><canvas id=\"game\"></canvas><section class=\"hud\"><div><span>LAP</span><strong id=\"lap\">1 / 3</strong></div><div><span>SPEED</span><strong id=\"speed\">000</strong></div></section><div class=\"brand\">NEBULA RUNNER</div></main><script type=\"module\" src=\"src/main.js\"></script></body></html>
            """,
            "styles/main.css": """
            *{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;background:#070912;color:#fff;font-family:-apple-system,BlinkMacSystemFont,system-ui}body{overflow:hidden}#app{position:relative;width:100%;height:100%;background:radial-gradient(circle at 50% 30%,#243453 0,#0a1020 38%,#05070d 75%)}canvas{width:100%;height:100%;display:block}.hud{position:absolute;top:24px;left:24px;right:24px;display:flex;justify-content:space-between;pointer-events:none}.hud div{padding:10px 14px;border:1px solid #ffffff2c;border-radius:16px;background:#0c1428aa;backdrop-filter:blur(18px)}.hud span{display:block;font-size:10px;letter-spacing:.18em;color:#a6b7d6}.hud strong{font-size:20px}.brand{position:absolute;left:50%;bottom:28px;transform:translateX(-50%);font-weight:800;letter-spacing:.28em;font-size:12px;color:#c7d5ff}
            """,
            "src/main.js": """
            import {Vehicle} from './vehicle.js'; import {RaceState} from './race-state.js';
            const canvas=document.querySelector('#game'),ctx=canvas.getContext('2d'),car=new Vehicle(),race=new RaceState(3); let last=performance.now();
            function resize(){canvas.width=innerWidth*devicePixelRatio;canvas.height=innerHeight*devicePixelRatio} addEventListener('resize',resize);resize();
            const keys=new Set();addEventListener('keydown',e=>keys.add(e.key));addEventListener('keyup',e=>keys.delete(e.key));
            function frame(now){const dt=Math.min(.033,(now-last)/1000);last=now;car.update(dt,keys);race.update(car);ctx.setTransform(devicePixelRatio,0,0,devicePixelRatio,0,0);draw(ctx,canvas.width/devicePixelRatio,canvas.height/devicePixelRatio);document.querySelector('#speed').textContent=String(Math.round(car.speed*8)).padStart(3,'0');document.querySelector('#lap').textContent=`${race.lap} / ${race.totalLaps}`;requestAnimationFrame(frame)}
            function draw(g,w,h){g.clearRect(0,0,w,h);g.save();g.translate(w/2,h/2);g.strokeStyle='#6a7dff55';g.lineWidth=34;g.beginPath();g.ellipse(0,0,w*.33,h*.31,0,0,Math.PI*2);g.stroke();g.rotate(car.heading);g.fillStyle='#a8c7ff';g.fillRect(-18,-34,36,68);g.fillStyle='#10182d';g.fillRect(-12,-25,24,20);g.restore()} requestAnimationFrame(frame);
            """,
            "src/vehicle.js": """
            export class Vehicle{constructor(){this.speed=0;this.heading=0;this.progress=0}update(dt,keys){const throttle=keys.has('ArrowUp')?1:keys.has('ArrowDown')?-.5:0;const steer=(keys.has('ArrowLeft')?-1:0)+(keys.has('ArrowRight')?1:0);this.speed+=(throttle*24-this.speed*.75)*dt;this.heading+=steer*Math.min(2.6,Math.abs(this.speed)*.09)*dt;this.progress=(this.progress+Math.max(0,this.speed)*dt*.003)%1}}
            """,
            "src/race-state.js": """
            export class RaceState{constructor(totalLaps){this.totalLaps=totalLaps;this.lap=1;this.lastProgress=0}update(car){if(this.lastProgress>.85&&car.progress<.15)this.lap=Math.min(this.totalLaps,this.lap+1);this.lastProgress=car.progress}}
            """,
            "README.md": "# Nebula Runner\n\nA modular browser-game workspace. Keep rendering, physics, race state, styles, and assets in separate files.\n",
            "assets/.keep": ""
        ]
        for (path, text) in files {
            let url = try resolve(path)
            if !overwrite && fm.fileExists(atPath: url.path) { continue }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        }
    }

    func entries() throws -> [Entry] {
        guard let root else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var output: [Entry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            let rel = String(url.path.dropFirst(root.path.count + 1))
            if rel.hasPrefix(".triinfer") { continue }
            output.append(.init(id: rel, relativePath: rel, isDirectory: values.isDirectory ?? false, size: Int64(values.fileSize ?? 0)))
        }
        return output.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
        }
    }

    func read(_ path: String, maxBytes: Int = 256_000) throws -> String {
        let url = try resolve(path)
        guard fm.fileExists(atPath: url.path) else { throw WorkspaceError.missingFile(path) }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maxBytes else { throw WorkspaceError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw WorkspaceError.notText(path) }
        return text
    }

    func write(_ path: String, content: String) throws {
        let url = try resolve(path)
        let previous = try? Data(contentsOf: url)
        try record(.init(kind: .write, path: path, destination: nil, previousBase64: previous?.base64EncodedString(), wasDirectory: false, timestamp: Date()))
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    func patch(_ path: String, exact old: String, replacement: String) throws {
        let source = try read(path)
        guard source.contains(old) else { throw WorkspaceError.missingFile("exact match in \(path)") }
        guard source.components(separatedBy: old).count == 2 else { throw WorkspaceError.invalidPath }
        try write(path, content: source.replacingOccurrences(of: old, with: replacement))
    }

    func makeDirectory(_ path: String) throws {
        let url = try resolve(path)
        try record(.init(kind: .mkdir, path: path, destination: nil, previousBase64: nil, wasDirectory: true, timestamp: Date()))
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func delete(_ path: String) throws {
        let url = try resolve(path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw WorkspaceError.missingFile(path) }
        let previous = isDir.boolValue ? nil : try? Data(contentsOf: url)
        try record(.init(kind: .delete, path: path, destination: nil, previousBase64: previous?.base64EncodedString(), wasDirectory: isDir.boolValue, timestamp: Date()))
        try fm.removeItem(at: url)
    }

    func move(_ source: String, to destination: String) throws {
        let src = try resolve(source), dst = try resolve(destination)
        try record(.init(kind: .move, path: source, destination: destination, previousBase64: nil, wasDirectory: false, timestamp: Date()))
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: src, to: dst)
    }

    func search(_ query: String, maxHits: Int = 30) throws -> [SearchHit] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for entry in try entries() where !entry.isDirectory && entry.size < 512_000 {
            guard let text = try? read(entry.relativePath, maxBytes: 512_000) else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.lowercased().contains(needle) {
                hits.append(.init(path: entry.relativePath, line: index + 1, text: String(line.prefix(240))))
                if hits.count >= maxHits { return hits }
            }
        }
        return hits
    }

    func undo() throws -> String {
        guard let item = undoStack.popLast() else { return "Nothing to undo." }
        let url = try resolve(item.path)
        switch item.kind {
        case .write:
            if let encoded = item.previousBase64, let data = Data(base64Encoded: encoded) {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } else if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        case .delete:
            if item.wasDirectory { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
            else if let encoded = item.previousBase64, let data = Data(base64Encoded: encoded) {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
        case .move:
            if let destination = item.destination {
                let dst = try resolve(destination)
                if fm.fileExists(atPath: dst.path) { try fm.moveItem(at: dst, to: url) }
            }
        case .mkdir:
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        try persistJournal()
        return "Undid \(item.kind.rawValue): \(item.path)"
    }

    private func resolve(_ relative: String) throws -> URL {
        guard let root else { throw WorkspaceError.invalidPath }
        let normalized = relative.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.split(separator: "/").contains("..") else { throw WorkspaceError.invalidPath }
        let target = root.appendingPathComponent(normalized).standardizedFileURL
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else { throw WorkspaceError.outsideWorkspace }
        return target
    }

    private func record(_ record: UndoRecord) throws {
        undoStack.append(record)
        if undoStack.count > 80 { undoStack.removeFirst(undoStack.count - 80) }
        try persistJournal()
    }

    private func persistJournal() throws {
        let data = try JSONEncoder().encode(undoStack)
        try data.write(to: journalURL, options: .atomic)
    }
}

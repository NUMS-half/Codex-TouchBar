import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: make_icns.swift ICONSET_DIRECTORY OUTPUT.icns\n", stderr)
    exit(64)
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])

// Modern ICNS files can contain PNG payloads directly. Writing these chunks
// avoids iconutil's unreliable re-packaging behaviour on the installed CLT.
let entries: [(String, String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_128x128@2x.png"),
    ("ic09", "icon_256x256@2x.png"),
    ("ic10", "icon_512x512@2x.png"),
]

func bigEndian(_ value: UInt32) -> Data {
    var number = value.bigEndian
    return Data(bytes: &number, count: MemoryLayout<UInt32>.size)
}

var chunks = Data()
for (type, filename) in entries {
    let payload = try Data(contentsOf: iconset.appendingPathComponent(filename))
    guard let typeData = type.data(using: .ascii), typeData.count == 4 else { fatalError("invalid icon type") }
    chunks.append(typeData)
    chunks.append(bigEndian(UInt32(payload.count + 8)))
    chunks.append(payload)
}

var result = Data("icns".utf8)
result.append(bigEndian(UInt32(chunks.count + 8)))
result.append(chunks)
try result.write(to: output, options: .atomic)

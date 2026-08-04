import AppKit

guard CommandLine.arguments.count == 4,
      let size = Int(CommandLine.arguments[3]), size > 0 else {
    fputs("Usage: RasterizeSVG.swift input.svg output.png size\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: sourceURL) else {
    fputs("Could not load SVG: \(sourceURL.path)\n", stderr)
    exit(1)
}

image.size = NSSize(width: size, height: size)
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not rasterize SVG: \(sourceURL.path)\n", stderr)
    exit(1)
}

do {
    try png.write(to: outputURL, options: .atomic)
} catch {
    fputs("Could not write PNG: \(error.localizedDescription)\n", stderr)
    exit(1)
}

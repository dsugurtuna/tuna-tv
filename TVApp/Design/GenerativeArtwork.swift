import SwiftUI

/// Beautiful deterministic artwork for items without images (and for the demo).
/// The same seed always produces the same picture (stable FNV-1a hash, never `hashValue`), so a title's poster,
/// backdrop and logo share one palette.
struct GenerativeArtwork: View {
    var kind: ArtworkKind
    var seed: String
    var title: String? = nil
    /// Extra: small line under generative poster titles (e.g. "2019 · Drama").
    var caption: String? = nil
    /// Extra: placement of the generative logo text inside its frame.
    var alignment: Alignment = .center

    var body: some View {
        switch kind {
        case .poster:
            DSPosterArt(seed: seed, title: title, caption: caption)
        case .backdrop, .still:
            DSLandscapeArt(seed: seed)
        case .logo:
            DSLogoArt(seed: seed, title: title, alignment: alignment)
        case .person:
            DSPersonArt(seed: seed, title: title)
        case .channel:
            DSChannelArt(seed: seed, title: title)
        case .studio:
            DSStudioArt(seed: seed, title: title)
        }
    }

    /// Accent colour of the palette a seed maps to (e.g. to tint `AmbientBackground` like the hero art).
    static func tint(for seed: String) -> Color { DSArtPalette.forSeed(seed).glow }
}

// MARK: - Hashing & randomness

enum DSHash {
    static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    static let prime: UInt64 = 0x0000_0100_0000_01b3

    /// 64-bit FNV-1a over UTF-8 bytes.
    static func fnv1a64(_ string: String) -> UInt64 {
        var hash = offsetBasis
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    /// 128-bit hex digest (two decorrelated FNV-1a passes) for cache file names.
    static func hex128(_ string: String) -> String {
        let forward = fnv1a64(string)
        var backward: UInt64 = 0x84_22_23_25_cb_f2_9c_e4
        for byte in string.utf8.reversed() {
            backward ^= UInt64(byte)
            backward = backward &* prime
        }
        backward ^= UInt64(string.utf8.count) &* 0x9E37_79B9_7F4A_7C15
        return String(format: "%016llx%016llx", forward, backward)
    }
}

/// SplitMix64: tiny, fast, deterministic.
struct DSRandom {
    private var state: UInt64

    init(seed: String) { state = DSHash.fnv1a64(seed) }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< 1
    mutating func unit() -> CGFloat {
        CGFloat(Double(next() >> 11) / 9_007_199_254_740_992.0)
    }

    mutating func range(_ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        lower + (upper - lower) * unit()
    }

    mutating func int(_ upperBound: Int) -> Int {
        guard upperBound > 1 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }

    mutating func chance(_ probability: CGFloat) -> Bool { unit() < probability }
}

// MARK: - Palettes

/// One cinematic palette: sky (top → horizon), glow (sun/light), accent (secondary light), three terrain layers
/// (far → near) and the ink used for titles.
struct DSArtPalette {
    let sky: [Color]
    let glow: Color
    let accent: Color
    let layers: [Color]
    let ink: Color
    let isNight: Bool

    init(sky: [UInt32], glow: UInt32, accent: UInt32, layers: [UInt32], ink: UInt32, night: Bool) {
        self.sky = sky.map { Color(hex: $0) }
        self.glow = Color(hex: glow)
        self.accent = Color(hex: accent)
        self.layers = layers.map { Color(hex: $0) }
        self.ink = Color(hex: ink)
        self.isNight = night
    }

    static func forSeed(_ seed: String) -> DSArtPalette {
        let index = Int(DSHash.fnv1a64(seed) % UInt64(all.count))
        return all[index]
    }

    static let all: [DSArtPalette] = [
        // Ember
        DSArtPalette(sky: [0x12060F, 0x3D1026, 0xB8432A], glow: 0xFFB067, accent: 0xFF6A3D,
                     layers: [0x5A1A2E, 0x2E0D1C, 0x14060D], ink: 0xFFF1E6, night: false),
        // Abyss
        DSArtPalette(sky: [0x02060F, 0x062544, 0x0C5A78], glow: 0x6FE3FF, accent: 0x2BB3D9,
                     layers: [0x0A3550, 0x05203A, 0x020D1C], ink: 0xE8FAFF, night: true),
        // Aurora
        DSArtPalette(sky: [0x040713, 0x0F2A3D, 0x1D6B63], glow: 0x86FFC2, accent: 0x9B6BFF,
                     layers: [0x123A40, 0x0A2129, 0x040D12], ink: 0xEFFFF7, night: true),
        // Dune
        DSArtPalette(sky: [0x1A0F07, 0x6A3812, 0xE09040], glow: 0xFFE3A3, accent: 0xFF9F4A,
                     layers: [0xA2541C, 0x5E2E0E, 0x2A1406], ink: 0xFFF6E3, night: false),
        // Neon Noir
        DSArtPalette(sky: [0x07020F, 0x260A3A, 0x6E1A63], glow: 0xFF4FD8, accent: 0x22D3EE,
                     layers: [0x3A0F4A, 0x1F0730, 0x0B0214], ink: 0xFFE9FB, night: true),
        // Glacier
        DSArtPalette(sky: [0x0A1420, 0x2A4762, 0x8DB6CF], glow: 0xEAF7FF, accent: 0x9FD8FF,
                     layers: [0x4C6F8C, 0x26405A, 0x0E1C2B], ink: 0xF4FBFF, night: false),
        // Forest
        DSArtPalette(sky: [0x040B08, 0x0E2C20, 0x2E6A48], glow: 0xD4F7A8, accent: 0x7FD36B,
                     layers: [0x1E4A33, 0x0F2A1D, 0x05120C], ink: 0xF1FFE8, night: false),
        // Rosé
        DSArtPalette(sky: [0x180812, 0x55203D, 0xE07A8F], glow: 0xFFD3DD, accent: 0xFF8FA8,
                     layers: [0x7A2E4E, 0x42152B, 0x1C0812], ink: 0xFFF0F4, night: false),
        // Cobalt
        DSArtPalette(sky: [0x03050F, 0x0B1B55, 0x2B5BD6], glow: 0xA6C8FF, accent: 0x5B8CFF,
                     layers: [0x16307A, 0x0B1A47, 0x040A1E], ink: 0xEEF4FF, night: true),
        // Saffron
        DSArtPalette(sky: [0x140A02, 0x5A3806, 0xE3A82A], glow: 0xFFF2B8, accent: 0xFFC94A,
                     layers: [0x8A5A10, 0x4A2E06, 0x1E1203], ink: 0xFFF8E6, night: false),
        // Plum
        DSArtPalette(sky: [0x0B0513, 0x2D1150, 0x6C3BBE], glow: 0xE4CCFF, accent: 0xB18CFF,
                     layers: [0x40207A, 0x221045, 0x0D061C], ink: 0xF6EEFF, night: true),
        // Crimson
        DSArtPalette(sky: [0x0D0305, 0x470A15, 0xB0142F], glow: 0xFF9C8F, accent: 0xFF4D5E,
                     layers: [0x5E0F1D, 0x320710, 0x120305], ink: 0xFFEDEB, night: false),
        // Jade
        DSArtPalette(sky: [0x02100E, 0x0A3934, 0x188377], glow: 0xA6FFEA, accent: 0x3EE0C3,
                     layers: [0x0F5049, 0x08302B, 0x021411], ink: 0xEBFFFA, night: false),
        // Smoke
        DSArtPalette(sky: [0x0A0A0C, 0x28282F, 0x6A6A78], glow: 0xF3EADB, accent: 0xC9BFAE,
                     layers: [0x3A3A44, 0x22222A, 0x0C0C10], ink: 0xF7F3EC, night: true),
        // Pacific Sunset
        DSArtPalette(sky: [0x110524, 0x5A1D5E, 0xF06C4E], glow: 0xFFD47E, accent: 0xFF8A5C,
                     layers: [0x6B2459, 0x3A1236, 0x160717], ink: 0xFFF3E4, night: false),
        // Midnight Coral (brand)
        DSArtPalette(sky: [0x040915, 0x0D1B39, 0x2A3F73], glow: 0xFF8A6A, accent: 0xFF5B5F,
                     layers: [0x1A2A52, 0x0E1832, 0x050A16], ink: 0xFFF0EC, night: true),
    ]
}

// MARK: - Scenery (Canvas)

/// Layered cinematic landscapes: gradient sky, glow, soft blobs, stars, sun, light rays, terrain
/// (peaks / dunes / waves / skyline), vignette and film grain.
enum DSScenery {
    private enum Terrain: Int, CaseIterable { case peaks, dunes, waves, skyline }

    static func draw(in context: inout GraphicsContext, size: CGSize, seed: String, wide: Bool) {
        let width = size.width
        let height = size.height
        guard width > 2, height > 2 else { return }
        let palette = DSArtPalette.forSeed(seed)
        var rng = DSRandom(seed: seed + "#scene")
        let bounds = CGRect(origin: .zero, size: size)
        let horizon = height * (wide ? rng.range(0.50, 0.62) : rng.range(0.52, 0.64))
        let terrain = Terrain(rawValue: rng.int(Terrain.allCases.count)) ?? .peaks

        drawSky(&context, bounds: bounds, horizon: horizon, palette: palette, rng: &rng)
        let sun = drawGlow(&context, bounds: bounds, horizon: horizon, palette: palette, rng: &rng)
        drawBlobs(&context, bounds: bounds, palette: palette, rng: &rng)
        if palette.isNight || rng.chance(0.35) {
            drawStars(&context, bounds: bounds, horizon: horizon, wide: wide, rng: &rng)
        }
        if rng.chance(0.75) {
            drawSun(&context, center: sun, bounds: bounds, palette: palette, rng: &rng)
        }
        if rng.chance(0.35) {
            drawRays(&context, origin: sun, bounds: bounds, palette: palette, rng: &rng)
        }
        switch terrain {
        case .peaks: drawPeaks(&context, bounds: bounds, horizon: horizon, palette: palette, rng: &rng)
        case .dunes: drawDunes(&context, bounds: bounds, horizon: horizon, palette: palette, rng: &rng)
        case .waves: drawWaves(&context, bounds: bounds, horizon: horizon, sun: sun, palette: palette, rng: &rng)
        case .skyline: drawSkyline(&context, bounds: bounds, horizon: horizon, palette: palette, rng: &rng)
        }
        drawVignette(&context, bounds: bounds)
        drawGrain(&context, bounds: bounds, rng: &rng)
    }

    // MARK: Sky & light

    private static func drawSky(_ context: inout GraphicsContext, bounds: CGRect, horizon: CGFloat,
                                palette: DSArtPalette, rng: inout DSRandom) {
        let shift = rng.range(-0.3, 0.3) * bounds.width
        let start = CGPoint(x: bounds.midX + shift, y: 0)
        let end = CGPoint(x: bounds.midX - shift, y: horizon * 1.05)
        context.fill(Path(bounds), with: .linearGradient(Gradient(colors: palette.sky), startPoint: start, endPoint: end))
    }

    private static func drawGlow(_ context: inout GraphicsContext, bounds: CGRect, horizon: CGFloat,
                                 palette: DSArtPalette, rng: inout DSRandom) -> CGPoint {
        let center = CGPoint(x: bounds.width * rng.range(0.22, 0.78),
                             y: horizon - bounds.height * rng.range(0.06, 0.26))
        let radius = max(bounds.width, bounds.height) * rng.range(0.42, 0.7)
        let gradient = Gradient(stops: [
            .init(color: palette.glow.opacity(0.62), location: 0),
            .init(color: palette.glow.opacity(0.2), location: 0.35),
            .init(color: palette.glow.opacity(0), location: 1),
        ])
        context.fill(Path(bounds), with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: radius))
        return center
    }

    private static func drawBlobs(_ context: inout GraphicsContext, bounds: CGRect, palette: DSArtPalette,
                                  rng: inout DSRandom) {
        let count = 2 + rng.int(2)
        context.drawLayer { layer in
            layer.blendMode = .screen
            for index in 0..<count {
                let center = CGPoint(x: bounds.width * rng.range(-0.1, 1.1), y: bounds.height * rng.range(-0.1, 0.7))
                let radius = max(bounds.width, bounds.height) * rng.range(0.18, 0.42)
                let color = index % 2 == 0 ? palette.accent : palette.glow
                let strength = Double(rng.range(0.14, 0.3))
                let gradient = Gradient(colors: [color.opacity(strength), color.opacity(0)])
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                layer.fill(Path(ellipseIn: rect),
                           with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: radius))
            }
        }
    }

    private static func drawStars(_ context: inout GraphicsContext, bounds: CGRect, horizon: CGFloat, wide: Bool,
                                  rng: inout DSRandom) {
        var dim = Path()
        var bright = Path()
        let count = wide ? 70 : 42
        for _ in 0..<count {
            let x = bounds.width * rng.unit()
            let y = horizon * rng.range(0, 0.78)
            let radius = rng.range(0.35, 1.1)
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            if rng.chance(0.25) {
                bright.addEllipse(in: rect)
            } else {
                dim.addEllipse(in: rect)
            }
        }
        context.fill(dim, with: .color(Color.white.opacity(0.42)))
        context.fill(bright, with: .color(Color.white.opacity(0.88)))
    }

    private static func drawSun(_ context: inout GraphicsContext, center: CGPoint, bounds: CGRect,
                                palette: DSArtPalette, rng: inout DSRandom) {
        let radius = min(bounds.width, bounds.height) * rng.range(0.09, 0.17)
        let disk = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let halo = disk.insetBy(dx: -radius * 0.95, dy: -radius * 0.95)
        let haloGradient = Gradient(colors: [palette.glow.opacity(0.38), palette.glow.opacity(0)])
        context.fill(Path(ellipseIn: halo),
                     with: .radialGradient(haloGradient, center: center, startRadius: radius, endRadius: radius * 1.95))
        let diskGradient = Gradient(colors: [palette.ink, palette.glow])
        context.fill(Path(ellipseIn: disk),
                     with: .linearGradient(diskGradient,
                                           startPoint: CGPoint(x: center.x, y: disk.minY),
                                           endPoint: CGPoint(x: center.x, y: disk.maxY)))
        guard rng.chance(0.45) else { return }
        // Retro "synthwave" bands cut through the lower half of the sun.
        var stripes = Path()
        let bands = 4 + rng.int(3)
        for band in 0..<bands {
            let t = CGFloat(band) / CGFloat(bands)
            let y = center.y + radius * (0.08 + t * 0.86)
            let thickness = radius * (0.04 + t * 0.1)
            stripes.addRect(CGRect(x: disk.minX - 1, y: y, width: disk.width + 2, height: thickness))
        }
        let cut = palette.sky[1]
        context.drawLayer { layer in
            layer.clip(to: Path(ellipseIn: disk))
            layer.fill(stripes, with: .color(cut))
        }
    }

    private static func drawRays(_ context: inout GraphicsContext, origin: CGPoint, bounds: CGRect,
                                 palette: DSArtPalette, rng: inout DSRandom) {
        var rays = Path()
        let count = 4 + rng.int(4)
        let length = max(bounds.width, bounds.height) * 1.3
        for _ in 0..<count {
            let angle = rng.range(0.2, 0.8) * CGFloat.pi
            let spread = rng.range(0.015, 0.05)
            let first = CGPoint(x: origin.x + cos(angle - spread) * length, y: origin.y + sin(angle - spread) * length)
            let second = CGPoint(x: origin.x + cos(angle + spread) * length, y: origin.y + sin(angle + spread) * length)
            rays.move(to: origin)
            rays.addLine(to: first)
            rays.addLine(to: second)
            rays.closeSubpath()
        }
        let gradient = Gradient(colors: [palette.glow.opacity(0.2), palette.glow.opacity(0)])
        let reach = max(bounds.width, bounds.height) * 0.9
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.fill(rays, with: .radialGradient(gradient, center: origin, startRadius: 0, endRadius: reach))
        }
    }

    // MARK: Terrain

    private static func fillLayer(_ context: inout GraphicsContext, path: Path, top: CGFloat, bounds: CGRect,
                                  color: Color, rim: Color) {
        context.fill(path, with: .color(color))
        let rimGradient = Gradient(colors: [rim.opacity(0.22), rim.opacity(0)])
        context.fill(path, with: .linearGradient(rimGradient,
                                                 startPoint: CGPoint(x: 0, y: top),
                                                 endPoint: CGPoint(x: 0, y: top + bounds.height * 0.12)))
    }

    private static func drawMist(_ context: inout GraphicsContext, bounds: CGRect, y: CGFloat, color: Color) {
        let band = CGRect(x: 0, y: y - bounds.height * 0.07, width: bounds.width, height: bounds.height * 0.1)
        let gradient = Gradient(colors: [color.opacity(0), color.opacity(0.13), color.opacity(0)])
        context.fill(Path(band), with: .linearGradient(gradient,
                                                       startPoint: CGPoint(x: 0, y: band.minY),
                                                       endPoint: CGPoint(x: 0, y: band.maxY)))
    }

    private static func drawPeaks(_ context: inout GraphicsContext, bounds: CGRect, horizon: CGFloat,
                                  palette: DSArtPalette, rng: inout DSRandom) {
        let width = bounds.width
        let height = bounds.height
        for layerIndex in 0..<3 {
            let depth = CGFloat(layerIndex)
            let base = horizon + (height - horizon) * depth * 0.24
            let amplitude = height * (0.17 - depth * 0.04) * rng.range(0.7, 1.15)
            let segments = 6 + layerIndex * 3 + rng.int(3)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: height))
            var top = base
            for step in 0...segments {
                let x = width * CGFloat(step) / CGFloat(segments)
                let jitter = (step == 0 || step == segments) ? 0 : width / CGFloat(segments) * rng.range(-0.3, 0.3)
                let lift = step % 2 == 0 ? rng.range(0.55, 1.0) : rng.range(0.0, 0.42)
                let y = base - amplitude * lift
                top = min(top, y)
                path.addLine(to: CGPoint(x: x + jitter, y: y))
            }
            path.addLine(to: CGPoint(x: width, y: height))
            path.closeSubpath()
            fillLayer(&context, path: path, top: top, bounds: bounds, color: palette.layers[layerIndex], rim: palette.glow)
            if layerIndex < 2 {
                drawMist(&context, bounds: bounds, y: base + (height - horizon) * 0.2, color: palette.glow)
            }
        }
    }

    /// Two-sine ridge line across the full width (closed = filled down to the bottom edge).
    private struct Ridge {
        var base: CGFloat
        var amplitude: CGFloat
        var frequency: CGFloat
        var phase: CGFloat
        var secondFrequency: CGFloat
        var secondPhase: CGFloat

        init(base: CGFloat, amplitude: CGFloat, frequency: CGFloat, phase: CGFloat, rng: inout DSRandom) {
            self.base = base
            self.amplitude = amplitude
            self.frequency = frequency
            self.phase = phase
            self.secondFrequency = frequency * rng.range(1.8, 2.6)
            self.secondPhase = rng.range(0, 2 * CGFloat.pi)
        }
    }

    private static func ridgePath(bounds: CGRect, ridge: Ridge, closed: Bool) -> (path: Path, top: CGFloat) {
        let base = ridge.base
        let amplitude = ridge.amplitude
        let frequency = ridge.frequency
        let phase = ridge.phase
        let secondFrequency = ridge.secondFrequency
        let secondPhase = ridge.secondPhase
        let steps = 56
        var path = Path()
        var top = base
        if closed { path.move(to: CGPoint(x: 0, y: bounds.height)) }
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let primary = sin(t * frequency * 2 * CGFloat.pi + phase) * 0.7
            let secondary = sin(t * secondFrequency * 2 * CGFloat.pi + secondPhase) * 0.3
            let y = base - amplitude * (primary + secondary)
            top = min(top, y)
            let point = CGPoint(x: t * bounds.width, y: y)
            if step == 0 && !closed {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        if closed {
            path.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
            path.closeSubpath()
        }
        return (path, top)
    }

    private static func drawDunes(_ context: inout GraphicsContext, bounds: CGRect, horizon: CGFloat,
                                  palette: DSArtPalette, rng: inout DSRandom) {
        let height = bounds.height
        for layerIndex in 0..<3 {
            let depth = CGFloat(layerIndex)
            let base = horizon + (height - horizon) * (0.06 + depth * 0.26)
            let amplitude = height * (0.06 - depth * 0.012) * rng.range(0.7, 1.3)
            let frequency = rng.range(0.6, 1.4) * (1 + depth * 0.35)
            let phase = rng.range(0, 2 * CGFloat.pi)
            let shape = Ridge(base: base, amplitude: amplitude, frequency: frequency, phase: phase, rng: &rng)
            let ridge = ridgePath(bounds: bounds, ridge: shape, closed: true)
            fillLayer(&context, path: ridge.path, top: ridge.top, bounds: bounds,
                      color: palette.layers[layerIndex], rim: palette.glow)
            if layerIndex < 2 {
                drawMist(&context, bounds: bounds, y: base + (height - horizon) * 0.22, color: palette.glow)
            }
        }
    }

    private static func drawWaves(_ context: inout GraphicsContext, bounds: CGRect, horizon: CGFloat, sun: CGPoint,
                                  palette: DSArtPalette, rng: inout DSRandom) {
        let height = bounds.height
        // Sea surface.
        let sea = CGRect(x: 0, y: horizon, width: bounds.width, height: height - horizon)
        let seaGradient = Gradient(colors: [palette.layers[0], palette.layers[2]])
        context.fill(Path(sea), with: .linearGradient(seaGradient,
                                                      startPoint: CGPoint(x: 0, y: sea.minY),
                                                      endPoint: CGPoint(x: 0, y: sea.maxY)))
        // Sun glitter on the water.
        var glitter = Path()
        let glitterCount = 22
        for index in 0..<glitterCount {
            let t = CGFloat(index) / CGFloat(glitterCount)
            let y = horizon + (height - horizon) * t * 0.9 + rng.range(0, 3)
            let spread = bounds.width * (0.03 + t * 0.12)
            let lineWidth = spread * rng.range(0.3, 1.0)
            let x = sun.x + rng.range(-spread, spread) - lineWidth / 2
            glitter.addRect(CGRect(x: x, y: y, width: lineWidth, height: max(0.8, height * 0.004)))
        }
        context.fill(glitter, with: .color(palette.glow.opacity(0.35)))
        // Rolling swells.
        for layerIndex in 0..<4 {
            let depth = CGFloat(layerIndex)
            let base = horizon + (height - horizon) * (0.18 + depth * 0.22)
            let amplitude = height * (0.012 + depth * 0.01)
            let frequency = rng.range(2.0, 3.6) / (1 + depth * 0.25)
            let phase = rng.range(0, 2 * CGFloat.pi)
            let swell = Ridge(base: base, amplitude: amplitude, frequency: frequency, phase: phase, rng: &rng)
            let body = ridgePath(bounds: bounds, ridge: swell, closed: true)
            let color = palette.layers[min(2, layerIndex)]
            context.fill(body.path, with: .color(color.opacity(0.92)))
            let crest = ridgePath(bounds: bounds, ridge: swell, closed: false)
            let crestOpacity = 0.16 + Double(depth) * 0.04
            context.stroke(crest.path, with: .color(palette.glow.opacity(crestOpacity)), lineWidth: 1)
        }
    }

    private static func drawSkyline(_ context: inout GraphicsContext, bounds: CGRect, horizon: CGFloat,
                                    palette: DSArtPalette, rng: inout DSRandom) {
        let width = bounds.width
        let height = bounds.height
        // Far hills.
        let hillFrequency = rng.range(0.8, 1.6)
        let hillPhase = rng.range(0, 6)
        let hillRidge = Ridge(base: horizon, amplitude: height * 0.035, frequency: hillFrequency, phase: hillPhase, rng: &rng)
        let hills = ridgePath(bounds: bounds, ridge: hillRidge, closed: true)
        fillLayer(&context, path: hills.path, top: hills.top, bounds: bounds, color: palette.layers[0], rim: palette.glow)
        // Buildings with lit windows.
        let ground = horizon + (height - horizon) * 0.42
        var buildings = Path()
        var windows = Path()
        var x: CGFloat = -width * 0.02
        var windowBudget = 170
        while x < width {
            let buildingWidth = width * rng.range(0.045, 0.11)
            let buildingHeight = height * rng.range(0.07, 0.3)
            let rect = CGRect(x: x, y: ground - buildingHeight, width: buildingWidth, height: buildingHeight + 2)
            buildings.addRect(rect)
            let cell = max(2.2, width * 0.012)
            var wy = rect.minY + cell
            while wy < ground - cell && windowBudget > 0 {
                var wx = rect.minX + cell * 0.7
                while wx < rect.maxX - cell && windowBudget > 0 {
                    if rng.chance(0.22) {
                        windows.addRect(CGRect(x: wx, y: wy, width: cell * 0.55, height: cell * 0.7))
                        windowBudget -= 1
                    }
                    wx += cell * 1.4
                }
                wy += cell * 1.6
            }
            x += buildingWidth + width * rng.range(0.0, 0.012)
        }
        context.fill(buildings, with: .color(palette.layers[1]))
        context.fill(windows, with: .color(palette.glow.opacity(0.72)))
        // Foreground ground / water with a soft reflection of the glow.
        let foreground = CGRect(x: 0, y: ground, width: width, height: height - ground)
        let groundGradient = Gradient(colors: [palette.layers[2].opacity(0.94), palette.layers[2]])
        context.fill(Path(foreground), with: .linearGradient(groundGradient,
                                                             startPoint: CGPoint(x: 0, y: foreground.minY),
                                                             endPoint: CGPoint(x: 0, y: foreground.maxY)))
        drawMist(&context, bounds: bounds, y: ground, color: palette.glow)
    }

    // MARK: Finish

    private static func drawVignette(_ context: inout GraphicsContext, bounds: CGRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.height * 0.45)
        let radius = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot() * 0.62
        let gradient = Gradient(stops: [
            .init(color: Color.black.opacity(0), location: 0.5),
            .init(color: Color.black.opacity(0.55), location: 1),
        ])
        context.fill(Path(bounds), with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: radius))
    }

    private static func drawGrain(_ context: inout GraphicsContext, bounds: CGRect, rng: inout DSRandom) {
        let count = min(900, max(120, Int(bounds.width * bounds.height / 150)))
        var light = Path()
        var dark = Path()
        for index in 0..<count {
            let side = rng.range(0.5, 1.4)
            let rect = CGRect(x: bounds.width * rng.unit(), y: bounds.height * rng.unit(), width: side, height: side)
            if index % 2 == 0 {
                light.addRect(rect)
            } else {
                dark.addRect(rect)
            }
        }
        context.fill(light, with: .color(Color.white.opacity(0.07)))
        context.fill(dark, with: .color(Color.black.opacity(0.1)))
    }
}

// MARK: - Kinds

/// 2:3 poster: scenery + bold display title + small caption line.
private struct DSPosterArt: View {
    var seed: String
    var title: String?
    var caption: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas(opaque: true) { context, size in
                    DSScenery.draw(in: &context, size: size, seed: seed, wide: false)
                }
                if let title, !title.isEmpty, proxy.size.width >= 44 {
                    DSPosterTitleBlock(title: title, caption: caption, seed: seed, size: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Typographic treatments for generative posters, picked from the seed.
private struct DSPosterTitleStyle {
    let variant: Int

    static func pick(_ seed: String) -> DSPosterTitleStyle {
        DSPosterTitleStyle(variant: Int(DSHash.fnv1a64(seed + "#type") % 4))
    }

    var horizontal: HorizontalAlignment { variant == 1 ? .leading : .center }
    var textAlignment: TextAlignment { variant == 1 ? .leading : .center }
    var uppercase: Bool { variant == 0 || variant == 2 }
    var captionFirst: Bool { variant == 1 }

    var frameAlignment: Alignment {
        switch variant {
        case 1: return .bottomLeading
        case 2: return .top
        default: return .bottom
        }
    }

    func font(width: CGFloat, length: Int) -> Font {
        let scale: CGFloat
        if length <= 10 {
            scale = 1
        } else if length <= 20 {
            scale = 0.8
        } else {
            scale = 0.64
        }
        switch variant {
        case 0: return Font.system(size: width * 0.16 * scale, weight: .black).width(.condensed)
        case 1: return Font.system(size: width * 0.15 * scale, weight: .bold, design: .serif)
        case 2: return Font.system(size: width * 0.115 * scale, weight: .heavy).width(.expanded)
        default: return Font.system(size: width * 0.15 * scale, weight: .heavy, design: .rounded)
        }
    }

    func tracking(width: CGFloat) -> CGFloat {
        switch variant {
        case 0: return width * 0.004
        case 2: return width * 0.012
        default: return -width * 0.003
        }
    }
}

private struct DSPosterTitleBlock: View {
    var title: String
    var caption: String?
    var seed: String
    var size: CGSize

    var body: some View {
        let palette = DSArtPalette.forSeed(seed)
        let style = DSPosterTitleStyle.pick(seed)
        let width = size.width
        let showCaption = width >= 90
        VStack(alignment: style.horizontal, spacing: width * 0.035) {
            if style.captionFirst, showCaption, let caption {
                captionText(caption, palette: palette)
            }
            Text(style.uppercase ? title.uppercased() : title)
                .font(style.font(width: width, length: title.count))
                .tracking(style.tracking(width: width))
                .multilineTextAlignment(style.textAlignment)
                .lineLimit(3)
                .minimumScaleFactor(0.55)
                .foregroundStyle(palette.ink)
                .shadow(color: Color.black.opacity(0.55), radius: width * 0.025, x: 0, y: 1)
            Capsule()
                .fill(palette.glow)
                .frame(width: width * 0.16, height: max(1.5, width * 0.012))
            if !style.captionFirst, showCaption, let caption {
                captionText(caption, palette: palette)
            }
        }
        .padding(.horizontal, width * 0.08)
        .padding(.top, width * 0.1)
        .padding(.bottom, size.height * 0.13)
        .frame(width: size.width, height: size.height, alignment: style.frameAlignment)
    }

    private func captionText(_ text: String, palette: DSArtPalette) -> some View {
        Text(text.uppercased())
            .font(.system(size: max(7, size.width * 0.048), weight: .semibold))
            .tracking(max(0.6, size.width * 0.008))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(palette.ink.opacity(0.78))
    }
}

/// 16:9 backdrop / episode still: wide landscape, no text.
private struct DSLandscapeArt: View {
    var seed: String

    var body: some View {
        Canvas(opaque: true) { context, size in
            DSScenery.draw(in: &context, size: size, seed: seed, wide: true)
        }
    }
}

/// Transparent title treatment: heavy, tight tracking, gradient fill.
private struct DSLogoArt: View {
    var seed: String
    var title: String?
    var alignment: Alignment

    var body: some View {
        GeometryReader { proxy in
            let palette = DSArtPalette.forSeed(seed)
            let variant = Int(DSHash.fnv1a64(seed + "#logo") % 3)
            let fontSize = max(8, min(proxy.size.height * 0.62, proxy.size.width * 0.2))
            Text(variant == 2 ? (title ?? "").uppercased() : (title ?? ""))
                .font(DSLogoArt.font(variant: variant, size: fontSize))
                .tracking(-fontSize * 0.035)
                .multilineTextAlignment(DSLogoArt.textAlignment(alignment))
                .lineLimit(2)
                .minimumScaleFactor(0.25)
                .foregroundStyle(LinearGradient(colors: [palette.ink, palette.glow], startPoint: .top, endPoint: .bottom))
                .shadow(color: Color.black.opacity(0.5), radius: fontSize * 0.12, x: 0, y: fontSize * 0.04)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: alignment)
        }
    }

    static func font(variant: Int, size: CGFloat) -> Font {
        switch variant {
        case 0: return Font.system(size: size, weight: .black)
        case 1: return Font.system(size: size, weight: .heavy, design: .serif)
        default: return Font.system(size: size, weight: .black).width(.condensed)
        }
    }

    static func textAlignment(_ alignment: Alignment) -> TextAlignment {
        if alignment.horizontal == .leading { return .leading }
        if alignment.horizontal == .trailing { return .trailing }
        return .center
    }
}

/// Circle with a gradient and initials.
private struct DSPersonArt: View {
    var seed: String
    var title: String?

    var body: some View {
        GeometryReader { proxy in
            let palette = DSArtPalette.forSeed(seed)
            let diameter = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [palette.sky[2], palette.sky[0]],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                Circle()
                    .fill(RadialGradient(colors: [palette.glow.opacity(0.42), Color.clear],
                                         center: UnitPoint(x: 0.3, y: 0.22),
                                         startRadius: 0,
                                         endRadius: diameter * 0.75))
                Text(DSText.initials(title ?? seed))
                    .font(.system(size: diameter * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.94))
                    .minimumScaleFactor(0.5)
                    .shadow(color: Color.black.opacity(0.3), radius: diameter * 0.03, x: 0, y: 1)
                Circle()
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: max(1, diameter * 0.012))
            }
            .frame(width: diameter, height: diameter)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Rounded tile with a gradient, broadcast rings and the channel name (or initials) in bold.
private struct DSChannelArt: View {
    var seed: String
    var title: String?

    var body: some View {
        GeometryReader { proxy in
            let palette = DSArtPalette.forSeed(seed)
            let width = proxy.size.width
            let height = proxy.size.height
            let radius = min(min(width, height) * 0.16, Tuna.Metrics.cardRadius)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let lockup = DSText.channelLockup(title ?? seed)
            ZStack {
                shape.fill(LinearGradient(colors: [palette.sky[2], palette.sky[1], palette.sky[0]],
                                          startPoint: .topLeading,
                                          endPoint: .bottomTrailing))
                Canvas { context, size in
                    DSChannelArt.drawRings(&context, size: size, glow: palette.glow)
                }
                .clipShape(shape)
                VStack(spacing: height * 0.03) {
                    Text(lockup.big)
                        .font(.system(size: min(height * 0.34, width * 0.2), weight: .heavy, design: .rounded))
                        .tracking(-0.5)
                    if let small = lockup.small {
                        Text(small)
                            .font(.system(size: max(7, min(height * 0.1, width * 0.06)), weight: .bold))
                            .tracking(1.4)
                            .opacity(0.78)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .foregroundStyle(Color.white)
                .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 1)
                .padding(.horizontal, width * 0.08)
                shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            }
            .frame(width: width, height: height)
        }
    }

    static func drawRings(_ context: inout GraphicsContext, size: CGSize, glow: Color) {
        let center = CGPoint(x: size.width * 0.88, y: size.height * 0.12)
        let step = max(size.width, size.height) * 0.12
        var rings = Path()
        for index in 1...7 {
            let radius = step * CGFloat(index)
            rings.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        context.stroke(rings, with: .color(Color.white.opacity(0.07)), lineWidth: max(1, size.height * 0.012))
        let glowGradient = Gradient(colors: [glow.opacity(0.35), glow.opacity(0)])
        let bounds = CGRect(origin: .zero, size: size)
        context.fill(Path(bounds), with: .radialGradient(glowGradient, center: center, startRadius: 0,
                                                         endRadius: max(size.width, size.height) * 0.7))
    }
}

/// Studio/company monogram mark on a transparent background.
private struct DSStudioArt: View {
    var seed: String
    var title: String?

    var body: some View {
        GeometryReader { proxy in
            let palette = DSArtPalette.forSeed(seed)
            let diameter = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.04))
                Circle()
                    .strokeBorder(LinearGradient(colors: [palette.ink.opacity(0.9), palette.glow.opacity(0.6)],
                                                 startPoint: .top,
                                                 endPoint: .bottom),
                                  lineWidth: max(1.2, diameter * 0.035))
                Text(DSText.initials(title ?? seed))
                    .font(.system(size: diameter * 0.36, weight: .bold, design: .serif))
                    .foregroundStyle(palette.ink)
                    .minimumScaleFactor(0.5)
            }
            .frame(width: diameter, height: diameter)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

// MARK: - Text helpers

enum DSText {
    /// "Keanu Reeves" -> "KR", "Zendaya" -> "ZE".
    static func initials(_ text: String, limit: Int = 2) -> String {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2 {
            let letters = words.prefix(limit).compactMap { $0.first }
            return String(letters).uppercased()
        }
        if let word = words.first { return String(word.prefix(limit)).uppercased() }
        return "•"
    }

    /// Channel tile lockup: short names as-is, "Discovery Channel" -> ("Discovery", "CHANNEL"), else initials.
    static func channelLockup(_ name: String) -> (big: String, small: String?) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return ("TV", nil) }
        if clean.count <= 10 { return (clean, nil) }
        let words = clean.split(separator: " ")
        if words.count >= 2, let first = words.first, first.count <= 10 {
            let rest = words.dropFirst().joined(separator: " ")
            return (String(first), String(rest.prefix(22)).uppercased())
        }
        return (initials(clean, limit: 3), nil)
    }
}

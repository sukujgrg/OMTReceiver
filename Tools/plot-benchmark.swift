import AppKit
import Charts
import Foundation
import SwiftUI

struct BenchmarkPlotPoint: Identifiable {
    let id: String
    let minute: Double
    let value: Double
    let series: String
}

struct BenchmarkPanel: View {
    let title: String
    let points: [BenchmarkPlotPoint]
    let domain: ClosedRange<Double>
    let duration: Double
    var reference: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 16, weight: .semibold))
            Chart(points) { point in
                LineMark(x: .value("Minutes", point.minute), y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartYScale(domain: domain)
            .chartXScale(domain: 0...duration)
            .chartLegend(position: .top, alignment: .leading)
            .chartOverlay { proxy in
                if let reference, let y = proxy.position(forY: reference),
                   let plotFrame = proxy.plotFrame {
                    GeometryReader { geometry in
                        let frame = geometry[plotFrame]
                        Path { path in
                            path.move(to: CGPoint(x: frame.minX, y: frame.minY + y))
                            path.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + y))
                        }
                        .stroke(.gray.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
                }
            }
            .chartXAxisLabel("Minutes after baseline", alignment: .trailing)
        }
        .frame(height: 198)
    }
}

struct BenchmarkReportPlot: View {
    let fps: [BenchmarkPlotPoint]
    let decode: [BenchmarkPlotPoint]
    let lead: [BenchmarkPlotPoint]
    let memory: [BenchmarkPlotPoint]
    let duration: Double
    let notes: String
    let targetFPS: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("OMTReceiver — hardware trial")
                    .font(.system(size: 27, weight: .bold))
                Text("First-generation Apple TV 4K (A10X) · 1920×1080p\(String(format: "%.2f", targetFPS)) · Medium quality")
                    .font(.system(size: 15))
                Text(notes).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            BenchmarkPanel(title: "Video admitted to renderer (fps; dashed target = \(String(format: "%.2f", targetFPS)))",
                           points: fps, domain: 0...ceil(targetFPS * 1.1), duration: duration, reference: targetFPS)
            BenchmarkPanel(title: "Cumulative decode percentiles (ms; dashed frame budget = \(String(format: "%.1f", 1000 / targetFPS)))",
                           points: decode, domain: 0...40, duration: duration, reference: 1000 / targetFPS)
            BenchmarkPanel(title: "Scheduling lead at admission (ms; excludes physical HDMI/panel delay)",
                           points: lead, domain: 0...350, duration: duration)
            BenchmarkPanel(title: "Receiver physical memory footprint (MiB)",
                           points: memory, domain: 0...100, duration: duration)
            Text("Five-second receiver samples. Decode percentiles are upper bounds at 0.25 ms resolution.\nFrame admission and renderer counters do not establish physical display latency or audible continuity.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(width: 1080, height: 1110, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

@main
struct PlotBenchmark {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: plot-benchmark RUN-DIRECTORY OUTPUT.png\n", stderr)
            exit(64)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func object(_ name: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(name))) as! [String: Any]
        }
        let baseline = try object("receiver-baseline.json")
        let manifest = try object("manifest.json")
        let origin = (baseline["uptime"] as! NSNumber).doubleValue
        let text = try String(contentsOf: directory.appendingPathComponent("receiver-series.jsonl"), encoding: .utf8)
        var fps: [BenchmarkPlotPoint] = [], decode: [BenchmarkPlotPoint] = [], lead: [BenchmarkPlotPoint] = [], memory: [BenchmarkPlotPoint] = []
        var duration = 0.0
        for (index, line) in text.split(separator: "\n").enumerated() {
            let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let minute = ((row["uptime"] as! NSNumber).doubleValue - origin) / 60
            guard minute > 0 else { continue }
            duration = max(duration, minute)
            func point(_ value: Any?, _ name: String) -> BenchmarkPlotPoint? {
                guard let number = value as? NSNumber else { return nil }
                return .init(id: "\(index)-\(name)", minute: minute, value: number.doubleValue, series: name)
            }
            if let p = point(row["windowVideoAdmissionFPS"], "Admitted fps") { fps.append(p) }
            if let d = row["decodeMs"] as? [String: Any] {
                if let p = point(d["p95UpperBound"], "p95") { decode.append(p) }
                if let p = point(d["p99UpperBound"], "p99") { decode.append(p) }
            }
            if let p = point(row["currentAudioLeadMs"], "Audio") { lead.append(p) }
            if let p = point(row["currentVideoLeadMs"], "Video") { lead.append(p) }
            if let p = point(row["physicalFootprintMiB"], "Footprint") { memory.append(p) }
        }
        guard duration > 0 else { throw NSError(domain: "OMTBenchmarkPlot", code: 1, userInfo: [NSLocalizedDescriptionKey: "No samples after baseline."]) }
        let plot = BenchmarkReportPlot(fps: fps, decode: decode, lead: lead, memory: memory,
            duration: ceil(duration / 5) * 5,
            notes: manifest["setupNotes"] as? String ?? "Opaque VMX test pattern with 48 kHz stereo FPA1 audio",
            targetFPS: ((manifest["expectedFrameRateNumerator"] as? NSNumber)?.doubleValue)
                .map { $0 / ((manifest["expectedFrameRateDenominator"] as? NSNumber)?.doubleValue ?? 1) } ?? 30)
        let renderer = ImageRenderer(content: plot)
        renderer.scale = 1.5
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "OMTBenchmarkPlot", code: 2, userInfo: [NSLocalizedDescriptionKey: "The chart could not be rendered."])
        }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Saved \(CommandLine.arguments[2])")
    }
}

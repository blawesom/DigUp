import DigUpCore
import Foundation
import Testing
@testable import LlamaRuntime

/// What a card with little room gets: the whole model when it fits (the encoders with it), a share of the
/// layers when it doesn't (the layers a small card holds are layers the CPU doesn't run), and nothing when
/// there's no room worth taking. Pure arithmetic, so the small cards this machine doesn't have are covered
/// anyway.
struct GpuDecisionTests {
    static let gigabyte: UInt = 1 << 30

    @Test func aBigCardGetsEverything() {
        let full = LlamaEmbedder.gpuDecision(free: 8 * Self.gigabyte, weights: 865_000_000, name: "RX 9070")
        #expect(full.layers == 999)
        #expect(full.encoders == true)
        #expect(full.note.contains("RX 9070") == true)
    }

    @Test func aSmallCardGetsItsLayersWorth() {
        // 700 MB free against a ~1.3 GB ask: a share of the layers, the encoders on the CPU
        let plan = LlamaEmbedder.gpuDecision(free: 700 << 20, weights: 865_000_000, name: "RX 6400")
        #expect(plan.layers > 0 && plan.layers < 999)
        #expect(plan.encoders == false)
        #expect(plan.note.contains("layers") == true)
        // More free room, more layers
        let roomier = LlamaEmbedder.gpuDecision(free: 900 << 20, weights: 865_000_000, name: "RX 6400")
        #expect(roomier.layers > plan.layers)
        // A query encoder is a smaller ask (~310 MB plus the reserve): 1 GB is plenty for all of it
        let queries = LlamaEmbedder.gpuDecision(free: Self.gigabyte, weights: 310_000_000, name: "iGPU")
        #expect(queries.layers == 999)
        #expect(queries.encoders == true)
    }

    @Test func aCardWithoutRoomGetsNothing() {
        // Under the reserve for the compute buffers: the CPU, saying so
        let cramped = LlamaEmbedder.gpuDecision(free: 300 << 20, weights: 865_000_000, name: "old card")
        #expect(cramped.layers == 0)
        #expect(cramped.encoders == false)
        #expect(cramped.note.contains("the CPU") == true)
    }
}

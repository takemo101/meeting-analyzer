import Foundation
import Metal
import MetalPerformanceShadersGraph

/// Qwen3 の decoder ＋ 1 次元の判断の頭（Tiny-Jev）を、MPSGraph（Apple 標準の GPU のグラフ）で動かす。外部のコードは使わない。
/// 系列長は固定（右側を詰める。因果なので、手前の位置は、詰めた分に影響されない）。重みは bf16 のまま、グラフの定数に持つ。
/// 正規化・softmax・判断の頭は、fp32 で計算する。PyTorch（bf16）との差は、確率で最大 0.022・argmax は 30/30 一致（検証記録）。
/// 1 つのインスタンスは、同時に 1 つの呼び出しだけ（`SystemOneJudge` が、ロックで直列にする）。
final class QwenDecision: @unchecked Sendable {
    let shape: QwenShape
    let length: Int
    private let maxOptions = OptionMarkerPrompt.maxOptions
    private let device: MTLDevice
    private let graph = MPSGraph()
    private let queue: MTLCommandQueue
    private let gdev: MPSGraphDevice
    private let st: Safetensors
    private let dt: MPSDataType = .bFloat16
    private var xT: MPSGraphTensor!, cosT: MPSGraphTensor!, sinT: MPSGraphTensor!, posT: MPSGraphTensor!, outT: MPSGraphTensor!
    private let headWeights: [Float]
    private let headBias: Float
    private let cosData: Data, sinData: Data, maskData: Data

    init(shape: QwenShape, weights: URL, length: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw DecisionModelError.noGPU }
        self.device = device; self.queue = queue; self.gdev = MPSGraphDevice(mtlDevice: device)
        self.shape = shape; self.length = length
        st = try Safetensors(url: weights)
        let head = try st.info("head.weight")
        guard head.shape == [1, shape.hidden] else { throw DecisionModelError.unreadable("判断の頭の形が想定と違います") }
        headWeights = try st.floats("head.weight")
        headBias = try st.floats("head.bias").first ?? 0
        // RoPE（rotate_half 形式）：cos/sin は [L, headDim]
        var cosV = [Float](repeating: 0, count: length * shape.headDim), sinV = cosV
        let half = shape.headDim / 2
        for p in 0..<length {
            for i in 0..<half {
                let f = Float(p) * pow(shape.ropeTheta, -Float(2 * i) / Float(shape.headDim))
                cosV[p * shape.headDim + i] = cos(f); cosV[p * shape.headDim + i + half] = cos(f)
                sinV[p * shape.headDim + i] = sin(f); sinV[p * shape.headDim + i + half] = sin(f)
            }
        }
        cosData = cosV.withUnsafeBytes { Data($0) }; sinData = sinV.withUnsafeBytes { Data($0) }
        var mask = [Float](repeating: 0, count: length * length)
        for i in 0..<length { for j in (i + 1)..<max(length, i + 1) { mask[i * length + j] = -1e9 } }
        maskData = mask.withUnsafeBytes { Data($0) }
        try build()
    }

    // MARK: グラフ

    private func ns(_ a: [Int]) -> [NSNumber] { a.map { NSNumber(value: $0) } }
    private func cast(_ x: MPSGraphTensor, _ t: MPSDataType) -> MPSGraphTensor { x.dataType == t ? x : graph.cast(x, to: t, name: nil) }

    private func weight(_ name: String) throws -> MPSGraphTensor {
        let info = try st.info(name)
        guard info.dtype == "BF16" else { throw DecisionModelError.unreadable("\(name) の型が想定と違います") }
        return graph.constant(try st.bytes(name), shape: ns(info.shape), dataType: .bFloat16)
    }

    private func rms(_ x: MPSGraphTensor, _ w: MPSGraphTensor) -> MPSGraphTensor {
        let x32 = cast(x, .float32)
        let ms = graph.mean(of: graph.square(with: x32, name: nil), axes: [-1], name: nil)
        let r = graph.reciprocalSquareRoot(graph.addition(ms, graph.constant(Double(shape.rmsEps), dataType: .float32), name: nil), name: nil)
        return cast(graph.multiplication(graph.multiplication(x32, r, name: nil), cast(w, .float32), name: nil), x.dataType)
    }

    private func linear(_ x: MPSGraphTensor, _ name: String) throws -> MPSGraphTensor {
        graph.matrixMultiplication(primary: x, secondary: graph.transposeTensor(try weight(name), dimension: 0, withDimension: 1, name: nil), name: nil)
    }

    private func rotateHalf(_ x: MPSGraphTensor) -> MPSGraphTensor {
        let h = shape.headDim / 2
        let a = graph.sliceTensor(x, dimension: 2, start: 0, length: h, name: nil)
        let b = graph.sliceTensor(x, dimension: 2, start: h, length: h, name: nil)
        return graph.concatTensors([graph.negative(with: b, name: nil), a], dimension: 2, name: nil)
    }

    private func build() throws {
        let L = length, H = shape.hidden, d = shape.headDim
        xT = graph.placeholder(shape: ns([L, H]), dataType: dt, name: "x")
        cosT = graph.placeholder(shape: ns([1, L, d]), dataType: .float32, name: "cos")
        sinT = graph.placeholder(shape: ns([1, L, d]), dataType: .float32, name: "sin")
        posT = graph.placeholder(shape: ns([maxOptions]), dataType: .int32, name: "pos")
        let maskT = graph.constant(maskData, shape: ns([1, L, L]), dataType: .float32)
        let cosA = cast(cosT, dt), sinA = cast(sinT, dt)
        let rep = shape.heads / shape.kvHeads
        var h: MPSGraphTensor = xT
        for i in 0..<shape.layers {
            let p = "model.layers.\(i)."
            let a = rms(h, try weight(p + "input_layernorm.weight"))
            var q = graph.reshape(try linear(a, p + "self_attn.q_proj.weight"), shape: ns([L, shape.heads, d]), name: nil)
            var k = graph.reshape(try linear(a, p + "self_attn.k_proj.weight"), shape: ns([L, shape.kvHeads, d]), name: nil)
            let v = graph.reshape(try linear(a, p + "self_attn.v_proj.weight"), shape: ns([L, shape.kvHeads, d]), name: nil)
            q = rms(q, try weight(p + "self_attn.q_norm.weight")); k = rms(k, try weight(p + "self_attn.k_norm.weight"))
            q = graph.transpose(q, permutation: ns([1, 0, 2]), name: nil); k = graph.transpose(k, permutation: ns([1, 0, 2]), name: nil)
            var vt = graph.transpose(v, permutation: ns([1, 0, 2]), name: nil)
            q = graph.addition(graph.multiplication(q, cosA, name: nil), graph.multiplication(rotateHalf(q), sinA, name: nil), name: nil)
            k = graph.addition(graph.multiplication(k, cosA, name: nil), graph.multiplication(rotateHalf(k), sinA, name: nil), name: nil)
            // GQA：kv の頭を、問い合わせの頭の数まで繰り返す（頭 i が、問い合わせの頭 i·rep … i·rep+rep-1 に使われる）
            func repeatKV(_ t: MPSGraphTensor) -> MPSGraphTensor {
                let r = graph.reshape(t, shape: ns([shape.kvHeads, 1, L, d]), name: nil)
                let cat = graph.concatTensors(Array(repeating: r, count: rep), dimension: 1, name: nil)
                return graph.reshape(cat, shape: ns([shape.heads, L, d]), name: nil)
            }
            k = repeatKV(k); vt = repeatKV(vt)
            let scale = graph.constant(Double(1 / sqrt(Float(d))), dataType: .float32)
            var s = graph.matrixMultiplication(primary: q, secondary: graph.transposeTensor(k, dimension: 1, withDimension: 2, name: nil), name: nil)
            s = graph.addition(graph.multiplication(cast(s, .float32), scale, name: nil), maskT, name: nil)
            let pr = cast(graph.softMax(with: s, axis: -1, name: nil), dt)
            var o = graph.matrixMultiplication(primary: pr, secondary: vt, name: nil)
            o = graph.reshape(graph.transpose(o, permutation: ns([1, 0, 2]), name: nil), shape: ns([L, shape.heads * d]), name: nil)
            h = graph.addition(h, try linear(o, p + "self_attn.o_proj.weight"), name: nil)
            let m = rms(h, try weight(p + "post_attention_layernorm.weight"))
            let g = try linear(m, p + "mlp.gate_proj.weight"), u = try linear(m, p + "mlp.up_proj.weight")
            let act = graph.multiplication(graph.multiplication(g, graph.sigmoid(with: g, name: nil), name: nil), u, name: nil)
            h = graph.addition(h, try linear(act, p + "mlp.down_proj.weight"), name: nil)
        }
        h = rms(h, try weight("model.norm.weight"))
        // 選択肢の印の位置だけを取り出して、LayerNorm（重みなし）→ 判断の頭 → 温度
        let g = cast(graph.gather(withUpdatesTensor: h, indicesTensor: posT, axis: 0, batchDimensions: 0, name: nil), .float32)
        let mean = graph.mean(of: g, axes: [-1], name: nil)
        let cen = graph.subtraction(g, mean, name: nil)
        let variance = graph.mean(of: graph.square(with: cen, name: nil), axes: [-1], name: nil)
        let ln = graph.multiplication(cen, graph.reciprocalSquareRoot(graph.addition(variance, graph.constant(1e-5, dataType: .float32), name: nil), name: nil), name: nil)
        let hw = graph.constant(headWeights.withUnsafeBytes { Data($0) }, shape: ns([H, 1]), dataType: .float32)
        let logits = graph.addition(graph.matrixMultiplication(primary: ln, secondary: hw, name: nil), graph.constant(Double(headBias), dataType: .float32), name: nil)
        outT = graph.division(graph.reshape(logits, shape: ns([maxOptions]), name: nil), graph.constant(Double(shape.temperature), dataType: .float32), name: nil)
    }

    // MARK: 実行

    private func tensorData(_ data: Data, _ s: [Int], _ t: MPSDataType) -> MPSGraphTensorData {
        MPSGraphTensorData(device: gdev, data: data, shape: ns(s), dataType: t)
    }

    /// `ids`（長さ ≤ `length`）と、選択肢の印の位置 → 選択肢ごとの確率（合計 1）。
    func probabilities(ids: [Int], positions: [Int]) throws -> [Double] {
        guard ids.count <= length, !positions.isEmpty, positions.count <= maxOptions, positions.allSatisfy({ $0 >= 0 && $0 < ids.count }) else { throw DecisionModelError.inputTooLong }
        let H = shape.hidden
        var x = Data(count: length * H * 2)
        try x.withUnsafeMutableBytes { dst in
            for (i, id) in ids.enumerated() {
                let row = try st.bf16Row("model.embed_tokens.weight", row: id, width: H)
                for j in 0..<H { dst.storeBytes(of: UInt16(row[j].bitPattern >> 16), toByteOffset: (i * H + j) * 2, as: UInt16.self) }
            }
        }
        var pos = [Int32](repeating: 0, count: maxOptions)
        for (i, p) in positions.enumerated() { pos[i] = Int32(p) }
        let feeds: [MPSGraphTensor: MPSGraphTensorData] = [
            xT: tensorData(x, [length, H], dt),
            cosT: tensorData(cosData, [1, length, shape.headDim], .float32),
            sinT: tensorData(sinData, [1, length, shape.headDim], .float32),
            posT: tensorData(pos.withUnsafeBytes { Data($0) }, [maxOptions], .int32),
        ]
        let result = graph.run(with: queue, feeds: feeds, targetTensors: [outT], targetOperations: nil)
        guard let out = result[outT] else { throw DecisionModelError.failed("グラフの出力がありません") }
        var logits = [Float](repeating: 0, count: maxOptions)
        logits.withUnsafeMutableBytes { out.mpsndarray().readBytes($0.baseAddress!, strideBytes: nil) }
        let used = Array(logits.prefix(positions.count))
        guard used.allSatisfy({ $0.isFinite }), let top = used.max() else { throw DecisionModelError.failed("出力が数値ではありません") }
        let e = used.map { Double(exp($0 - top)) }
        let sum = e.reduce(0, +)
        return e.map { $0 / sum }
    }
}

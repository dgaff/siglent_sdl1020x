import SwiftUI
import LoadLabCore
import SDLKit

/// Colors shared by readouts and charts so a quantity looks the same everywhere.
extension Quantity {
    var color: Color {
        switch self {
        case .voltage: .blue
        case .current: .orange
        case .power: .pink
        case .resistance: .teal
        }
    }
}

/// Number entry bound to a device read-back.
///
/// Shows `value` (what the instrument reports) unless the user is editing. Commits on Return or
/// when focus leaves; the session clamps, writes, and reads back, so the field then shows what
/// the instrument actually accepted.
struct NumericField: View {
    let label: String
    let value: Double
    let unit: String
    var digits = 3
    var range: ClosedRange<Double>? = nil
    var disabled = false
    let commit: (Double) async -> Void

    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(label, text: $text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 96)
                    .focused($focused)
                    .disabled(disabled)
                    .onSubmit { submit() }
                    .onChange(of: focused) { _, f in
                        if f { editing = true } else if editing { submit() }
                    }
                Text(unit).foregroundStyle(.secondary).frame(minWidth: 34, alignment: .leading)
            }
        } label: {
            Text(label)
        }
        .help(range.map { "Range \(format($0.lowerBound)) – \(format($0.upperBound)) \(unit)" } ?? "")
        .onAppear { text = format(value) }
        .onChange(of: value) { _, v in if !editing { text = format(v) } }
    }

    private func format(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(digits)).grouping(.never)) }

    private func submit() {
        editing = false
        let cleaned = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned) else { text = format(value); return }
        if abs(v - value) < pow(10, -Double(digits + 1)) { text = format(value); return }
        Task {
            await commit(v)
            text = format(value)
        }
    }
}

/// Large live readout.
struct ReadoutTile: View {
    let quantity: Quantity
    let value: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(quantity.label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { Self.format($0, quantity) } ?? "—")
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(quantity.unit).font(.title3).foregroundStyle(quantity.color)
            }
        }
        .frame(minWidth: 132, alignment: .leading)
    }

    static func format(_ v: Double, _ q: Quantity) -> String {
        switch q {
        case .voltage, .current: return v.formatted(.number.precision(.fractionLength(4)))
        case .power: return v.formatted(.number.precision(.fractionLength(3)))
        case .resistance:
            if v == 0 { return "—" }
            return v >= 1000 ? (v / 1000).formatted(.number.precision(.fractionLength(3))) + "k"
                             : v.formatted(.number.precision(.fractionLength(3)))
        }
    }
}

struct StatusChip: View {
    let text: String
    var on: Bool = true
    var tint: Color = .accentColor
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(on ? tint.opacity(0.18) : Color.secondary.opacity(0.08), in: Capsule())
            .foregroundStyle(on ? tint : .secondary)
    }
}

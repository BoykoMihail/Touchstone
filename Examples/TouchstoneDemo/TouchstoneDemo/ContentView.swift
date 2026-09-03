import SwiftUI
import Touchstone

struct RootView: View {

    @State private var model = DemoModel()

    var body: some View {
        TabView {
            TypedOutputView(model: model)
                .tabItem { Label("Typed output", systemImage: "curlybraces") }

            StreamingView(model: model)
                .tabItem { Label("Streaming", systemImage: "dot.radiowaves.right") }
        }
    }
}

// MARK: - Typed output

struct TypedOutputView: View {

    @Bindable var model: DemoModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    backendSection
                    inputSection
                    runButton
                    resultSection
                }
                .padding()
            }
            .navigationTitle("Sentence → value")
            .background(Color(.systemGroupedBackground))
        }
    }

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Backend", selection: $model.backend) {
                ForEach(BackendChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(model.backend.requirement)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let blocker = model.blocker {
                // The interesting part of this label is that it is a sentence
                // rather than a boolean: `unavailableReason` tells you which of
                // four different problems you have.
                Label(blocker, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            switch model.backend {
            case .fake:
                Picker("Scenario", selection: $model.scenario) {
                    ForEach(FakeScenario.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Text(model.scenario.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case .ollama:
                LabeledContent("Model") {
                    TextField("model", text: $model.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }

            case .cloud:
                LabeledContent("Base URL") {
                    TextField("base URL", text: $model.cloudBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                LabeledContent("Model") {
                    TextField("model", text: $model.cloudModel)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                LabeledContent("API key") {
                    SecureField("sk-…", text: $model.cloudKey)
                        .textFieldStyle(.roundedBorder)
                }

            case .appleIntelligence:
                EmptyView()
            }
        }
        .card()
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What the user typed").sectionLabel()

            TextField("an expense, in words", text: $model.sentence, axis: .vertical)
                .textFieldStyle(.roundedBorder)

            if model.backend == .fake {
                Text("The fake ignores this text — its answers are scripted. Switch to a real backend to see the sentence matter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var runButton: some View {
        Button {
            Task { await model.extract() }
        } label: {
            HStack {
                if model.isRunning { ProgressView().controlSize(.small) }
                Text(model.isRunning ? "Asking…" : "Extract an Expense")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isRunning)
    }

    @ViewBuilder
    private var resultSection: some View {
        if !model.replies.isEmpty || model.failure != nil {
            VStack(alignment: .leading, spacing: 14) {

                HStack {
                    Text("Attempts").sectionLabel()
                    Spacer()
                    Text("\(model.attempts)")
                        .font(.system(.body, design: .monospaced))
                        .bold()
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("What the model said").sectionLabel()

                    ForEach(Array(model.replies.enumerated()), id: \.offset) { index, reply in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 16, alignment: .trailing)

                            Text(reply)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8)
                        .background(background(forReplyAt: index))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("What you got").sectionLabel()

                    if let expense = model.expense {
                        LabeledContent("amount") {
                            Text(expense.amount.description)
                                .font(.system(.body, design: .monospaced))
                                .bold()
                        }
                        LabeledContent("category") {
                            Text(expense.category)
                                .font(.system(.body, design: .monospaced))
                                .bold()
                        }
                        Text("A value of type Expense. Not a string that looks like one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let failure = model.failure {
                        Text(failure)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)

                        Text("An error, which is the point: no partially filled value, no silent zero.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .card()
        }
    }

    /// The last reply is the one that decoded — unless nothing did.
    private func background(forReplyAt index: Int) -> Color {
        let isLast = index == model.replies.count - 1
        if model.expense != nil && isLast {
            return Color.green.opacity(0.12)
        }
        return Color.red.opacity(0.08)
    }
}

// MARK: - Streaming

struct StreamingView: View {

    @Bindable var model: DemoModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Why this tab exists").sectionLabel()
                        Text("Cancelling stops generation. There is no handle to keep and nothing to remember to tear down: the work runs inside the stream's own task, so structured concurrency does it. Press Start, then Cancel halfway.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .card()

                    HStack {
                        Button("Start") { model.startStreaming() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isStreaming)

                        Button("Cancel") { model.cancelStreaming() }
                            .buttonStyle(.bordered)
                            .disabled(!model.isStreaming)

                        Spacer()

                        Text("\(model.chunkCount) chunks")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Arriving").sectionLabel()

                        Text(model.streamed.isEmpty ? "—" : model.streamed)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                            .textSelection(.enabled)

                        if let failure = model.streamFailure {
                            Text(failure)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                    }
                    .card()
                }
                .padding()
            }
            .navigationTitle("Streaming")
            .background(Color(.systemGroupedBackground))
        }
    }
}

// MARK: - Small shared styling

struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct SectionLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}

extension View {
    func card() -> some View { modifier(Card()) }
    func sectionLabel() -> some View { modifier(SectionLabel()) }
}

#Preview {
    RootView()
}

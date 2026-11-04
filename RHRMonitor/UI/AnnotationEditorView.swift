import SwiftUI
import HeartRateKit

/// Quick, optional behavior logging. Only the toggled behaviors are saved.
struct AnnotationEditorView: View {
    let initialKind: AnnotationKind?
    let onSave: ([Annotation]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var caffeine = false
    @State private var caffeineServings = 1
    @State private var alcohol = false
    @State private var drinks = 1
    @State private var sleep = false
    @State private var sleepHours = 7.5
    @State private var exercise = false
    @State private var exerciseType = ""
    @State private var intensity = 3
    @State private var stress = false
    @State private var stressLevel = 3
    @State private var travel = false
    @State private var illness = false
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Day", selection: $date, in: ...Date(), displayedComponents: .date)
                }
                Section {
                    Toggle(isOn: $caffeine) { Label("Caffeine", systemImage: AnnotationKind.caffeine.systemImage) }
                    if caffeine { Stepper("\(caffeineServings) serving\(caffeineServings == 1 ? "" : "s")", value: $caffeineServings, in: 1...10) }
                    Toggle(isOn: $alcohol) { Label("Alcohol", systemImage: AnnotationKind.alcohol.systemImage) }
                    if alcohol { Stepper("\(drinks) drink\(drinks == 1 ? "" : "s")", value: $drinks, in: 1...15) }
                    Toggle(isOn: $exercise) { Label("Exercise", systemImage: AnnotationKind.exercise.systemImage) }
                    if exercise {
                        TextField("Type (e.g. run, lifting)", text: $exerciseType)
                        Stepper("Intensity \(intensity) of 5", value: $intensity, in: 1...5)
                    }
                    Toggle(isOn: $stress) { Label("Stress", systemImage: AnnotationKind.stress.systemImage) }
                    if stress { Stepper("Level \(stressLevel) of 5", value: $stressLevel, in: 1...5) }
                    Toggle(isOn: $travel) { Label("Travel", systemImage: AnnotationKind.travel.systemImage) }
                    Toggle(isOn: $illness) { Label("Illness", systemImage: AnnotationKind.illness.systemImage) }
                } header: {
                    Text("Behaviors on this day")
                }
                Section {
                    Toggle(isOn: $sleep) { Label("Sleep last night", systemImage: AnnotationKind.sleep.systemImage) }
                    if sleep { Stepper(String(format: "%.1f hours", sleepHours), value: $sleepHours, in: 0...14, step: 0.5) }
                } footer: {
                    Text("Log sleep on the morning after, so it lines up with that morning's resting heart rate.")
                }
                Section("Note") {
                    TextField("Anything else", text: $note, axis: .vertical)
                }
            }
            .navigationTitle("Add Annotation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(build())
                        dismiss()
                    }
                    .disabled(build().isEmpty)
                }
            }
            .onAppear { preselect() }
        }
    }

    private func preselect() {
        switch initialKind {
        case .caffeine: caffeine = true
        case .alcohol: alcohol = true
        case .sleep: sleep = true
        case .exercise: exercise = true
        case .stress: stress = true
        case .travel: travel = true
        case .illness: illness = true
        case .note, .none: break
        }
    }

    private func build() -> [Annotation] {
        let day = CalendarDay(date)
        var out: [Annotation] = []
        if caffeine { out.append(Annotation(day: day, kind: .caffeine, value: Double(caffeineServings))) }
        if alcohol { out.append(Annotation(day: day, kind: .alcohol, value: Double(drinks))) }
        if exercise {
            out.append(Annotation(day: day, kind: .exercise, value: Double(intensity),
                                  text: exerciseType.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if stress { out.append(Annotation(day: day, kind: .stress, value: Double(stressLevel))) }
        if travel { out.append(Annotation(day: day, kind: .travel)) }
        if illness { out.append(Annotation(day: day, kind: .illness)) }
        if sleep { out.append(Annotation(day: day, kind: .sleep, value: sleepHours)) }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { out.append(Annotation(day: day, kind: .note, text: trimmed)) }
        return out
    }
}

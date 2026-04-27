import SwiftUI

struct FeedbackComposerView: View {
    @Bindable var model: FeedbackComposerModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case message
        case email
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Space.xl) {
                    headerCard
                    categoryCard
                    messageCard
                    contactCard

                    if let banner = statusBanner {
                        banner
                    }
                }
                .padding(.horizontal, DesignTokens.Space.xl)
                .padding(.top, DesignTokens.Space.lg)
                .padding(.bottom, DesignTokens.Space.xxxl)
            }
            .background(backgroundGradient.ignoresSafeArea())
            .navigationTitle("Send feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("feedback.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    submitButton
                }
            }
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [DesignTokens.Palette.canvas, DesignTokens.Palette.canvasSunken],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
            Text("Tell us what worked, what broke, or what you wish RoadSense could do.")
                .font(.system(size: 16))
                .foregroundStyle(DesignTokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("We don't include your location, drive data, or device ID with feedback. We do attach the app version, your iOS version, and the screen you came from so a tester report is reproducible.")
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.lg)
        .background(DesignTokens.Palette.surface, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }

    private var categoryCard: some View {
        cardContainer(title: "What's it about?") {
            VStack(spacing: 0) {
                ForEach(Array(FeedbackCategory.allCases.enumerated()), id: \.element.id) { index, category in
                    Button {
                        model.category = category
                    } label: {
                        HStack(spacing: DesignTokens.Space.md) {
                            Image(systemName: model.category == category ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(model.category == category ? DesignTokens.Palette.deep : DesignTokens.Palette.inkMuted)

                            Text(category.displayName)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(DesignTokens.Palette.ink)

                            Spacer()
                        }
                        .padding(.horizontal, DesignTokens.Space.md)
                        .padding(.vertical, DesignTokens.Space.sm)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("feedback.category.\(category.rawValue)")

                    if index < FeedbackCategory.allCases.count - 1 {
                        Divider()
                    }
                }
            }
            .background(DesignTokens.Palette.canvasSunken, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
        }
    }

    private var messageCard: some View {
        cardContainer(title: "What happened?") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.sm) {
                TextEditor(text: $model.message)
                    .focused($focusedField, equals: .message)
                    .frame(minHeight: 160)
                    .padding(DesignTokens.Space.sm)
                    .background(DesignTokens.Palette.canvasSunken, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                            .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
                    )
                    .accessibilityIdentifier("feedback.message")

                HStack {
                    Text("At least \(FeedbackComposerModel.messageMinimumLength) characters.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.Palette.inkMuted)

                    Spacer()

                    Text(model.characterCountLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignTokens.Palette.inkMuted)
                }
            }
        }
    }

    private var contactCard: some View {
        cardContainer(title: "Reply (optional)") {
            VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
                TextField("you@example.com", text: $model.replyEmail)
                    .focused($focusedField, equals: .email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(DesignTokens.Space.md)
                    .background(DesignTokens.Palette.canvasSunken, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                            .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
                    )
                    .accessibilityIdentifier("feedback.reply-email")

                Toggle(isOn: $model.contactConsent) {
                    Text("OK to email me about this report")
                        .font(.system(size: 14))
                        .foregroundStyle(DesignTokens.Palette.ink)
                }
                .tint(DesignTokens.Palette.deep)
                .accessibilityIdentifier("feedback.contact-consent")
            }
        }
    }

    @ViewBuilder
    private func cardContainer<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.md) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignTokens.Palette.ink)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.lg)
        .background(DesignTokens.Palette.surface, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .strokeBorder(DesignTokens.Palette.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusBanner: (some View)? {
        switch model.status {
        case .idle, .submitting:
            EmptyView()
        case .submitted:
            statusCard(
                tint: DesignTokens.Palette.smooth,
                title: "Thanks — feedback received.",
                subtitle: "We read everything that comes through. You can close this screen now."
            )
        case let .validationFailed(fieldErrors):
            statusCard(
                tint: DesignTokens.Palette.warning,
                title: "Couldn't send that yet.",
                subtitle: validationSummary(fieldErrors)
            )
        case let .rateLimited(retryAfterSeconds):
            statusCard(
                tint: DesignTokens.Palette.warning,
                title: "Too many submissions from this network.",
                subtitle: rateLimitSubtitle(retryAfterSeconds: retryAfterSeconds)
            )
        case let .networkError(message):
            statusCard(
                tint: DesignTokens.Palette.danger,
                title: "Couldn't reach RoadSense.",
                subtitle: "Check your connection and try again. (\(message))"
            )
        case let .serverError(statusCode):
            statusCard(
                tint: DesignTokens.Palette.danger,
                title: "Server error \(statusCode).",
                subtitle: "Your form is still here — try sending it again in a moment."
            )
        }
    }

    private func statusCard(tint: Color, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.Palette.ink)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Space.md)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        )
        .accessibilityIdentifier("feedback.status-banner")
    }

    private var submitButton: some View {
        Button {
            focusedField = nil
            Task { await model.submit() }
        } label: {
            if case .submitting = model.status {
                ProgressView()
            } else {
                Text("Send")
                    .font(.system(size: 16, weight: .semibold))
            }
        }
        .disabled(!model.canSubmit)
        .accessibilityIdentifier("feedback.submit")
    }

    private func validationSummary(_ errors: [String: String]) -> String {
        if errors.isEmpty {
            return "Your message couldn't be saved. Try shortening it or removing unusual characters."
        }
        return errors.values.sorted().joined(separator: " · ")
    }

    private func rateLimitSubtitle(retryAfterSeconds: TimeInterval?) -> String {
        guard let retryAfterSeconds, retryAfterSeconds > 0 else {
            return "Try again in a few minutes."
        }
        let minutes = Int(ceil(retryAfterSeconds / 60))
        if minutes <= 1 {
            return "Try again in about a minute."
        }
        return "Try again in about \(minutes) minutes."
    }
}

import SwiftUI
import MLXRuntime

// ─────────────────────────────────────────────────────────────
// The model manager (ARCHITECTURE §9.4, P5.2).
//
// Two lists and one number: what is on this machine, what can be fetched, and
// how much space that leaves. The number is not decoration — one 30B
// checkpoint is 17 GB, and the app is the only thing here that can fill a
// disk.
// ─────────────────────────────────────────────────────────────

struct ModelsView: View {
    @Bindable var model: ModelsViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    installedSection
                    leftoverSection
                    recommendedSection
                }
                .padding(Space.section)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(localised: "On-device models (Tier 0.5)",
                 "Heading of the models screen. 'Tier 0.5' is the name of the guarantee floor.")
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                if let storage = model.storage {
                    Text(localised: "\(bytes(storage.usedBytes)) of a \(bytes(storage.quotaBytes)) quota used · \(bytes(storage.freeDiskBytes)) free on disk",
                         "Model storage summary. Placeholders: used, quota, and free disk space.")
                }
                // §9.4's RAM→size→work table, for this machine specifically.
                Text(localised: "RAM \(bytes(model.memory.totalBytes)) (\(bytes(model.memory.availableBytes)) free) → suggested \(model.sizeClass.recommendedSize) · \(model.sizeClass.trustedWith)",
                     "Memory summary and what it can run. Placeholders: total RAM, free RAM, a suggested model size, and what that size can be trusted with.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            if let status = model.status {
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(status.isError ? .red : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 380, alignment: .trailing)
            }
        }
        .padding(Space.box)
    }

    // MARK: - installed

    @ViewBuilder
    private var installedSection: some View {
        Text(localised: "Installed", "Heading over models already on the machine.")
            .font(.subheadline).bold()
        if model.installed.isEmpty {
            // Says what the absence means, not just that the list is empty:
            // with no model here the guaranteed floor (§9.2 rule 4) is missing.
            ContentUnavailableView(
                t("No model on this machine yet", "Empty state on the models screen."),
                systemImage: "cpu",
                description: Text(localised: "Tier 0.5 is the guarantee floor — if the endpoint is down or you are offline, work that needs accuracy has nowhere to run. Download one from the list below.",
                                  "Empty-state explanation on the models screen."))
                .frame(height: 160)
        } else {
            ForEach(model.installed, id: \.name) { installed in
                InstalledRow(model: model, installed: installed)
            }
        }
    }

    // MARK: - leftovers (§9.4, P5.2)

    /// Downloads that stopped halfway. Separate from the installed list on
    /// purpose — they are not models, they cannot be loaded, and putting them
    /// in the same list is how a broken 17 GB directory gets chosen as the
    /// local tier. What they are is disk space with no way to reclaim it
    /// except a terminal, which this screen exists to replace.
    @ViewBuilder
    private var leftoverSection: some View {
        if !model.leftovers.isEmpty {
            Text(localised: "Unfinished downloads", "Heading over partial model downloads.")
                .font(.subheadline).bold()
            Text(localised: "These did not finish, so they cannot be loaded as models — but they still take space and count against the quota",
                 "Explains why unfinished downloads are shown.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.leftovers) { leftover in
                HStack(spacing: Space.row) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(leftover.directory.lastPathComponent).font(.callout)
                        Text("\(leftover.missing) · "
                             + ByteCountFormatter.string(fromByteCount: leftover.bytes,
                                                         countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if leftover.isOurs {
                        Button(t("Delete the partial files", "Button that removes an unfinished download."),
                               role: .destructive) {
                            Task { await model.remove(leftover) }
                        }
                        .accessibilityLabel(t("Delete the partial files of \(leftover.directory.lastPathComponent)",
                                              "Screen-reader label. Placeholder is the directory name."))
                    } else {
                        // Somebody else's library is somebody else's to tidy,
                        // and the path is what somebody needs to go and do it.
                        Text(localised: "in another program's cache",
                             "Marker on a leftover download the app does not own.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .help(leftover.directory.path(percentEncoded: false))
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - recommended

    @ViewBuilder
    private var recommendedSection: some View {
        Text(localised: "Download more", "Heading over models available to download.")
            .font(.subheadline).bold()
        Text(localised: "This list is what our runtime can really load — not everything on Hugging Face",
             "Explains why the download list is short.")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(model.recommended) { entry in
            CatalogRow(model: model, entry: entry)
        }
    }

    private func bytes(_ value: Int64) -> String { ModelsView.format(value) }

    static func format(_ value: Int64) -> String {
        let gb = Double(value) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb)
                       : String(format: "%.0f MB", Double(value) / 1_048_576)
    }
}

private struct InstalledRow: View {
    @Bindable var model: ModelsViewModel
    let installed: LocalModel
    @State private var removable = false
    @State private var confirmingDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(installed.name).font(.body).bold()
                    if model.isSelected(installed) {
                        Text(localised: "in use", "Marker on the model currently selected.")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                Text("\(ModelsView.format(installed.sizeOnDisk)) · context \(installed.contextWindow) "
                     + (installed.supportsTools
                        ? t("· can call tools", "Marker on a model that supports tool calling.")
                        : t("· cannot call tools", "Marker on a model that does not support tool calling.")))
                    .font(.caption).foregroundStyle(.secondary)
                // The estimate the selection is allowed or refused on, shown
                // with its numbers rather than as a verdict the user has to
                // take on trust.
                let admission = model.admission(for: installed)
                Text(admission.reason)
                    .font(.caption2)
                    .foregroundStyle(admission.isBlocking ? Color.red
                                     : admission.verdict == .tight ? Color.orange : Color.secondary)
                if !removable {
                    // Explains why Delete is missing: the catalogue also finds
                    // models owned by LM Studio, and this app does not delete
                    // other applications' files.
                    Text(localised: "outside the app's folder — cannot be deleted from here",
                         "Marker on a model the app does not own.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if !model.isSelected(installed) {
                Button(t("Use this one", "Button that selects a model as the local tier.")) {
                    model.select(installed)
                }
                    // Blocked rather than warned: §9.4 is explicit that a
                    // model over the line must not become the default.
                    .disabled(model.admission(for: installed).isBlocking)
            }
            if removable {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label(t("Delete", "Context-menu item that removes a file."), systemImage: "trash")
                }
                .labelStyle(.iconOnly)
            }
        }
        .padding(Space.box)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Radius.box))
        .task { removable = await model.isRemovable(installed) }
        .confirmationDialog(t("Delete \(installed.name)?",
                              "Confirmation title. Placeholder is the model name."),
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(t("Delete", "Context-menu item that removes a file."),
                   role: .destructive) { Task { await model.delete(installed) } }
            Button(t("Cancel", "Button that dismisses the delete confirmation."), role: .cancel) {}
        } message: {
            Text(localised: "Frees \(ModelsView.format(installed.sizeOnDisk)) — it can be downloaded again later",
                 "Message in the delete confirmation. Placeholder is how much space is freed.")
        }
    }
}

private struct CatalogRow: View {
    @Bindable var model: ModelsViewModel
    let entry: ModelCatalogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(entry.displayName) · \(entry.quantization)").font(.body).bold()
                Text(entry.summary).font(.caption).foregroundStyle(.secondary)
                Text(localised: "\(ModelsView.format(entry.downloadBytes)) download · needs \(ModelsView.format(entry.minimumRAMBytes)) RAM or more",
                     "A downloadable model. Placeholders: the download size and the minimum RAM.")
                    .font(.caption2).foregroundStyle(.tertiary)
                let admission = model.admission(for: entry)
                if admission.isBlocking {
                    // Downloading is still allowed — the machine may have
                    // memory free later, and the user may be about to close
                    // everything else — but it says plainly that it cannot be
                    // made the default as things stand.
                    Label("\(admission.reason)", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if let download = model.downloads[entry.repository] {
                    ProgressView(value: download.fraction)
                        .frame(maxWidth: 320)
                    // "≈" because the Hub reports progress per file, not per
                    // byte; the figure is that fraction of the recorded size.
                    Text("≈ \(ModelsView.format(download.completedBytes)) / \(ModelsView.format(download.totalBytes))")
                        .font(.caption2).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            if model.isDownloading(entry) {
                Button(t("Cancel", "Button that stops a running download.")) { model.cancel(entry) }
            } else {
                Button(t("Download", "Button that starts downloading a model.")) { model.download(entry) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Space.box)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Radius.box))
    }
}

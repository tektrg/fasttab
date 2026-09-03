import SwiftUI
import FastTabSync

/// Sheet for creating a new bookmark folder or subfolder.
/// Can be invoked with a preselected profile and/or parent folder path (e.g. from
/// a folder row's "Add Subfolder" action), or default to top-level creation.
struct NewBookmarkFolderSheet: View {
    @ObservedObject private var localCache = LocalCache.shared
    @Environment(\.dismiss) private var dismiss

    let sourceDeviceID: String
    var initialProfileKey: String? = nil
    var initialParentPath: [String] = []
    let onCreate: (String, String, String, [String]) -> Void // (browserName, profileName, folderName, parentFolderPath)

    @State private var folderName: String = ""
    @State private var selectedProfileKey: String = ""
    @State private var selectedParentPath: [String] = []
    @FocusState private var isNameFocused: Bool

    private struct ProfileOption: Identifiable, Hashable {
        let browserName: String
        let profileName: String
        var key: String { "\(browserName)|\(profileName)" }
        var displayName: String { "\(browserName) — \(profileName)" }
        var id: String { key }
    }

    private struct ParentFolderOption: Identifiable, Hashable {
        let path: [String]
        var id: String { path.joined(separator: "/") }
        var displayName: String {
            path.isEmpty ? "Top Level (Root)" : path.joined(separator: " / ")
        }
    }

    /// Writable profiles for this device (excludes Safari).
    private var availableProfiles: [ProfileOption] {
        guard !sourceDeviceID.isEmpty else { return [] }
        let blobs = localCache.state.bookmarkBlobs.filter {
            $0.deviceID == sourceDeviceID && !$0.browserName.lowercased().contains("safari")
        }
        var seen = Set<String>()
        var options: [ProfileOption] = []
        for blob in blobs {
            let opt = ProfileOption(browserName: blob.browserName, profileName: blob.profileName)
            if !seen.contains(opt.key) {
                seen.insert(opt.key)
                options.append(opt)
            }
        }
        return options.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Available parent folders in the currently selected profile.
    private var availableParentFolders: [ParentFolderOption] {
        var options = [ParentFolderOption(path: [])] // Top Level
        guard let blob = localCache.state.bookmarkBlobs.first(where: {
            $0.deviceID == sourceDeviceID && "\($0.browserName)|\($0.profileName)" == selectedProfileKey
        }) else {
            return options
        }

        var distinctPaths = Set<[String]>()
        for bookmark in blob.bookmarks {
            let path = BookmarkTreeBuilder.splitPath(bookmark.folderPath ?? "")
            if !path.isEmpty {
                // Add all prefixes as parent folder options too
                for i in 1...path.count {
                    distinctPaths.insert(Array(path.prefix(i)))
                }
            }
        }

        let sortedPaths = distinctPaths.sorted {
            $0.joined(separator: " / ").localizedCaseInsensitiveCompare($1.joined(separator: " / ")) == .orderedAscending
        }

        for path in sortedPaths {
            options.append(ParentFolderOption(path: path))
        }
        return options
    }

    private var trimmedName: String {
        folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var containsInvalidChars: Bool {
        folderName.contains("/") || folderName.contains("\\")
    }

    private var isDuplicateName: Bool {
        guard !trimmedName.isEmpty else { return false }
        let fullPath = selectedParentPath + [trimmedName]
        return availableParentFolders.contains { $0.path == fullPath }
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && !containsInvalidChars && !selectedProfileKey.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Folder Name", text: $folderName)
                        .focused($isNameFocused)
                        .autocorrectionDisabled()

                    if containsInvalidChars {
                        Text("Folder names cannot contain \"/\" or \"\\\"")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if isDuplicateName {
                        Text("A folder with this name already exists at this location.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Folder Details")
                } footer: {
                    if !trimmedName.isEmpty && !containsInvalidChars {
                        let destinationPreview = (selectedParentPath + [trimmedName]).joined(separator: " / ")
                        Text("Location: \(destinationPreview)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if availableProfiles.count > 1 {
                    Section("Browser Profile") {
                        Picker("Profile", selection: $selectedProfileKey) {
                            ForEach(availableProfiles) { profile in
                                Text(profile.displayName).tag(profile.key)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } else if let onlyProfile = availableProfiles.first {
                    Section("Browser Profile") {
                        HStack {
                            Text("Profile")
                            Spacer()
                            Text(onlyProfile.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Parent Folder") {
                    Picker("Parent", selection: $selectedParentPath) {
                        ForEach(availableParentFolders) { option in
                            HStack {
                                Image(systemName: option.path.isEmpty ? "tray" : "folder")
                                Text(option.displayName)
                            }
                            .tag(option.path)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .navigationTitle("New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        confirmCreate()
                    }
                    .disabled(!isValid)
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                initializeDefaults()
                isNameFocused = true
            }
        }
    }

    private func initializeDefaults() {
        if let initialKey = initialProfileKey, availableProfiles.contains(where: { $0.key == initialKey }) {
            selectedProfileKey = initialKey
        } else if let first = availableProfiles.first {
            selectedProfileKey = first.key
        }

        if !initialParentPath.isEmpty {
            selectedParentPath = initialParentPath
        }
    }

    private func confirmCreate() {
        guard isValid else { return }
        guard let profile = availableProfiles.first(where: { $0.key == selectedProfileKey }) else { return }
        onCreate(profile.browserName, profile.profileName, trimmedName, selectedParentPath)
        dismiss()
    }
}

import ContactsUI
import SwiftUI

/// The system shares only the selected contact snapshot; no address-book access
/// is requested. Selection is an editable name suggestion, not owner detection.
struct ProfileContactPicker: UIViewControllerRepresentable {
    let onSelection: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactGivenNameKey]
        picker.predicateForSelectionOfContact = NSPredicate(value: true)
        return picker
    }

    func updateUIViewController(_ picker: CNContactPickerViewController, context: Context) {
        context.coordinator.onSelection = onSelection
        context.coordinator.onCancel = onCancel
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency CNContactPickerDelegate {
        var onSelection: (String) -> Void
        var onCancel: () -> Void
        private var completed = false

        init(onSelection: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onSelection = onSelection
            self.onCancel = onCancel
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            guard !completed else { return }
            completed = true
            let name = contact.isKeyAvailable(CNContactGivenNameKey) ? contact.givenName : ""
            onSelection(UserProfile.normalize(name))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            guard !completed else { return }
            completed = true
            onCancel()
        }
    }
}

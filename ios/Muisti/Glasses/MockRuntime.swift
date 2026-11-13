/// Whether MockDeviceKit is currently standing in for the glasses. Set by
/// `MockDeviceController` (DEBUG only); always `false` in Release.
@MainActor
enum MockRuntime {
    static var isActive = false
}

import Foundation
struct CapturedFrame { let id = UUID(); let capturedAt = Date() }
enum PerceptionEngine {
    struct TextLine { let text: String; let box: CGRect; let confidence: Float }
}

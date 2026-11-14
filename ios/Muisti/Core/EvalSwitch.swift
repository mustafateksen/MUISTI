import CoreGraphics
import Foundation

/// Launch arguments that turn single features off, so the evaluation sets can measure what
/// each one is worth on the same stored records. Debug builds only; never set in normal use.
enum EvalSwitch {
    private static func has(_ flag: String) -> Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(flag)
        #else
        return false
        #endif
    }

    /// `--no-image-channel`: search without the keyframe (image) vectors.
    static let noImageChannel = has("--no-image-channel")
    /// `--no-unsure`: show visible things without their [unsure] marks.
    static let noUnsure = has("--no-unsure")
    /// `--no-look-again`: skip the visual re-check of answers.
    static let noLookAgain = has("--no-look-again")
    /// `--picture-cell=640`: cell size of the answer picture grid.
    static let pictureCell: CGFloat? = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--picture-cell=") }
            .flatMap { Double($0.dropFirst("--picture-cell=".count)) }.map { CGFloat($0) }
        #else
        nil
        #endif
    }()

    static func visual(_ text: String) -> String {
        noUnsure ? text.replacingOccurrences(of: " [unsure]", with: "") : text
    }
}

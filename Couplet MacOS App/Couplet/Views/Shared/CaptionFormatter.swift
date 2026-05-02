import Foundation

extension String {
    /// Strips common qwen2.5vl caption openers before display (not in the DB).
    /// Returns the original string unchanged if the stripped result is shorter than
    /// 20 characters or if no known opener is matched.
    func strippingCaptionOpener() -> String {
        // More-specific (longer) patterns must appear before any prefix they share
        // with a shorter pattern so we match the most specific opener first.
        let openers: [String] = [
            "In this image, we see ",
            "In this photograph, we see ",
            "In this photo, we see ",
            "In this scene, we see ",
            "In this image, ",
            "In this photograph, ",
            "In this photo, ",
            "In this scene, ",
            "The photograph captures ",
            "The photograph depicts ",
            "The photograph shows ",
            "The photograph features ",
            "The photograph portrays ",
            "The photograph presents ",
            "The image captures ",
            "The image depicts ",
            "The image shows ",
            "The image features ",
            "The image portrays ",
            "The image presents ",
            "The scene unfolds with ",
            "The scene unfolds in ",
            "The scene unfolds on ",
            "The scene unfolds ",
            "The scene captures ",
            "The scene depicts ",
            "The scene shows ",
            "This photograph captures ",
            "This photograph depicts ",
            "This photograph shows ",
            "This photograph features ",
            "This photograph portrays ",
            "This image captures ",
            "This image depicts ",
            "This image shows ",
            "This image features ",
            "This image portrays ",
            "This scene captures ",
            "This scene depicts ",
            "This scene shows ",
        ]
        for opener in openers {
            if self.hasPrefix(opener) {
                let remainder = String(self.dropFirst(opener.count))
                guard remainder.count >= 20 else { return self }
                return remainder.prefix(1).uppercased() + remainder.dropFirst()
            }
        }
        return self
    }
}

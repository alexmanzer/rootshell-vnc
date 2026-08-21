import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

/// One recognized line in Vision's normalized, bottom-left image space.
struct AppleLoginTextLine: Equatable, Sendable {
    let text: String
    let confidence: Float
    let bounds: CGRect
}

struct AppleLoginTextAnalysis: Equatable, Sendable {
    let isLoginScreen: Bool
    let recognizedLineCount: Int
    let evidence: String
}

/// Conservative visual fallback for the ordinary macOS user lock screen.
///
/// DisplayInfo2 only reports the real Login Window and Login Window's special
/// lock session. A logged-in user's lock screen is known to AppleVNCServer
/// (through SACScreenSaverIsRunning) but is not serialized to the viewer. This
/// detector therefore examines complete frames and requires corroborated
/// password/login evidence in the part of the screen where macOS places it.
enum AppleLoginScreenDetector {
    static func recognize(cgImage: CGImage) throws -> AppleLoginTextAnalysis {
        try recognize(handler: VNImageRequestHandler(
            cgImage: cgImage,
            orientation: .up,
            options: [:]))
    }

    static func recognize(
        pixelBuffer: CVPixelBuffer
    ) throws -> AppleLoginTextAnalysis {
        try recognize(handler: VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]))
    }

    static func analyze(_ lines: [AppleLoginTextLine]) -> AppleLoginTextAnalysis {
        let usable = lines.filter { line in
            line.confidence >= 0.35 && isCentralLoginRegion(line.bounds)
        }
        let normalized = usable.map { line in
            (text: normalize(line.text), bounds: line.bounds)
        }

        if normalized.contains(where: { containsStrongLoginPhrase($0.text) }) {
            return AppleLoginTextAnalysis(
                isLoginScreen: true,
                recognizedLineCount: lines.count,
                evidence: "central password-entry phrase")
        }

        let combined = normalized.map { $0.text }.joined(separator: " ")
        let hasPassword = containsPasswordWord(combined)
        let hasBiometric = combined.contains("touch id")
            || combined.contains("touchid")
        let actionCount = loginActions.reduce(into: 0) { count, action in
            if combined.contains(action) { count += 1 }
        }
        if hasPassword && (hasBiometric || actionCount >= 2) {
            return AppleLoginTextAnalysis(
                isLoginScreen: true,
                recognizedLineCount: lines.count,
                evidence: hasBiometric
                    ? "password and Touch ID"
                    : "password and login-window actions")
        }

        return AppleLoginTextAnalysis(
            isLoginScreen: false,
            recognizedLineCount: lines.count,
            evidence: hasPassword ? "weak password text only" : "no login phrase")
    }

    private static func recognize(
        handler: VNImageRequestHandler
    ) throws -> AppleLoginTextAnalysis {
        let fastRequest = VNRecognizeTextRequest()
        fastRequest.recognitionLevel = .fast
        fastRequest.usesLanguageCorrection = false
        fastRequest.automaticallyDetectsLanguage = true
        fastRequest.minimumTextHeight = 0.012
        fastRequest.preferBackgroundProcessing = true
        try handler.perform([fastRequest])

        let fastAnalysis = analyze(lines(from: fastRequest))
        if fastAnalysis.isLoginScreen {
            return fastAnalysis
        }

        // Current macOS lock screens put the password controls at the extreme
        // bottom of a Retina framebuffer. At full-frame scale Vision reliably
        // sees the large clock and date but skips the much smaller password
        // labels. Restricting the accurate pass to this lower-center region
        // makes those labels large relative to the request while examining
        // only 21% of the pixels.
        let focusedRequest = VNRecognizeTextRequest()
        focusedRequest.recognitionLevel = .accurate
        focusedRequest.usesLanguageCorrection = true
        focusedRequest.automaticallyDetectsLanguage = true
        focusedRequest.minimumTextHeight = 0.001
        focusedRequest.preferBackgroundProcessing = true
        focusedRequest.regionOfInterest = CGRect(
            x: 0.20, y: 0.0, width: 0.60, height: 0.35)
        try handler.perform([focusedRequest])
        return analyze(lines(from: focusedRequest))
    }

    private static func lines(
        from request: VNRecognizeTextRequest
    ) -> [AppleLoginTextLine] {
        (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }
            return AppleLoginTextLine(
                text: candidate.string,
                confidence: candidate.confidence,
                bounds: observation.boundingBox)
        }
    }

    private static func isCentralLoginRegion(_ bounds: CGRect) -> Bool {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return (0.14...0.86).contains(center.x)
            && (0.0...0.72).contains(center.y)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func containsStrongLoginPhrase(_ value: String) -> Bool {
        strongLoginPhrases.contains { value.contains($0) }
    }

    private static func containsPasswordWord(_ value: String) -> Bool {
        passwordWords.contains { value.contains($0) }
    }

    private static let strongLoginPhrases = [
        "enter password", "type password", "password required",
        "password is required", "passwort eingeben",
        "mot de passe", "introduce la contrasena", "ingresa tu contrasena",
        "inserisci password", "digite a senha", "voer wachtwoord in",
        "パスワードを入力", "输入密码", "輸入密碼", "암호 입력",
    ]

    private static let passwordWords = [
        "password", "passwort", "mot de passe", "contrasena", "senha",
        "wachtwoord", "パスワード", "密码", "密碼", "암호",
    ]

    private static let loginActions = [
        "cancel", "switch user", "sleep", "restart", "shut down",
        "annuler", "changer d utilisateur", "redemarrer", "eteindre",
        "abbrechen", "benutzer wechseln", "neustart", "ausschalten",
        "cancelar", "cambiar usuario", "reiniciar", "apagar",
    ]
}

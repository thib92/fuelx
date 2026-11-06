import ConvexMobile
import Foundation
import Testing

@testable import fuelx

struct LocalizationTests {
    private var french: Bundle { get throws { try bundle("fr") } }

    /// Tests name their language, because the simulator's may be either.
    private func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle(for: DayStore.self).path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func frenchIsBundled() throws {
        #expect(String(localized: "Breakfast", bundle: try french) == "Petit-déjeuner")
    }

    /// Keys with a literal percent sign and no arguments must come through unformatted.
    @Test func literalPercentSurvivesLookup() throws {
        let note = String(localized: "Weight loss is capped at 1% of body weight per week.", bundle: try french)
        #expect(note == "La perte de poids est plafonnée à 1\u{a0}% du poids corporel par semaine.")
    }

    @Test func percentArgumentIsFormatted() throws {
        let fat = 25
        #expect(String(localized: "\(fat)% of calories", bundle: try french) == "25\u{a0}% des calories")
    }

    @Test func secondArgumentStaysInPlace() throws {
        let height = "100"
        let limit = "250"
        let message = String(localized: "Height must be between \(height) and \(limit) cm.", bundle: try french)
        #expect(message == "La taille doit être comprise entre 100 et 250 cm.")
    }

    @Test func stepsAgreeWithTheirCount() throws {
        let english = try bundle("en")
        let one = 1
        let many = 2
        #expect(String(localized: "\(one) steps", bundle: english, locale: Locale(identifier: "en")) == "1 step")
        #expect(String(localized: "\(many) steps", bundle: english, locale: Locale(identifier: "en")) == "2 steps")
    }

    @Test func userErrorIsWordedFromItsCode() {
        let error = ClientError.ConvexError(data: #"{"code":"invalidHeight","message":"From the backend.","min":100,"max":250}"#)
        #expect(error.convexMessage != "From the backend.")
        #expect(error.convexMessage.contains("100"))
        #expect(error.convexMessage.contains("250"))
    }

    @Test func unknownCodeFallsBackToTheBackendsEnglish() {
        let error = ClientError.ConvexError(data: #"{"code":"new","message":"From the backend."}"#)
        #expect(error.convexMessage == "From the backend.")
    }

    @Test func plainStringErrorsStillWork() {
        #expect(ClientError.ConvexError(data: #""Plain message.""#).convexMessage == "Plain message.")
    }
}

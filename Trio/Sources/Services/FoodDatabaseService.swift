import Foundation
import Network
import os.log

/// Service for looking up food nutritional information from barcodes
class FoodDatabaseService {
    static let shared = FoodDatabaseService()

    /// Servings parsed from OpenFoodFacts above this size are treated as suspect
    /// (often the package weight rather than a single serving) and ignored.
    private static let suspiciousServingSizeGrams: Double = 250

    private let log = OSLog(subsystem: "Trio.BarcodeScanner", category: "FoodDatabase")
    private let cache = NSCache<NSString, CachedFoodItem>()
    private let monitor = NWPathMonitor()
    private var isNetworkAvailable = true

    private init() {
        cache.countLimit = 100
        monitor.pathUpdateHandler = { [weak self] path in
            self?.isNetworkAvailable = path.status == .satisfied
        }
        monitor.start(queue: DispatchQueue(label: "FoodDatabaseNetworkMonitor"))
    }

    deinit {
        monitor.cancel()
    }

    /// Lookup food item by barcode using OpenFoodFacts API
    func lookupFood(barcode: String) async throws -> Treatments.FoodItem? {
        guard !barcode.isEmpty else {
            throw FoodDatabaseError.invalidBarcode
        }

        os_log("lookup barcode=%{public}@", log: log, type: .info, barcode)

        // Check cache first
        if let cachedItem = cache.object(forKey: barcode as NSString) {
            os_log("cache hit for barcode=%{public}@", log: log, type: .debug, barcode)
            return cachedItem.foodItem
        }

        // Check network availability
        guard isNetworkAvailable else {
            throw FoodDatabaseError.networkUnavailable
        }

        let urlString = "https://world.openfoodfacts.org/api/v0/product/\(barcode).json"
        guard let url = URL(string: urlString) else {
            throw FoodDatabaseError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("TrioApp/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw FoodDatabaseError.timeout
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw FoodDatabaseError.networkError
        }

        let openFoodFactsResponse: OpenFoodFactsResponse
        do {
            openFoodFactsResponse = try JSONDecoder().decode(OpenFoodFactsResponse.self, from: data)
        } catch {
            throw FoodDatabaseError.decodingError
        }

        guard openFoodFactsResponse.status == 1,
              let product = openFoodFactsResponse.product
        else {
            throw FoodDatabaseError.productNotFound
        }

        let foodItem = try convertToFoodItem(product: product, barcode: barcode)

        // Cache the result
        cache.setObject(CachedFoodItem(foodItem: foodItem), forKey: barcode as NSString)

        return foodItem
    }

    private func convertToFoodItem(product: OpenFoodFactsProduct, barcode: String) throws -> Treatments.FoodItem {
        guard let nutriments = product.nutriments else {
            throw FoodDatabaseError.missingNutritionData
        }

        let name = product.product_name ?? product.product_name_en ?? "Unknown Product"
        let brand = product.brands?.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)

        // A missing carb value must fail the lookup rather than become 0 g: the
        // scanned total is added straight into the carbs used for the bolus.
        guard let carbs = nutriments.carbohydrates_100g ?? nutriments.carbohydrates else {
            os_log("no carb value for barcode=%{public}@ name=%{public}@", log: log, type: .info, barcode, name)
            throw FoodDatabaseError.missingCarbData(productName: name)
        }

        // Convert nutrients per 100g (OpenFoodFacts standard), falling back to non-100g fields
        let protein = nutriments.proteins_100g ?? nutriments.proteins ?? 0.0
        let fat = nutriments.fat_100g ?? nutriments.fat ?? 0.0
        let calories = nutriments.energy_kcal_100g ?? nutriments.energy_kcal ?? 0.0

        let servingSize = product.serving_size
        let servingSizeGrams = resolveServingSizeGrams(product: product)

        os_log(
            "parsed barcode=%{public}@ name=%{public}@ carbs/100g=%.1f protein/100g=%.1f fat/100g=%.1f serving_size=%{public}@ serving_quantity=%.1f resolvedGrams=%.1f",
            log: log, type: .info,
            barcode, name, carbs, protein, fat,
            servingSize ?? "nil",
            product.serving_quantity?.value ?? -1,
            servingSizeGrams ?? -1
        )

        return Treatments.FoodItem(
            barcode: barcode,
            name: name,
            brand: brand,
            servingSize: servingSize,
            carbsPer100g: carbs,
            proteinPer100g: protein,
            fatPer100g: fat,
            caloriesPer100g: calories,
            servingSizeGrams: servingSizeGrams
        )
    }

    /// Pick a serving size in grams, preferring OpenFoodFacts' structured numeric
    /// `serving_quantity` over the free-text `serving_size` string. Suspiciously
    /// large values (commonly the package weight masquerading as a serving) are
    /// dropped so the UI defaults to 100g and the user adjusts from there.
    private func resolveServingSizeGrams(product: OpenFoodFactsProduct) -> Double? {
        if let qty = product.serving_quantity?.value, qty > 0 {
            let unit = product.serving_quantity_unit?.lowercased() ?? "g"
            if unit == "g" || unit.hasPrefix("gram") {
                return acceptIfReasonable(qty, source: "serving_quantity")
            }
        }
        if let parsed = parseServingSize(product.serving_size) {
            return acceptIfReasonable(parsed, source: "serving_size string")
        }
        return nil
    }

    private func acceptIfReasonable(_ grams: Double, source: String) -> Double? {
        if grams > Self.suspiciousServingSizeGrams {
            os_log(
                "ignoring suspicious serving size %.1fg from %{public}@; UI will default to 100g",
                log: log, type: .info, grams, source
            )
            return nil
        }
        return grams
    }

    private func parseServingSize(_ servingSize: String?) -> Double? {
        guard let servingSize = servingSize else { return nil }

        // Try to extract grams from serving size string
        let pattern = #"(\d+(?:\.\d+)?)\s*g"#
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let range = NSRange(location: 0, length: servingSize.utf16.count)

        if let match = regex?.firstMatch(in: servingSize, options: [], range: range),
           let gramsRange = Range(match.range(at: 1), in: servingSize)
        {
            return Double(servingSize[gramsRange])
        }

        return nil
    }
}

// MARK: - Cache Wrapper

private class CachedFoodItem: NSObject {
    let foodItem: Treatments.FoodItem

    init(foodItem: Treatments.FoodItem) {
        self.foodItem = foodItem
    }
}

// MARK: - OpenFoodFacts API Models

struct OpenFoodFactsResponse: Codable {
    let status: Int
    let product: OpenFoodFactsProduct?
}

struct OpenFoodFactsProduct: Codable {
    let product_name: String?
    let product_name_en: String?
    let brands: String?
    let serving_size: String?
    let serving_quantity: FlexibleDouble?
    let serving_quantity_unit: String?
    let nutriments: OpenFoodFactsNutriments?
}

/// `serving_quantity` is sometimes returned as a JSON number and sometimes as a
/// numeric string; accept either.
struct FlexibleDouble: Codable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = Double(s)
        } else {
            value = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct OpenFoodFactsNutriments: Codable {
    let carbohydrates_100g: Double?
    let proteins_100g: Double?
    let fat_100g: Double?
    let energy_kcal_100g: Double?

    // Alternative field names that might be present
    let carbohydrates: Double?
    let proteins: Double?
    let fat: Double?
    let energy_kcal: Double?
}

// MARK: - Errors

enum FoodDatabaseError: LocalizedError {
    case invalidBarcode
    case invalidURL
    case networkError
    case networkUnavailable
    case timeout
    case productNotFound
    case missingNutritionData
    case missingCarbData(productName: String)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidBarcode:
            return "Invalid barcode format"
        case .invalidURL:
            return "Invalid API URL"
        case .networkError:
            return "Network error occurred"
        case .networkUnavailable:
            return "No internet connection. Please check your network and try again."
        case .timeout:
            return "Request timed out. Please try again."
        case .productNotFound:
            return "Product not found in database"
        case .missingNutritionData:
            return "Nutrition data not available for this product"
        case let .missingCarbData(productName):
            return "The food database has no carb information for \"\(productName)\". Enter the carbs from the package label instead."
        case .decodingError:
            return "Failed to decode product data"
        }
    }
}

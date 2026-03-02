import Foundation
import Network

/// Service for looking up food nutritional information from barcodes
class FoodDatabaseService {
    static let shared = FoodDatabaseService()

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

        // Check cache first
        if let cachedItem = cache.object(forKey: barcode as NSString) {
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

        // Convert nutrients per 100g (OpenFoodFacts standard), falling back to non-100g fields
        let carbs = nutriments.carbohydrates_100g ?? nutriments.carbohydrates ?? 0.0
        let protein = nutriments.proteins_100g ?? nutriments.proteins ?? 0.0
        let fat = nutriments.fat_100g ?? nutriments.fat ?? 0.0
        let calories = nutriments.energy_kcal_100g ?? nutriments.energy_kcal ?? 0.0

        // Try to get serving size from the product
        let servingSize = product.serving_size
        let servingSizeGrams = parseServingSize(servingSize)

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
    let nutriments: OpenFoodFactsNutriments?
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
        case .decodingError:
            return "Failed to decode product data"
        }
    }
}

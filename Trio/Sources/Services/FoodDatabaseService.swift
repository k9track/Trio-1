import Foundation

/// Service for looking up food nutritional information from barcodes
class FoodDatabaseService {
    static let shared = FoodDatabaseService()

    private init() {}

    /// Lookup food item by barcode using OpenFoodFacts API
    func lookupFood(barcode: String) async throws -> Treatments.FoodItem? {
        guard !barcode.isEmpty else {
            throw FoodDatabaseError.invalidBarcode
        }

        let urlString = "https://world.openfoodfacts.org/api/v0/product/\(barcode).json"
        guard let url = URL(string: urlString) else {
            throw FoodDatabaseError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw FoodDatabaseError.networkError
        }

        let openFoodFactsResponse = try JSONDecoder().decode(OpenFoodFactsResponse.self, from: data)

        guard openFoodFactsResponse.status == 1,
              let product = openFoodFactsResponse.product
        else {
            throw FoodDatabaseError.productNotFound
        }

        return try convertToFoodItem(product: product, barcode: barcode)
    }

    private func convertToFoodItem(product: OpenFoodFactsProduct, barcode: String) throws -> Treatments.FoodItem {
        guard let nutriments = product.nutriments else {
            throw FoodDatabaseError.missingNutritionData
        }

        let name = product.product_name ?? product.product_name_en ?? "Unknown Product"
        let brand = product.brands?.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)

        // Convert nutrients per 100g (OpenFoodFacts standard)
        let carbs = nutriments.carbohydrates_100g ?? 0.0
        let protein = nutriments.proteins_100g ?? 0.0
        let fat = nutriments.fat_100g ?? 0.0
        let calories = nutriments.energy_kcal_100g

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
        case .productNotFound:
            return "Product not found in database"
        case .missingNutritionData:
            return "Nutrition data not available for this product"
        case .decodingError:
            return "Failed to decode product data"
        }
    }
}

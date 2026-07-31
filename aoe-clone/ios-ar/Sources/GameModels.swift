import Foundation

// Codable mirrors of the JSON protocol spoken by server/index.js. Keep these
// in sync with the field names in server/game.js's getState()/getStaticInfo()
// and the join/command messages client.js sends.

struct UnitTypeInfo: Codable {
    let name: String
    let hp: Double
    let attack: Double?
    let defense: Double?
    let attackCooldown: Double?
    let range: Double?
    let speed: Double
    let gatherRate: Double?
    let carryCapacity: Double?
    let cost: [String: Double]
    let trainTime: Double
    let radius: Double
}

struct BuildingTypeInfo: Codable {
    let name: String
    let hp: Double
    let size: Double
    let cost: [String: Double]
    let buildTime: Double
    let trains: [String]
    let dropOff: [String]?
    let popBonus: Double
}

struct WelcomeMessage: Codable {
    let type: String
    let playerId: Int
    let originLat: Double
    let originLng: Double
    let distanceFromOriginM: Double
    let farFromOrigin: Bool
    let unitTypes: [String: UnitTypeInfo]
    let buildingTypes: [String: BuildingTypeInfo]
    let playRadiusM: Double
}

struct PlayerDTO: Codable, Identifiable {
    let id: Int
    let name: String
    let color: String
    let resources: [String: Double]
    let population: Int
    let popCap: Int
    let eliminated: Bool
}

struct UnitDTO: Codable, Identifiable {
    let id: Int
    let ownerId: Int
    let type: String
    let lat: Double
    let lng: Double
    let hp: Double
    let maxHp: Double
    let carryType: String?
    let carryAmount: Double
}

struct TrainQueueItem: Codable {
    let unitType: String
    let timeRemaining: Double
}

struct BuildingDTO: Codable, Identifiable {
    let id: Int
    let ownerId: Int
    let type: String
    let lat: Double
    let lng: Double
    let hp: Double
    let maxHp: Double
    let constructed: Bool
    let buildProgress: Double
    let trainQueue: [TrainQueueItem]
}

struct ResourceDTO: Codable, Identifiable {
    let id: Int
    let type: String
    let lat: Double
    let lng: Double
    let amount: Double
    let maxAmount: Double
}

struct StateMessage: Codable {
    let type: String
    let tick: Int
    let players: [PlayerDTO]
    let units: [UnitDTO]
    let buildings: [BuildingDTO]
    let resources: [ResourceDTO]
}

struct ErrorMessage: Codable {
    let type: String
    let message: String
}
